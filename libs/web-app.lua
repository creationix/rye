--[[
Web App Framework

Middleware Contract:

function middleware(req, res, go)
  req.method
  req.path
  req.params
  req.headers
  req.version
  req.keepAlive
  req.body

  res.code
  res.headers
  res.body

  go() - Run next in chain, can tail call or wait for return and do more

headers is a table/list with numerical headers.  But you can also read and
write headers using string keys, it will do case-insensitive compare for you.

body can be a string or a stream.  A stream is nothing more than a function
you can call repeatedly to get new values.  Returns nil when done.

Response automatic values:
 - Auto Server header
 - Auto Date Header
 - code defaults to 404 with body "Not Found\n"
 - if there is a string body add Content-Length and Etag if missing
 - if string body and no Content-Type, use text/plain for valid utf-8, application/octet-stream otherwise
 - Auto add "; charset=utf-8" to Content-Type when body is known to be valid utf-8
 - Auto 304 responses for if-none-match requests
 - Auto strip body with HEAD requests
 - Auto chunked encoding if body with unknown length
 - if Connection header set and not keep-alive, set res.keepAlive to false
 - Add Connection Keep-Alive/Close if not found based on res.keepAlive


server
  .bind({
    host = "0.0.0.0"
    port = 8080
  })
  .bind({
    host = "0.0.0.0",
    port = 8443,
    tls = true
  })
  .route({
    method = "GET",
    host = "^creationix.com",
    path = "/:path:"
  }, middleware)
  .use(middleware)
  .start()
]]

local createServer = require('coro-tcp').createServer
local wrapper = require('coro-wrapper')
local readWrap, writeWrap = wrapper.reader, wrapper.writer
local httpCodec = require('http-codec')
local digest = require('openssl').digest.digest
local date = require('os').date
local compileRoute = require('compile-route')

local server = {}
local handlers = {}
local bindings = {}

-- Provide a nice case insensitive interface to headers.
local headerMeta = {
  __index = function (list, name)
    if type(name) ~= "string" then
      return rawget(list, name)
    end
    name = name:lower()
    for i = 1, #list do
      local key, value = unpack(list[i])
      if key:lower() == name then return value end
    end
  end,
  __newindex = function (list, name, value)
    if type(name) ~= "string" then
      return rawset(list, name, value)
    end
    local lowerName = name:lower()
    for i = 1, #list do
      local key = list[i][1]
      if key:lower() == lowerName then
        if value == nil then
          table.remove(list, i)
        else
          list[i] = {name, tostring(value)}
        end
        return
      end
    end
    if value == nil then return end
    list[#list + 1] = {name, tostring(value)}
  end,
}

local function handleRequest(head, input)
  local req = {
    method = head.method,
    path = head.path,
    headers = setmetatable({}, headerMeta),
    version = head.version,
    keepAlive = head.keepAlive,
    body = input
  }
  for i = 1, #head do
    req.headers[i] = head[i]
  end

  local res = {
    code = 404,
    headers = setmetatable({}, headerMeta),
    body = "Not Found\n",
  }
  local isHead = false
  if req.method == "HEAD" then
    req.method = "GET"
    isHead = true
  end

  local function run(i)
    local go = i < #handlers
      and function () return run(i + 1) end
      or function () end
    return handlers[i](req, res, go)
  end
  run(1)

  -- We could use the fancy metatable, but this is much faster
  local lowerHeaders = {}
  local headers = res.headers
  for i = 1, #headers do
    local key, value = unpack(headers[i])
    lowerHeaders[key:lower()] = value
  end


  if not lowerHeaders.server then
    headers[#headers + 1] = {"Server", server.name}
  end
  if not lowerHeaders.date then
    headers[#headers + 1] = {"Date", date("!%a, %d %b %Y %H:%M:%S GMT")}
  end

  if not lowerHeaders.connection then
    if req.keepAlive then
      lowerHeaders.connection = "Keep-Alive"
      headers[#headers + 1] = {"Connection", "Keep-Alive"}
    else
      headers[#headers + 1] = {"Connection", "Close"}
    end
  end
  res.keepAlive = lowerHeaders.connection:lower() == "keep-alive"

  local body = res.body
  if body then
    local needLength = not lowerHeaders["content-length"] and not lowerHeaders["transfer-encoding"]
    if type(body) == "string" then
      if needLength then
        headers[#headers + 1] = {"Content-Length", #body}
      end
      if not lowerHeaders.etag then
        local etag = '"' .. digest("sha1", body) .. '"'
        lowerHeaders.etag = etag
        headers[#headers + 1] = {"ETag", etag}
      end
    else
      if needLength then
        headers[#headers + 1] = {"Transfer-Encoding", "chunked"}
      end
    end
    if not lowerHeaders["content-type"] then
      headers[#headers + 1] = {"Content-Type", "text/plain"}
    end
  end

  local etag = res.headers["if-none-match"]
  if etag and res.code >= 200 and res.code < 300 and etag == lowerHeaders.etag then
    res.code = 304
    body = nil
  end

  if isHead then body = nil end
  res.body = body

  local out = {
    code = res.code,
    keepAlive = res.keepAlive,
  }
  for i = 1, #res.headers do
    out[i] = res.headers[i]
  end
  return out, body
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

function server.bind(options)
  bindings[#bindings + 1] = options
  return server
end

function server.use(handler)
  handlers[#handlers + 1] = handler
  return server
end

function server.route(options, handler)
  local method = options.method
  local path = options.path and compileRoute(options.path)
  local host = options.host
  handlers[#handlers + 1] = function (req, res, go)
    if method and req.method ~= method then return go() end
    if host and not (req.headers.host and req.headers.host:match(host)) then return go() end
    local params
    if path then
      params = path(req.path)
      if not params then return go() end
    end
    req.params = params
    return handler(req, res, go)
  end
  return server
end

function server.start()
  for i = 1, #bindings do
    local options = bindings[i]
    -- TODO: handle options.tls
    createServer(options.host, options.port, handleConnection)
    print("HTTP server listening at http://" .. options.host .. ":" .. options.port .. "/")
  end
  return server
end

server.name = "creationix/web-app v" .. require('../package').version

return server
