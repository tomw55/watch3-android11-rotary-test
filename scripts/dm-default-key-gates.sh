#!/bin/sh
# Destructive test: ONLY use a dedicated disposable loop device, never /data.
# Requires dmsetup, losetup, dd, cmp, sha256sum and Python reference vectors.
set -eu
: "${DK_TEST_DIR:?Set DK_TEST_DIR to a disposable directory}"
: "${DK_VECTOR_DIR:?Set DK_VECTOR_DIR to generated reference vector directory}"
[ -d "$DK_TEST_DIR" ] && [ -d "$DK_VECTOR_DIR" ]
[ "$DK_TEST_DIR" != / ] && [ "$DK_TEST_DIR" != /data ]
command -v dmsetup >/dev/null
command -v losetup >/dev/null
if ! dmsetup targets | grep -Eq '^default-key[[:space:]]+v2\\.0\\.0$'; then
  echo 'FAIL gate1: default-key v2.0.0 not registered' >&2; exit 1
fi
echo 'PASS gate1: default-key v2.0.0 registered'
backing="$DK_TEST_DIR/dm-default-key-disposable.img"
[ ! -e "$backing" ] || { echo 'FAIL: backing file already exists' >&2; exit 1; }
trap 'dmsetup remove dk_test 2>/dev/null || :; [ -z "${loop:-}" ] || losetup -d "$loop" 2>/dev/null || :; rm -f "$backing"' EXIT HUP INT TERM
dd if=/dev/zero of="$backing" bs=4096 count=64 2>/dev/null
loop=$(losetup -f --show "$backing")
key=$(cat "$DK_VECTOR_DIR/xts-key.hex")
# The offset is expressed in 512-byte sectors: 16 sectors => DUN 2.
printf '0 512 default-key AES-256-XTS %s 16 %s 0 2 sector_size:4096 iv_large_sectors\n' "$key" "$loop" | dmsetup create dk_test
dd if="$DK_VECTOR_DIR/xts-plain-4096.bin" of=/dev/mapper/dk_test bs=4096 count=1 conv=notrunc 2>/dev/null
dd if="$loop" of="$DK_TEST_DIR/cipher.bin" bs=4096 count=1 2>/dev/null
if ! cmp -s "$DK_TEST_DIR/cipher.bin" "$DK_VECTOR_DIR/xts-offset16-4096.bin"; then
  echo 'FAIL gate2: raw ciphertext differs from independent AES-XTS reference' >&2; exit 1
fi
echo 'PASS gate2: AES-256-XTS 4KiB offset16 DUN2 ciphertext'
# Multi-sector plaintext test, using distinct 4KiB blocks and nonzero sectors.
dd if=/dev/urandom of="$DK_TEST_DIR/multi-plain.bin" bs=4096 count=8 2>/dev/null
dd if="$DK_TEST_DIR/multi-plain.bin" of=/dev/mapper/dk_test bs=4096 seek=1 count=8 conv=notrunc 2>/dev/null
dd if=/dev/mapper/dk_test of="$DK_TEST_DIR/multi-read.bin" bs=4096 skip=1 count=8 2>/dev/null
cmp "$DK_TEST_DIR/multi-plain.bin" "$DK_TEST_DIR/multi-read.bin"
dd if="$loop" of="$DK_TEST_DIR/multi-raw.bin" bs=4096 skip=1 count=8 2>/dev/null
if cmp -s "$DK_TEST_DIR/multi-plain.bin" "$DK_TEST_DIR/multi-raw.bin"; then
  echo 'FAIL gate3: backing device contains plaintext' >&2; exit 1
fi
echo 'PASS gate3: multi-sector read/write and ciphertext isolation'
echo 'NOT TESTED: misalignment, flush ordering, discard, injected I/O errors'
