#!/usr/bin/env bash
set -euo pipefail
tag=android-11.0.0_r48
out=servicemanager-audit
mkdir -p "$out/source"
base="https://android.googlesource.com/platform/frameworks/native/+/refs/tags/$tag/cmds/servicemanager"
for file in Android.bp main.cpp ServiceManager.cpp ServiceManager.h; do
  echo "Fetching pinned AOSP $tag: $file"
  curl --fail --location --retry 4 --retry-all-errors --connect-timeout 20 \
    "$base/$file?format=TEXT" | base64 -d > "$out/source/$file"
  test -s "$out/source/$file"
done
(
  cd "$out/source"
  sha256sum Android.bp main.cpp ServiceManager.cpp ServiceManager.h
) | tee "$out/SHA256SUMS"
grep -Fq 'BINDER_SET_CONTEXT_MGR_EXT' "$out/source/main.cpp" || {
  echo "Pinned AOSP main.cpp does not use expected extended Binder manager ioctl" >&2
  exit 1
}
grep -Fq 'libbinder' "$out/source/Android.bp"
grep -Fq 'libselinux' "$out/source/Android.bp"
{
  echo "AOSP servicemanager source tag: $tag"
  echo "This audit retrieves source and dependencies only. It does NOT build or run servicemanager."
  echo
  echo "Android.bp:"
  cat "$out/source/Android.bp"
  echo
  echo "Extended manager and Binder security references:"
  grep -nE 'BINDER_SET_CONTEXT_MGR_EXT|FLAT_BINDER_FLAG_TXN_SECURITY_CTX|ProcessState|setThreadPoolMaxThreadCount|becomeContextManager|selinux' "$out/source/main.cpp" "$out/source/ServiceManager.cpp" || true
} > "$out/report.txt"
cat "$out/report.txt"
