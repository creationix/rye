return function (db, limit, max)
  local hashCache = {}
  local count = 0
  local realLoad = db.load
  function db.load(hash)
    local raw = hashCache[hash]
    if raw then return raw end
    raw = realLoad(hash)
    local size = #raw
    if size < limit then
      count = count + size
      if count > max then
        print("reset hash cache")
        hashCache = {}
        count = size
      end
      hashCache[hash] = raw
    end
    return raw
  end
  return db
end
