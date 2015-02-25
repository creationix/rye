local db
coroutine.wrap(function ()
  db = require('git-fs')(
    require('storage-fs')(
      require('coro-fs').chroot('luvit.io.git')
    )
  )

  p(db.loadAny("HEAD"))
end)()

-- local people = {
--   tim = 32,
--   jack = 8,
-- }


-- require('web-app')

-- .get("/:name", function (name)
--   local age = people[name]
--   if not age then return end
--   return 200, name .. " is " .. age .. " years old\n"
-- end)

-- .put("/:name/:age", function (name, age)
--   people[name] = age
--   return 204
-- end)

-- .get("/:path:", function (path)
--   local parts = {}
--   for part in path:gmatch("[^/]+") do
--     parts[#parts + 1] = part
--   end
--   p(parts)
-- end)

-- .use(function (req, res)
--   -- This can be a generic middleware plugin
--   p(req)
-- end)

-- .listen("0.0.0.0", 8080)

