#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
lua_bin=${LUA_BIN:-lua}
command -v "$lua_bin" >/dev/null 2>&1 || {
    echo "Lua is required; set LUA_BIN to your Lua interpreter." >&2
    exit 1
}

for script in widgets/*.lua shared/*.lua; do
    [ -f "$script" ] || continue
    "$lua_bin" -e "assert(loadfile('$script'))"
done
"$lua_bin" tests/opencode-go.lua
python3 -m unittest discover -s tests -p 'test_*.py'
