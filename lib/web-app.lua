local createServer = require('coro-tcp').createServer
local wrapper = require('coro-wrapper')
local readWrap, writeWrap = wrapper.reader, wrapper.writer
local httpCodec = require('http-codec')
local digest = require('openssl').digest.digest
local date = require('os').date

local compileRoute = require('./compile-route')
local server = "Rye-Web " .. require('../package').version

local routes = {}

local function handleRequest(req)
  local isHead = false
  if req.method == "HEAD" then
    req.method = "GET"
    isHead = true
  end
  local res = {}
  local body
  local out = {}
  for i = 1, #routes do
    local route = routes[i]
    if not route.method or route.method == req.method then
      if route.path then
        local match = route.path(req.path)
        if match then
          out = {route.handler(unpack(match))}
          if #out > 0 then break end
        end
      else
        out = {route.handler(req)}
        if #out > 0 then break end
      end
    end
  end

  if #out == 0 then
    res.code = 404
    body = "Not Found\n"
  else
    local i = 1
    if type(out[i]) == "number" then
      res.code = out[i]
      i = i + 1
    end
    if type(out[i]) == "table" then
      local headers = out[i]
      i = i + 1
      for i = 1, #headers do
        res[#res  +1] = headers[i]
      end
    end
    if type(out[i]) == "string" then
      body = out[i]
    end
  end

  local lower = {}
  for i = 1, #res do
    local key, value = unpack(res[i])
    lower[key:lower()] = value
  end
  if not lower.server then
    res[#res + 1] = {"Server", server}
  end
  if not lower.date then
    res[#res + 1] = {"Date", date("!%a, %d %b %Y %H:%M:%S GMT")}
  end
  if not lower.connection then
    if req.keepAlive then
      lower.connection = "Keep-Alive"
      res[#res + 1] = {"Connection", "Keep-Alive"}
    else
      res[#res + 1] = {"Connection", "Close"}
    end
  end
  res.keepAlive = lower.connection:lower() == "keep-alive"
  if body then
    local needLength = not lower["content-length"] and not lower["transfer-encoding"]
    if type(body) == "string" then
      if needLength then
        res[#res + 1] = {"Content-Length", #body}
      end
      if not lower.etag then
        local etag = '"' .. digest("sha1", body) .. '"'
        lower.etag = etag
        res[#res + 1] = {"ETag", etag}
      end
    else
      if needLength then
        res[#res + 1] = {"Transfer-Encoding", "chunked"}
      end
    end
    if not lower["content-type"] then
      res[#res + 1] = {"Content-Type", "text/plain"}
    end
  end

  local headers = {}
  for i = 1, #req do
    local key, value = unpack(req[i])
    headers[key:lower()] = value
  end

  local etag = headers["if-none-match"]
  if etag and res.code >= 200 and res.code < 300 and etag == lower.etag then
    res.code = 304
    body = nil
  end

  if isHead then body = nil end

  return res, body
end

local function handleConnection(rawRead, rawWrite)

  -- Speak in HTTP events
  local read = readWrap(rawRead, httpCodec.decoder())
  local write = writeWrap(rawWrite, httpCodec.encoder())

  for req in read do
    local parts = {}
    for chunk in read do
      if #chunk > 0 then
        parts[#parts + 1] = chunk
      else
        break
      end
    end
    req.parts = #parts > 0 and table.concat(parts) or nil
    local res, body = handleRequest(req)
    write(res)
    write(body)
    if not (res.keepAlive and req.keepAlive) then
      break
    end
  end
  write()

end

-- Create the public interface
local app = {}

-- Make nice aliases for REST handlers
local methods = "GET PUT POST DELETE"
for method in string.gmatch(methods, "[^ ]+") do
  app[method:lower()] = function (route, handler)
    routes[#routes + 1] = {
      method = method,
      path = compileRoute(route),
      handler = handler
    }
    print("Route Added: " .. method .. " " .. route)
    return app
  end
end

-- Allow general plugins
function app.use(handler)
  routes[#routes + 1] = { handler = handler }
  return app
end

function app.listen(addr, port)
  createServer(addr, port, handleConnection)
  print("HTTP server listening at http://" .. addr .. ":" .. port .. "/")
  return app
end

-- Return the chaining app directly
return app
