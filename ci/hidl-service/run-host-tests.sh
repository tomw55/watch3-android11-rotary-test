#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
c++ -std=c++17 -Wall -Wextra -Werror -pedantic -pthread "$root/token-store-test.cpp" -o "$work/plain"
"$work/plain"
c++ -std=c++17 -Wall -Wextra -Werror -pedantic -pthread -fsanitize=address,undefined -fno-omit-frame-pointer -no-pie "$root/token-store-test.cpp" -o "$work/sanitized"
ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1:halt_on_error=1}" UBSAN_OPTIONS=halt_on_error=1 "$work/sanitized"
