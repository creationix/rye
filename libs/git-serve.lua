local digest = require('openssl').digest.digest
local git = require('git')
local modes = git.modes
local listToMap = git.listToMap
local JSON = require('json')
local getType = require('mime').getType


return function (db, ref)
  return function (req, res, go)
    local commitHash = db.resolve(ref)
    local path = req.params.path or req.path
    local fullPath = commitHash .. ":" .. path
    local etag = '"dir-' .. digest("sha1", fullPath) .. '"'
    if etag == req.headers["If-None-Match"] then
      res.code = 304
      res.headers.ETag = etag
      return
    end
    local hash = db.loadAs("commit", commitHash).tree
    for part in path:gmatch("[^/]+") do
      local tree = listToMap(db.loadAs("tree", hash))
      local entry = tree[part]
      if entry.mode == modes.commit then
        error("Submodules not implemented yet")
      end
      if not entry then return go() end
      hash = entry.hash
    end
    if not hash then return go() end

    local function render(kind, value)
      if kind == "tree" then
        if req.path:sub(-1) ~= "/" then
          res.code = 301
          res.headers.Location = req.path .. "/"
          return
        end
        for i = 1, #value do
          local entry = value[i]
          if entry.name == "index.html" and modes.isFile(entry.mode) then
            path = path .. "index.html"
            return render(db.loadAny(entry.hash))
          end
          entry.type = modes.toType(entry.mode)
          if entry.mode == modes.tree or modes.isBlob(entry.mode) then
            local url = "http://" .. req.headers.Host .. req.path .. entry.name
            if entry.mode == modes.tree then url = url .. "/" end
            value[i].url = url
          end
        end
        res.code = 200
        res.headers["Content-Type"] = "application/json"
        res.headers.ETag = etag
        res.body = JSON.stringify(value) .. "\n"
        return
      elseif kind == "blob" then
        res.code = 200
        res.headers["Content-Type"] = getType(path)
        res.headers.ETag = etag
        res.body = value
        return
      else
        error("Unsupported kind: " .. kind)
      end
    end
    return render(db.loadAny(hash))
  end
end
