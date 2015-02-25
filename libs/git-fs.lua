exports.name = "creationix/git-fs"
exports.version = "0.1.0"
exports.dependencies = {
  "creationix/git@0.1.0",
  "creationix/hex-bin@1.0.0",
}

--[[

Git Object Database
===================

Consumes a storage interface and return a git database interface

db.has(hash) -> bool                   - check if db has an object
db.load(hash) -> raw                   - load raw data, nil if not found
db.loadAny(hash) -> kind, value        - pre-decode data, error if not found
db.loadAs(kind, hash) -> value         - pre-decode and check type or error
db.save(raw) -> hash                   - save pre-encoded and framed data
db.saveAs(kind, value) -> hash         - encode, frame and save to objects/$ha/$sh
db.hashes() -> iter                    - Iterate over all hashes

db.getHead() -> hash                   - Read the hash via HEAD
db.getRef(ref) -> hash                 - Read hash of a ref
db.resolve(ref) -> hash                - Given a hash, tag, branch, or HEAD, return the hash
]]

local git = require('git')
local miniz = require('miniz')
local openssl = require('openssl')
local hexBin = require('hex-bin')

local numToType = {
  [1] = "commit",
  [2] = "tree",
  [3] = "blob",
  [4] = "tag",
  [6] = "ofs-delta",
  [7] = "ref-delta",
}

local function applyDelta(base, delta) --> raw
  local deltaOffset = 0;

  -- Read a variable length number our of delta and move the offset.
  local function readLength()
    deltaOffset = deltaOffset + 1
    local byte = delta:byte(deltaOffset)
    local length = bit.band(byte, 0x7f)
    local shift = 7
    while bit.band(byte, 0x80) > 0 do
      deltaOffset = deltaOffset + 1
      byte = delta:byte(deltaOffset)
      length = bit.bor(length, bit.lshift(bit.band(byte, 0x7f), shift))
      shift = shift + 7
    end
    return length
  end

  assert(#base == readLength(), "base length mismatch")

  local outLength = readLength()
  local parts = {}
  while deltaOffset < #delta do
    deltaOffset = deltaOffset + 1
    local byte = delta:byte(deltaOffset)

    if bit.band(byte, 0x80) > 0 then
      -- Copy command. Tells us offset in base and length to copy.
      local offset = 0
      local length = 0
      if bit.band(byte, 0x01) > 0 then
        deltaOffset = deltaOffset + 1
        offset = bit.bor(offset, delta:byte(deltaOffset))
      end
      if bit.band(byte, 0x02) > 0 then
        deltaOffset = deltaOffset + 1
        offset = bit.bor(offset, bit.lshift(delta:byte(deltaOffset), 8))
      end
      if bit.band(byte, 0x04) > 0 then
        deltaOffset = deltaOffset + 1
        offset = bit.bor(offset, bit.lshift(delta:byte(deltaOffset), 16))
      end
      if bit.band(byte, 0x08) > 0 then
        deltaOffset = deltaOffset + 1
        offset = bit.bor(offset, bit.lshift(delta:byte(deltaOffset), 24))
      end
      if bit.band(byte, 0x10) > 0 then
        deltaOffset = deltaOffset + 1
        length = bit.bor(length, delta:byte(deltaOffset))
      end
      if bit.band(byte, 0x20) > 0 then
        deltaOffset = deltaOffset + 1
        length = bit.bor(length, bit.lshift(delta:byte(deltaOffset), 8))
      end
      if bit.band(byte, 0x40) > 0 then
        deltaOffset = deltaOffset + 1
        length = bit.bor(length, bit.lshift(delta:byte(deltaOffset), 16))
      end
      if length == 0 then length = 0x10000 end
      -- copy the data
      parts[#parts + 1] = base:sub(offset + 1, offset + length)
    elseif byte > 0 then
      -- Insert command, opcode byte is length itself
      parts[#parts + 1] = delta:sub(deltaOffset + 1, deltaOffset + byte)
      deltaOffset = deltaOffset + byte
    else
      error("Invalid opcode in delta")
    end
  end
  local out = table.concat(parts)
  assert(#out == outLength, "final size mismatch in delta application")
  return table.concat(parts)
end

local function readUint32(buffer, offset)
  offset = offset or 0
  return bit.bor(
    bit.lshift(buffer:byte(offset + 1), 24),
    bit.lshift(buffer:byte(offset + 2), 16),
    bit.lshift(buffer:byte(offset + 3), 8),
    buffer:byte(offset + 4)
  )
end

local function readUint64(buffer, offset)
  offset = offset or 0
  local hi, lo =
  bit.bor(
    bit.lshift(buffer:byte(offset + 1), 24),
    bit.lshift(buffer:byte(offset + 2), 16),
    bit.lshift(buffer:byte(offset + 3), 8),
    buffer:byte(offset + 4)
  ),
  bit.bor(
    bit.lshift(buffer:byte(offset + 5), 24),
    bit.lshift(buffer:byte(offset + 6), 16),
    bit.lshift(buffer:byte(offset + 7), 8),
    buffer:byte(offset + 8)
  )
  return hi * 0x100000000 + lo;
end

local function assertHash(hash)
  assert(hash and #hash == 40 and hash:match("^%x+$"), "Invalid hash")
end

local function hashPath(hash)
  return string.format("objects/%s/%s", hash:sub(1, 2), hash:sub(3))
end

return function (storage)

  local encoders = git.encoders
  local decoders = git.decoders
  local frame = git.frame
  local deframe = git.deframe
  local deflate = miniz.deflate
  local inflate = miniz.inflate
  local digest = openssl.digest.digest
  local binToHex = hexBin.binToHex
  local hexToBin = hexBin.hexToBin

  local db = { storage = storage }
  local fs = storage.fs

  -- Initialize the git file storage tree if it does't exist yet
  if not fs.access("HEAD") then
    assert(fs.mkdirp("objects"))
    assert(fs.mkdirp("refs/tags"))
    assert(fs.writeFile("HEAD", "ref: refs/heads/master\n"))
    assert(fs.writeFile("config", [[
[core]
  repositoryformatversion = 0
  filemode = true
  bare = true
[gc]
        auto = 0
]]))
  end

  function db.has(hash)
    assertHash(hash)
    return storage.read(hashPath(hash)) and true or false
  end

  local function findHash(indexHash, hash) --> offset
    local fd = assert(fs.open("objects/pack/pack-" .. indexHash .. ".idx"))
    local success, result = xpcall(function ()
      assert(fs.read(fd, 8, 0) == '\255tOc\0\0\0\2', "Only pack index v2 supported")
      local length = readUint32((fs.read(fd, 4, 8 + 255 * 4)))

      -- Read first fan-out table to get index into offset table
      local prefix = hexToBin(hash:sub(1, 2)):byte(1)
      local first = prefix == 0 and 0 or readUint32((fs.read(fd, 4, 8 + (prefix - 1) * 4)))
      local last = readUint32((fs.read(fd, 4, 8 + prefix * 4)))

      local hashOffset = 8 + 255 * 4 + 4
      local crcOffset = hashOffset + 20 * length
      local lengthOffset = crcOffset + 4 * length
      local largeOffset = lengthOffset + 4 * length
      for index = first, last do
        local start = hashOffset + index * 20
        local foundHash = binToHex(fs.read(fd, 20, start))
        if foundHash == hash then
          local offset = readUint32(fs.read(fd, 4, lengthOffset + index * 4))
          if bit.band(offset, 0x80000000) > 0 then
            offset = largeOffset + bit.band(offset, 0x7fffffff) * 8;
            offset = readUint64(fs.read(fd, 8, offset))
          end
          return offset
        end
      end

    end, debug.traceback)
    fs.close(fd)
    if success then return result end
    error(result)
  end

  local function loadPack(packHash, offset)
    local fd = assert(fs.open("objects/pack/pack-" .. packHash .. ".pack"))
    local success, kind, raw = xpcall(function ()
      assert(fs.read(fd, 8, 0) == "PACK\0\0\0\2", "Only v2 pack files supported")

      -- Shouldn't need more than 32 bytes to read variable length header and
      -- optional hash or offset
      local chunk = fs.read(fd, 32, offset)
      local byte = chunk:byte(1)

      -- Parse out the git type
      local kind = numToType[bit.band(bit.rshift(byte, 4), 0x7)]

      -- Parse out the uncompressed length
      local size = bit.band(byte, 0xf)
      local left = 4
      local i = 2
      while bit.band(byte, 0x80) > 0 do
        byte = chunk:byte(i)
        i = i + 1
        size = bit.bor(size, bit.lshift(bit.band(byte, 0x7f), left))
        left = left + 7
      end

      -- Optionally parse out the hash or offset for deltas
      local ref
      if kind == "ref-delta" then
        ref = binToHex(chunk:sub(i + 1, i + 20))
        i = i + 20
      elseif kind == "ofs-delta" then
        local byte = chunk:byte(i)
        i = i + 1
        ref = bit.band(byte, 0x7f)
        while bit.band(byte, 0x80) > 0 do
          byte = chunk:byte(i)
          i = i + 1
          ref = bit.bor(bit.lshift(ref + 1, 7), bit.band(byte, 0x7f))
        end
      end

      -- We don't know the size of the compressed data, so we guess uncompressed
      -- size + 32, extra data will be ignored
      local compressed = fs.read(fd, size + 32, offset + i - 1)
      local raw = inflate(compressed, 1)

      assert(#raw == size, "inflate error or size mismatch")

      if kind == "ref-delta" then
        error("TODO: handle ref-delta")
      elseif kind == "ofs-delta" then
        local base
        kind, base = loadPack(packHash, offset - ref)
        raw = applyDelta(base, raw)
      end
      return kind, raw
    end, debug.traceback)
    fs.close(fd)
    if success then return kind, raw end
    error(kind)
  end

  local function loadHash(packHash, hash)
    local offset, err = findHash(packHash, hash)
    if not offset then return nil, err end
    return frame(loadPack(packHash, offset))
  end

  function db.load(hash)
    hash = db.resolve(hash)
    assertHash(hash)
    local compressed, err = storage.read(hashPath(hash))
    if not compressed then
      for file in storage.leaves("objects/pack") do
        local packHash = file:match("^pack%-(%x+)%.idx$")
        if packHash then
          local raw
          raw, err = loadHash(packHash, hash)
          if raw then return raw end
        end
      end
      return nil, err
    end
    return inflate(compressed, 1)
  end

  function db.loadAny(hash)
    local raw = assert(db.load(hash), "no such hash")
    local kind, value = deframe(raw)
    return kind, decoders[kind](value)
  end

  function db.loadAs(kind, hash)
    local actualKind, value = db.loadAny(hash)
    assert(kind == actualKind, "Kind mismatch")
    return value
  end

  function db.save(raw)
    local hash = digest("sha1", raw)
    -- 0x1000 = TDEFL_WRITE_ZLIB_HEADER
    -- 4095 = Huffman+LZ (slowest/best compression)
    storage.put(hashPath(hash), deflate(raw, 0x1000 + 4095))
    return hash
  end

  function db.saveAs(kind, value)
    if type(value) ~= "string" then
      value = encoders[kind](value)
    end
    return db.save(frame(kind, value))
  end

  function db.hashes()
    local groups = storage.nodes("objects")
    local prefix, iter
    return function ()
      while true do
        if prefix then
          local rest = iter()
          if rest then return prefix .. rest end
          prefix = nil
          iter = nil
        end
        prefix = groups()
        if not prefix then return end
        iter = storage.leaves("objects/" .. prefix)
      end
    end
  end

  function db.getHead()
    local head = storage.read("HEAD")
    if not head then return end
    local ref = head:match("^ref: *([^\n]+)")
    return ref and db.getRef(ref)
  end

  function db.getRef(ref)
    local hash = storage.read(ref)
    if hash then return hash:match("%x+") end
    local refs = storage.read("packed-refs")
    return refs and refs:match("(%x+) " .. ref)
  end

  function db.resolve(ref)
    if ref == "HEAD" then return db.getHead() end
    local hash = ref:match("^%x+$")
    if hash and #hash == 40 then return hash end
    return db.getRef(ref)
        or db.getRef("refs/heads/" .. ref)
        or db.getRef("refs/tags/" .. ref)
  end

  return db
end
