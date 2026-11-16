#!/usr/bin/env bash
set -euo pipefail
out="${GITHUB_WORKSPACE:-$PWD}/binder-source-evidence"
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fL --retry 3 --connect-timeout 20 -o "$work/source.zip" \
  https://github.com/tomw55/watch3-android11-rotary-test/releases/download/kernel-source-4.9.59/kernel_samsung_galileo-master.zip
echo '1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f  '"$work/source.zip" | sha256sum -c -
unzip -q "$work/source.zip" 'kernel_samsung_galileo-master/drivers/android/binder.c' 'kernel_samsung_galileo-master/include/uapi/linux/android/binder.h' -d "$work"
cd "$work/kernel_samsung_galileo-master"
for file in drivers/android/binder.c include/uapi/linux/android/binder.h; do
  echo "=== $file ===" | tee -a "$out/anchors.txt"
  grep -nE 'BINDER_SET_CONTEXT_MGR_EXT|BINDER_SET_CONTEXT_MGR|BR_TRANSACTION_SEC_CTX|FLAT_BINDER_FLAG_TXN_SECURITY_CTX|security_task_getsecid|security_cred_getsecid|security_secid_to_secctx|binder_ioctl_set_ctx_mgr|binder_init_node_ilocked|binder_transaction\(|binder_thread_read\(|binder_alloc_new_buf|extra_buffers_size|struct binder_transaction_data|struct binder_node' "$file" | tee -a "$out/anchors.txt" || true
done
cp drivers/android/binder.c "$out/samsung-binder.c"
cp include/uapi/linux/android/binder.h "$out/samsung-binder-uapi.h"
echo 'Diagnostic only: no patch applied and no watch image produced.' | tee "$out/README.txt"
