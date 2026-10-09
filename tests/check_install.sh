#!/bin/sh
# install.sh runs under macOS's bash 3.2, which treats the bytes of a
# non-ASCII character right after "$name" as part of the variable's name
# ("version…" -> "unbound variable"). Require the ${name} form everywhere.
script="$(dirname "$0")/../install.sh"
bash -n "$script" || exit 1
if grep -nE '\$[A-Za-z_]' "$script"; then
  echo "install.sh: write these variables as \${name} (see above)"
  exit 1
fi
echo "install.sh ok"
