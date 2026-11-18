#!/usr/bin/env bash
# Read-only ext4 inspection. Output contains metadata and strings, not binaries.
set -euo pipefail
image=${1:?ext4 payload}
report=${2:?report filename}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
: > "$report"
inspect_file() {
    local path=$1
    rm -f "$work/payload"
    debugfs -R "dump $path $work/payload" "$image" > "$work/debugfs.log" 2>&1 || true
    if [[ ! -s "$work/payload" ]]; then
        printf 'ABSENT_OR_UNREADABLE %s\n' "$path" >> "$report"
        return
    fi
    printf '\nFILE %s\n' "$path" >> "$report"
    sha256sum "$work/payload" | awk '{print "SHA256 " $1}' >> "$report"
    file -b "$work/payload" >> "$report"
    if readelf -h "$work/payload" >/dev/null 2>&1; then
        readelf -d "$work/payload" >> "$report"
        readelf --dyn-syms --wide "$work/payload" |
            grep -E 'hw_get_module|HIDL_FETCH|registerAsService|HMI|gralloc|composer|HostConnection' \
            >> "$report" || true
        # Strings show candidate dependencies; they do not prove executed code.
        strings -a "$work/payload" |
            grep -Ei 'goldfish|qemu_pipe|opengles|/dev/(dri|graphics|fb)|minigbm|drm|swiftshader|gralloc|ro.hardware|hwcomposer'             >> "$report" || true
    else
        cat "$work/payload" >> "$report"
    fi
}
for prefix in '' /system; do
    for dir in /lib64/hw /lib/hw /lib64/egl /lib/egl /lib64 /lib /bin/hw                /etc/init /etc/init/hw /etc/vintf /etc/vintf/manifest; do
        path="$prefix$dir"
        printf '\nDIRECTORY %s\n' "$path" >> "$report"
        debugfs -R "ls -p $path" "$image" > "$work/list" 2>&1 || true
        cat "$work/list" >> "$report"
        # debugfs ls -p fields: /inode/mode/uid/gid/name/size/
        while IFS= read -r name; do
            [[ "$name" != . && "$name" != .. && "$name" != */* ]] || continue
            case "$dir/$name" in
                */etc/init/hw/*.rc|*/etc/vintf/*.xml|*/etc/vintf/manifest/*.xml)
                    inspect_file "$path/$name" ;;
                *)
                    if [[ "$name" =~ graphics|gralloc|hwcomposer|EGL|GLES|vulkan|Opengl|renderControl|ranchu.*\.rc$|goldfish.*\.rc$ ]]; then
                        inspect_file "$path/$name"
                    fi ;;
            esac
        done < <(awk -F/ '$1 == "" && $2 ~ /^[0-9]+$/ {print $6}' "$work/list")
    done
done
