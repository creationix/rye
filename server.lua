local digest = require('openssl').digest.digest
local git = require('git')
local modes = git.modes
local listToMap = git.listToMap
local JSON = require('json')
local getType = require('mime').getType

local db, headerMeta

local function getEtag(ref, path) --> etag, commitHash
  local commitHash = db.resolve(ref)
  local fullPath = commitHash .. ":" .. path
  return '"dir-' .. digest("sha1", fullPath) .. '"', commitHash
end

local function pathToHash(commitHash, path)
  local hash = db.loadAs("commit", commitHash).tree
  for part in path:gmatch("[^/]+") do
    local tree = listToMap(db.loadAs("tree", hash))
    local entry = tree[part]
    if entry.mode == modes.commit then
      return nil, "Submodules not implemented yet"
    end
    if not entry then return end
    hash = entry.hash
  end
  return hash
end

local function gitServe(ref, path, req)
  local etag, commitHash = getEtag(ref, path)
  local headers = setmetatable({}, headerMeta)
  headers.Etag = etag
  if etag == req.headers["if-none-match"] then
    return 304, headers
  end
  local hash = pathToHash(commitHash, path)
  if not hash then return end
  local kind, value = db.loadAny(hash)
  if kind == "tree" then
    if req.path:sub(-1) ~= "/" then
      return 301, {{"Location", req.path .. "/"}}
    end
    for i = 1, #value do
      local entry = value[i]
      entry.type = modes.toType(entry.mode)
      if entry.mode == modes.tree or modes.isBlob(entry.mode) then
        local url = "http://" .. req.headers.Host .. req.path .. entry.name
        if entry.mode == modes.tree then url = url .. "/" end
        value[i].url = url
      end
    end
    headers["Content-Type"] = "application/json"
    local body = JSON.stringify(value) .. "\n"

    return 200, headers, body
  elseif kind == "blob" then
    headers["Content-Type"] = getType(path)
    return 200, headers, value
  end
end

coroutine.wrap(function ()
  db = require('git-fs')(require('storage-fs')(require('coro-fs').chroot('luvit.io.git')))

  local people = {
    tim = 32,
    jack = 8,
  }

  local app = require('web-app')
  headerMeta = app.headerMeta

  app.get("/:name", function (name)
    local age = people[name]
    if not age then return end
    return 200, name .. " is " .. age .. " years old\n"
  end)

  app.put("/:name/:age", function (name, age)
    people[name] = age
    return 204
  end)

  app.get("/creationix/:path:", function (path, req)
    return gitServe("c5bdc76024924060b6776f56260e46c57679ab97", path, req)
  end)

  app.get("/exploder/:path:", function (path, req)
    return gitServe("fd69d5d826f63d51860ca946c7ce0069060eff97", path, req)
  end)

  app.get("/luvit/:path:", function (path, req)
    return gitServe("HEAD", path, req)
  end)

  app.listen("0.0.0.0", 8080)


end)()


