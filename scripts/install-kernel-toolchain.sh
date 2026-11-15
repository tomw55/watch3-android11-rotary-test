#!/usr/bin/env bash
# Print the absolute CROSS_COMPILE prefix after installing the audited toolchain.
set -euo pipefail
[[ $# == 1 && $(uname -m) == x86_64 ]] || {
    echo "Usage (x86_64 Linux): $0 TOOLCHAIN_DIRECTORY" >&2
    exit 2
}
archive=x86_64-gcc-7.5.0-nolibc-aarch64-linux.tar.xz
sha256=2399ecb4d622810e47096e931a7f21b6edb136844a4064f5c0983b5879b1bdf9
mkdir -p "$1"
cd "$1"
if [[ ! -f $archive ]]; then
    curl --fail --location --retry 3 \
        "https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/x86_64/7.5.0/$archive" \
        -o "$archive.part"
    mv "$archive.part" "$archive"
fi
printf '%s  %s\n' "$sha256" "$archive" | sha256sum -c - >&2
tar -xJf "$archive"
prefix="$PWD/gcc-7.5.0-nolibc/aarch64-linux/bin/aarch64-linux-"
[[ $("${prefix}gcc" -dumpmachine) == aarch64-linux ]]
"${prefix}gcc" --version >&2
"${prefix}ld" --version >&2
printf '%s\n' "$prefix"
