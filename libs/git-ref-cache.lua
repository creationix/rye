local uv = require('uv')

return function (db, timeout)
  local refCache = {}

  local headCache
  local headTime

  local realGetHead = db.getHead
  function db.getHead()
    local now = uv.now()
    if headCache and now < headTime + timeout then
      return headCache
    end
    headCache = realGetHead()
    headTime = now
    return headCache
  end
  local realGetRef = db.getRef
  function db.getRef(ref)
    local cached = refCache[ref]
    local now = uv.now()
    if cached and now < cached.time + timeout then
      return cached.hash
    end
    local hash = realGetRef(ref)
    refCache[ref] = {
      time = now,
      hash = hash
    }
    return hash
  end

end
