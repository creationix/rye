exports.name = "creationix/git-fs"
exports.version = "0.1.0"
exports.dependencies = { "creationix/git@0.1.0" }

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
]]

local git = require('git')
local miniz = require('miniz')
local openssl = require('openssl')

return function (storage)

  local encoders = git.encoders
  local decoders = git.decoders
  local frame = git.frame
  local deframe = git.deframe
  local deflate = miniz.deflate
  local inflate = miniz.inflate
  local digest = openssl.digest.digest

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

  function db.load(hash)
    assertHash(hash)
    local compressed, err = storage.read(hashPath(hash))
    if not compressed then return nil, err end
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

  return db
end
