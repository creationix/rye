local people = {
  tim = 32,
  jack = 8,
}

coroutine.wrap(function ()
  local db = require('git-fs')(
    require('storage-fs')(
      require('coro-fs').chroot('testdb.git')
    )
  )
  p(db)
end)()

require('web-app')

.get("/:name", function (name)
  local age = people[name]
  if not age then return end
  return 200, name .. " is " .. age .. " years old\n"
end)

.put("/:name/:age", function (name, age)
  people[name] = age
  return 204
end)

.use(function (req, res)
  -- This can be a generic middleware plugin
  p(req)
end)

.listen("0.0.0.0", 8080)

