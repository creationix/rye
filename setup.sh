#!/bin/sh
set -eu
rm -rf sites.git
git init --bare sites.git
cd sites.git
git remote add luvit.io https://github.com/luvit/luvit.io.git
git fetch luvit.io
git remote add creationix.com https://github.com/creationix/creationix.com.git
git fetch creationix.com
git remote add exploder.creationix.com https://github.com/creationix/exploder.git
git fetch exploder.creationix.com
git remote add conquest.creationix.com https://github.com/creationix/conquest.git
git fetch conquest.creationix.com
