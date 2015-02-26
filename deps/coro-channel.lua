exports.name = "creationix/coro-channel"
exports.version = "1.0.4"

-- Given a raw uv_stream_t userdara, return coro-friendly read/write functions.
-- Given a raw uv_stream_t userdara, return coro-friendly read/write functions.
function exports.wrapStream(socket)
  local paused = true
  local queue = {}
  local waiting
  local reading = true
  local writing = true

  local onRead

  local function read()
    if #queue > 0 then
      return unpack(table.remove(queue, 1))
    end
    if paused then
      paused = false
      assert(socket:read_start(onRead))
    end
    waiting = coroutine.running()
    return coroutine.yield()
  end

  local flushing = false
  local flushed = false
  local function checkShutdown()
    if socket:is_closing() then return end
    if not flushing and not writing then
      flushing = true
      local thread = coroutine.running()
      socket:shutdown(function (err)
        flushed = true
        coroutine.resume(thread, not err, err)
      end)
      assert(coroutine.yield())
    end
    if flushed and not reading then
      socket:close()
    end
  end

  function onRead(err, chunk)
    local data = err and {nil, err} or {chunk}
    if waiting then
      local thread = waiting
      waiting = nil
      assert(coroutine.resume(thread, unpack(data)))
    else
      queue[#queue + 1] = data
      if not paused then
        paused = true
        assert(socket:read_stop())
      end
    end
    if not chunk then
      reading = false
      -- Close the whole socket if the writing side is also closed already.
      checkShutdown()
    end
  end

  local function write(chunk)
    if chunk == nil then
      -- Shutdown our side of the socket
      writing = false
      checkShutdown()
    else
      -- TODO: add backpressure by pausing and resuming coroutine
      -- when write buffer is full.
      assert(socket:write(chunk))
    end
  end

  return read, write
end


function exports.chain(...)
  local args = {...}
  local nargs = select("#", ...)
  return function (read, write)
    local threads = {} -- coroutine thread for each item
    local waiting = {} -- flag when waiting to pull from upstream
    local boxes = {}   -- storage when waiting to write to downstream
    for i = 1, nargs do
      threads[i] = coroutine.create(args[i])
      waiting[i] = false
      local r, w
      if i == 1 then
        r = read
      else
        function r()
          local j = i - 1
          if boxes[j] then
            local data = boxes[j]
            boxes[j] = nil
            assert(coroutine.resume(threads[j]))
            return unpack(data)
          else
            waiting[i] = true
            return coroutine.yield()
          end
        end
      end
      if i == nargs then
        w = write
      else
        function w(...)
          local j = i + 1
          if waiting[j] then
            waiting[j] = false
            assert(coroutine.resume(threads[j], ...))
          else
            boxes[i] = {...}
            coroutine.yield()
          end
        end
      end
      assert(coroutine.resume(threads[i], r, w))
    end
  end
end
