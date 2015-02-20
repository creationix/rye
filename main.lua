local luvi = require('luvi')
luvi.bundle.register('require', "modules/require.lua")
local require = require('require')()("bundle:main.lua")
_G.p = require('pretty-print').prettyPrint

local people = {
  tim = 32,
  jack = 8,
}

require('./lib/web-app')

.get("/:name", function (name)
  local age = people[name]
  if not age then return end
  return 200, name .. " is " .. age .. " years old\n"
end)

.put("/:name/:age", function (name, age)
  people[name] = age
  return 204
end)

.use(function (req, code, headers, body)
  -- This can be a generic middleware plugin
  p{req=req,code=code,headers=headers,body=body}
end)

.listen("0.0.0.0", 8080)

require('uv').run()
