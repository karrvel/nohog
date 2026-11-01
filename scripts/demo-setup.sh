#!/bin/zsh
# Sample projects for the README demo (docs/demo.tape). Everything lives in /tmp/nohog-demo.
set -euo pipefail
demo=/tmp/nohog-demo
rm -rf "$demo"

files() { # files <dir> <count>: empty placeholder files spread over subfolders
  local dir=$1 count=$2 i
  for ((i = 0; i < count; i++)); do
    (( i % 200 == 0 )) && mkdir -p "$dir/pkg-$((i / 200))"
    : > "$dir/pkg-$((i / 200))/file-$i.js"
  done
}

mkdir -p "$demo"/{webapp/src,api/src,mobile,ml,docs/build}
touch "$demo/webapp/package.json" "$demo/api/Cargo.toml" "$demo/mobile/Podfile" "$demo/ml/requirements.txt"
files "$demo/webapp/node_modules" 12000
files "$demo/api/target" 2500
files "$demo/mobile/Pods" 1800
files "$demo/ml/venv" 3200
files "$demo/docs/build" 40   # no build.gradle/CMakeLists.txt next to it: stays searchable
