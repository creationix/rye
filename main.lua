local luvi = require('luvi')
luvi.bundle.register('require', "deps/require.lua")
local require = require('require')("bundle:main.lua")
_G.p = require('pretty-print').prettyPrint
coroutine.wrap(require)('./server')
require('uv').run()
