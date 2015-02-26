# rye
A git based publishing platform implemented in lua

This is a work in progress.  The goal is to re-implement the [wheaty](https://github.com/creationix/wheaty) platform in lua.

So far it can render static sites directly from git repos on disk.

## Test it out!

 1. Clone this repo.
 2. Run the setup script.
 3. [Install lit](https://github.com/luvit/lit#installing-lit).
 4. Build rye using lit.
 5. Run the new `rye` executable.
 6. Open the test page in a browser.

```sh
git clone https://github.com/creationix/rye.git
cd rye
./setup.sh
curl -L https://github.com/luvit/lit/raw/master/get-lit.sh | sh
./lit make
./rye
```
