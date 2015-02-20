local compileRoute = require('./compile-route')

local blob = compileRoute("/blobs/:hash/:path:")
p(blob("/blobs/thisishash/foo/bar"))
local package = compileRoute("/packages/:author/:name:/v:version")
p(package("/packages/creationix/web/routes/v1.2.3"))

return compileRoute
