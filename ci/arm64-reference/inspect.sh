#!/usr/bin/env bash
set -euo pipefail
out="$PWD/arm64-reference-evidence"
mkdir -p "$out"
stage=download
trap 'rc=$?; printf "stage=%s exit=%s\n" "$stage" "$rc" > "$out/result.txt"' EXIT
work=$(mktemp -d)
archive="$work/reference.zip"
url='https://dl.google.com/android/repository/sys-img/google_apis/arm64-v8a-30_r16.zip'
printf '%s\n' "$url" > "$out/source-url.txt"
curl -fL --retry 3 -o "$archive" "$url" 2>&1 | tee "$out/download.log"
test "$(stat -c %s "$archive")" = 1244324730
echo "0e66987d6b4db2e278af83d453ce5d74a7e6ced3  $archive" | sha1sum -c - | tee "$out/archive-verification.txt"
sha256sum "$archive" > "$out/archive-sha256.txt"
unzip -l "$archive" > "$out/archive-members.txt"
unzip -oq "$archive" -d "$work/extracted"
metadata=$(find "$work/extracted" -maxdepth 2 -name source.properties -print -quit)
test -n "$metadata"
image=$(dirname "$metadata")
cp "$image/source.properties" "$out/"
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*16$' "$image/source.properties"
stage=inventory
(cd "$image" && find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 -r sha256sum) > "$out/SHA256SUMS"
file "$image"/* > "$out/file-types.txt"
# SDK system/vendor partitions can be Android sparse or raw ext4.
for part in system vendor; do
    input="$image/$part.img"
    raw="$work/$part.raw"
    if [[ $(od -An -N4 -tx1 "$input" | tr -d '[:space:]') == 3aff26ed ]]; then
        simg2img "$input" "$raw"
    else
        raw="$input"
    fi
    debugfs -R 'ls -l /' "$raw" > "$out/$part-root.txt" 2>&1
    for tree in / /system; do
        for dir in etc etc/init etc/selinux; do
            debugfs -R "ls -l ${tree%/}/$dir" "$raw" >> "$out/$part-layout.txt" 2>&1
        done
    done
    if [[ $part == system ]]; then
        for init in /bin/init /system/bin/init; do
            debugfs -R "dump $init $work/init" "$raw" >> "$out/init-inspection.txt" 2>&1
            if [[ -s "$work/init" ]]; then break; fi
        done
        readelf -h -l -d "$work/init" >> "$out/init-inspection.txt"
        grep -q 'AArch64' "$out/init-inspection.txt"
    fi
done
stage=inventory_complete
printf '%s\n' 'ARM64 init and storage image inventory complete.' \
 'Guest boot, Android policy load and second-stage init: NOT RUN.' > "$out/scope.txt"
