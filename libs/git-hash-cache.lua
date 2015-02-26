return function (db, limit)
  local hashCache = {}
  local realLoad = db.load
  function db.load(hash)
    local raw = hashCache[hash]
    if raw then return raw end
    raw = realLoad(hash)
    if #raw < limit then
      hashCache[hash] = raw
    end
    return raw
  end
  return db
end
