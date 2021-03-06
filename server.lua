-- Load the git-serve web library
local gitServe = require('git-serve')

-- Grab an internal library from luvi for convenience
local bundle = require('luvi').bundle

-- Load the git repo into a coroutine based filesystem abstraction
-- Wrap it some midl-level sugar to make it suitable for git
-- Create a git database interface around the storage layer
local fs = require('coro-fs')
local storage = require('storage-fs')(fs.chroot('sites.git'))
local db = require('git-fs')(storage)
-- Add an in-memory cache for all git objects under 200k with a total
-- max cache size of 2mb
require('git-hash-cache')(db, 200000, 2000000)

-- Cache all ref lookups for 1000ms
require('git-ref-cache')(db, 1000)

-- Create three instances of the gitServe app using different refs in our
-- local git repo.  A cron job or post commit hook will `git fetch ...` these
-- to keep the database up to date. Eventually rye can poll for updates on a
-- smart interval based on requests.
local luvitApp = gitServe(db, "refs/remotes/luvit.io/master")
local exploderApp = gitServe(db, "refs/remotes/exploder.creationix.com/master")
local creationixApp = gitServe(db, "refs/remotes/creationix.com/master")
local conquestApp = gitServe(db, "refs/remotes/conquest.creationix.com/master")

-- Configure the web app
require('web-app')

  -- Declare the host and port to bind to.
  .bind({host="0.0.0.0", port=8080})

  -- Set an outer middleware for logging requests and responses
  .use(require('logger'))

  -- This adds missing headers, and tries to do automatic cleanup.
  .use(require('auto-headers'))

  -- A caching proxy layer for backends supporting Etags
  .use(require('etag-cache'))

  .route({ method="GET", path="/" }, function (req, res, go)
    -- Render a dynamic welcome page for clients with a user-agent
    local userAgent = req.headers["User-Agent"]
    if not userAgent then return go() end
    local template = bundle.readfile("index.html")
    res.code = 200
    res.body = template:gsub("%%USER_AGENT%%", userAgent)
    res.headers["Content-Type"] = "text/html"
  end)

  -- Mount the git app on three virtual hosts
  .route({ method="GET", host="luvit.localdomain*" }, luvitApp)
  .route({ method="GET", host="exploder.localdomain*" }, exploderApp)
  .route({ method="GET", host="creationix.localdomain*" }, creationixApp)
  .route({ method="GET", host="conquest.localdomain*" }, conquestApp)

  -- Mount them again, but on subpaths instead of virtual hosts
  .route({ method="GET", path="/luvit/:path:" }, luvitApp)
  .route({ method="GET", path="/exploder/:path:" }, exploderApp)
  .route({ method="GET", path="/creationix/:path:" }, creationixApp)
  .route({ method="GET", path="/conquest/:path:" }, conquestApp)

  -- Bind the ports, start the server and begin listening for and accepting connections.
  .start()
