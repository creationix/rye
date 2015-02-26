return function (req, res, go)
  -- Run all inner layers first.
  go()
  -- And then log after everything is done
  print(string.format("%s %s %s", req.method,  req.path, res.code))
end
