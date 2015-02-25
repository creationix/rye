-- Load the git-serve web library
local gitServe = require('git-serve')

-- Load the git repo into a coroutine based filesystem abstraction
-- Wrap it some midl-level sugar to make it suitable for git
-- Create a git database interface around the storage layer
local fs = require('coro-fs').chroot('luvit.io.git')
local storage = require('storage-fs')(fs)
local db = require('git-fs')(storage)

-- Create three instances of the gitServe app using different refs in our
-- local git repo.  A cron job or post commit hook will `git fetch ...` these
-- to keep the database up to date. Eventually rye can poll for updates on a
-- smart interval based on requests.
local luvitApp = gitServe(db, "refs/remotes/luvit.io/master")
local exploderApp = gitServe(db, "refs/remotes/exploder.creationix.com/master")
local creationixApp = gitServe(db, "refs/remotes/creationix.com/master")

-- Configure the web app
require('web-app')

  -- Declare the host and port to bind to.
  .bind({host="0.0.0.0", port=8080})

  -- Set an outer middleware for logging requests and responses
  .use(function (req, res, go)
    -- Run all inner layers first.
    go()
    -- And then log after everything is done
    print(string.format("%s %s %s %s", req.method,  req.path, req.headers["User-Agent"], res.code))
  end)

  -- Mount the git app on three virtual hosts
  .route({ method="GET", host="^luvit.localdomain" }, luvitApp)
  .route({ method="GET", host="^exploder.localdomain" }, exploderApp)
  .route({ method="GET", host="^creationix.localdomain" }, creationixApp)

  -- Mount them again, but on subpaths instead of virtual hosts
  .route({ method="GET", path="/luvit/:path:" }, luvitApp)
  .route({ method="GET", path="/exploder/:path:" }, exploderApp)
  .route({ method="GET", path="/creationix/:path:" }, creationixApp)

  -- Bind the ports, start the server and begin listening for and accepting connections.
  .start()
