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

return function (storage)

  local encoders = git.encoders
  local decoders = git.decoders
  local frame = git.frame
  local deframe = git.deframe
  local deflate = miniz.deflate
  local inflate = miniz.inflate
  local digest = openssl.digest.digest
  local binToHex = hexBin.binToHex

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

  local function assertHash(hash)
    assert(hash and #hash == 40 and hash:match("^%x+$"), "Invalid hash")
  end

  local function hashPath(hash)
    return string.format("objects/%s/%s", hash:sub(1, 2), hash:sub(3))
  end

  function db.has(hash)
    assertHash(hash)
    return storage.read(hashPath(hash)) and true or false
  end

  local function readUint32(buffer, offset)
    return bit.bor(
      bit.lshift(buffer:byte(offset + 1), 24),
      bit.lshift(buffer:byte(offset + 2), 16),
      bit.lshift(buffer:byte(offset + 3), 8),
      buffer:byte(offset + 4)
    )
  end

  local function readUint64(buffer, offset)
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

  local indexes = {}
  local function parseIndex(hash)
    local parsed = indexes[hash]
    if parsed then return parsed end
    local data = storage.read("objects/pack/pack-" .. hash .. ".idx")
    assert(data:sub(1, 8) == '\255tOc\0\0\0\2', "Only pack index v2 supported")


    -- Get the number of hashes in index
    -- This is the value of the last fan-out entry
    local length = readUint32(data, 8 + 255 * 4)
    local items = {}
    indexes[hash] = items

    local hashOffset = 8 + 255 * 4 + 4
    local crcOffset = hashOffset + 20 * length
    local lengthOffset = crcOffset + 4 * length
    local largeOffset = lengthOffset + 4 * length
    local checkOffset = largeOffset

    for i = 1, length do
      local start = hashOffset + i * 20
      local hash = binToHex(data:sub(start + 1, start + 20))
      local offset = readUint32(data, lengthOffset + i * 4);
      if bit.band(offset, 0x80000000) > 0 then
        offset = largeOffset + bit.band(offset, 0x7fffffff) * 8;
        checkOffset = (checkOffset > offset + 8) and checkOffset or offset + 8
        offset = readUint64(data, offset);
      end
      items[hash] = offset
    end

    return items
  end

  function db.load(hash)
    hash = db.resolve(hash)
    assertHash(hash)
    local compressed, err = storage.read(hashPath(hash))
    if not compressed then
      for file in storage.leaves("objects/pack") do
        local packHash = file:match("^pack%-(%x+)%.idx$")
        if packHash then
          local index = parseIndex(packHash)
          local offset = index[hash]
          if not offset then return end
          p(hash, offset)
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
    if not ref then return end
    return db.getRef(ref)
  end

  function db.getRef(ref)
    local hash = storage.read(ref)
    if hash then return hash:match("%x+") end
    local refs = storage.read("packed-refs")
    return refs:match("(%x+) " .. ref)
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
