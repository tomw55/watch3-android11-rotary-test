#!/system/bin/sh
set -eu
# Split-policy input order and compiler flags from AOSP android-11.0.0_r48
# system/core/init/selinux.cpp, LoadSplitPolicy(). The target version is 30.
out=$(mktemp -d /data/local/tmp/watch3-policy.XXXXXX)
published=/data/local/tmp/watch3-policy-v30
mkdir "$published"
version=$(cat /vendor/etc/selinux/plat_sepolicy_vers.txt)
case "$version" in ''|*[!0-9.]*) echo "Invalid vendor mapping version"; exit 1;; esac
printf 'vendor_mapping=%s\n' "$version"
set -- "/system/etc/selinux/plat_sepolicy.cil" "/system/etc/selinux/mapping/$version.cil"
for optional in "/system/etc/selinux/mapping/$version.compat.cil" \
    /system_ext/etc/selinux/system_ext_sepolicy.cil "/system_ext/etc/selinux/mapping/$version.cil" \
    /product/etc/selinux/product_sepolicy.cil "/product/etc/selinux/mapping/$version.cil"; do
    if [ -f "$optional" ]; then set -- "$@" "$optional"; fi
done
vendor=/vendor/etc/selinux
if [ -f "$vendor/vendor_sepolicy.cil" ]; then
    set -- "$@" "$vendor/plat_pub_versioned.cil" "$vendor/vendor_sepolicy.cil"
else
    set -- "$@" "$vendor/nonplat_sepolicy.cil"
fi
odm=/odm/etc/selinux/odm_sepolicy.cil
if [ -f "$odm" ]; then set -- "$@" "$odm"; fi
for input do
    test -r "$input"
    sha256sum "$input"
done
/system/bin/secilc -m -M true -G -N -c 30 "$@" -o "$out/policy.bin" -f /dev/null 2>&1
mv "$out/policy.bin" "$published/policy.bin"
