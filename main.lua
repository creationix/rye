local luvi = require('luvi')
luvi.bundle.register('require', "modules/require.lua")
local require = require('require')()("bundle:main.lua")
_G.p = require('pretty-print').prettyPrint

require('./lib/web-app')
