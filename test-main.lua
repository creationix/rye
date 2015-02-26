local luvi = require('luvi')
luvi.bundle.register('require', "deps/require.lua")
local require = require('require')("bundle:main.lua")
_G.p = require('pretty-print').prettyPrint
coroutine.wrap(function ()

  local fs = require('coro-fs')
  local storage = require('storage-fs')(fs.chroot('sites.git'))
  local db = require('git-fs')(storage)

  local modes = require('git').modes

  local function walkTree(hash)
    local tree = db.loadAs("tree", hash)
    for i = 1, #tree do
      local entry = tree[i]
      if entry.mode == modes.tree then
        walkTree(entry.hash)
      elseif modes.isBlob(entry.mode) then
        db.loadAs("blob", entry.hash)
      end
    end
  end

  local function walkCommit(hash)
    print("commit", hash)
    local commit = db.loadAs("commit", hash)
    print(commit.message)
    walkTree(commit.tree)
    for i = 1, #commit.parents do
      walkCommit(commit.parents[i])
    end
  end

  walkCommit("refs/remotes/luvit.io/master")
  walkCommit("refs/remotes/exploder.creationix.com/master")
  walkCommit("refs/remotes/creationix.com/master")
  walkCommit("refs/remotes/conquest.creationix.com/master")

end)()
require('uv').run()

