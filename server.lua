local gitServe = require('git-serve')

coroutine.wrap(function ()
  local db = require('git-fs')(require('storage-fs')(require('coro-fs').chroot('luvit.io.git')))

  require('web-app')
    .get("/luvit/:path:", gitServe(db, "refs/remotes/luvit.io/master"))
    .get("/exploder/:path:", gitServe(db, "refs/remotes/exploder.creationix.com/master"))
    .get("/creationix/:path:", gitServe(db, "refs/remotes/creationix.com/master"))
    .listen("0.0.0.0", 8080)

end)()


