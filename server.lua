local gitServe = require('git-serve')

coroutine.wrap(function ()
  local db = require('git-fs')(require('storage-fs')(require('coro-fs').chroot('luvit.io.git')))

  require('web-app')
    .listen({host="0.0.0.0", port=8080})
    .use(function (req, res, go)
      go()
      print(string.format("%s %s %s %s", req.method,  req.path, req.headers["User-Agent"], res.code))
    end)
    .route({ method = "GET", host = "^luvit.localdomain", path = "/:path:" },
      gitServe(db, "refs/remotes/luvit.io/master"))
    .route({ method = "GET", host = "^exploder.localdomain", path = "/:path:" },
      gitServe(db, "refs/remotes/exploder.creationix.com/master"))
    .route({ method = "GET", host = "^creationix.localdomain", path = "/:path:" },
      gitServe(db, "refs/remotes/creationix.com/master"))
    .route({ method = "GET", path = "/luvit/:path:" },
      gitServe(db, "refs/remotes/luvit.io/master"))
    .route({ method = "GET", path = "/exploder/:path:" },
      gitServe(db, "refs/remotes/exploder.creationix.com/master"))
    .route({ method = "GET", path = "/creationix/:path:" },
      gitServe(db, "refs/remotes/creationix.com/master"))
    .start()

end)()


