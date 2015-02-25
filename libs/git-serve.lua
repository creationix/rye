local digest = require('openssl').digest.digest
local git = require('git')
local modes = git.modes
local listToMap = git.listToMap
local JSON = require('json')
local getType = require('mime').getType
local headerMeta = require('web-app').headerMeta


return function (db, ref)
  return function (path, req)
    local commitHash = db.resolve(ref)
    local fullPath = commitHash .. ":" .. path
    local etag = '"dir-' .. digest("sha1", fullPath) .. '"'
    local headers = setmetatable({}, headerMeta)
    headers.Etag = etag
    if etag == req.headers["if-none-match"] then
      return 304, headers
    end
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
    if not hash then return end

    local function render(kind, value)
      if kind == "tree" then
        if req.path:sub(-1) ~= "/" then
          return 301, {{"Location", req.path .. "/"}}
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
        headers["Content-Type"] = "application/json"
        local body = JSON.stringify(value) .. "\n"

        return 200, headers, body
      elseif kind == "blob" then
        headers["Content-Type"] = getType(path)
        return 200, headers, value
      end
    end
    return render(db.loadAny(hash))
  end
end
