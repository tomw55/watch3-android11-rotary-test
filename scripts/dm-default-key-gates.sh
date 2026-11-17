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
if ! dmsetup targets | grep -Eq '^default-key[[:space:]]+v2\.0\.0$'; then
  echo 'FAIL gate1: default-key v2.0.0 not registered' >&2; exit 1
fi
echo 'PASS gate1: default-key v2.0.0 registered'
backing="$DK_TEST_DIR/dm-default-key-disposable.img"
[ ! -e "$backing" ] || { echo 'FAIL: backing file already exists' >&2; exit 1; }
trap 'dmsetup remove dk_err_test 2>/dev/null || :; dmsetup remove dk_err_backing 2>/dev/null || :; dmsetup remove dk_test 2>/dev/null || :; [ -z "${loop:-}" ] || losetup -d "$loop" 2>/dev/null || :; rm -f "$backing"' EXIT HUP INT TERM
dd if=/dev/zero of="$backing" bs=4096 count=128 2>/dev/null
loop=$(losetup -f --show "$backing")
key=$(cat "$DK_VECTOR_DIR/xts-key.hex")
# The offset is expressed in 512-byte sectors: 16 sectors => DUN 2.
printf '0 1024 default-key AES-256-XTS %s 16 %s 0 2 sector_size:4096 iv_large_sectors\n' "$key" "$loop" | dmsetup create dk_test
dd if="$DK_VECTOR_DIR/xts-plain-4096.bin" of=/dev/mapper/dk_test bs=4096 count=1 conv=notrunc 2>/dev/null
dd if="$loop" of="$DK_TEST_DIR/cipher.bin" bs=4096 count=1 2>/dev/null
if ! cmp -s "$DK_TEST_DIR/cipher.bin" "$DK_VECTOR_DIR/xts-offset16-4096.bin"; then
  echo 'FAIL gate2: raw ciphertext differs from independent AES-XTS reference' >&2; exit 1
fi
echo 'PASS gate2: AES-256-XTS 4KiB offset16 DUN2 ciphertext'
# Constructor rejection checks. These exercise ctr() independently of data I/O.
expect_reject() {
  name="$1"; shift
  if printf '%s\n' "$*" | dmsetup create "$name" 2>"$DK_TEST_DIR/$name.err"; then
    dmsetup remove "$name" || :
    echo "FAIL constructor: $name unexpectedly accepted" >&2
    exit 1
  fi
  echo "PASS constructor rejection: $name"
}
expect_reject dk_bad_iv "0 512 default-key AES-256-XTS $key 4 $loop 0 2 sector_size:4096 iv_large_sectors"
expect_reject dk_bad_start "0 512 default-key AES-256-XTS $key 0 $loop 4 2 sector_size:4096 iv_large_sectors"
expect_reject dk_bad_sector "0 512 default-key AES-256-XTS $key 0 $loop 0 2 sector_size:512 iv_large_sectors"
expect_reject dk_bad_ivmode "0 512 default-key AES-256-XTS $key 0 $loop 0 1 sector_size:4096"
echo 'PASS constructor rejection suite'
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
# Large-bio round trip: 256 KiB, aligned to the encryption data unit.
dd if=/dev/urandom of="$DK_TEST_DIR/large-plain.bin" bs=65536 count=4 2>/dev/null
dd if="$DK_TEST_DIR/large-plain.bin" of=/dev/mapper/dk_test bs=65536 count=4 conv=notrunc,fsync 2>/dev/null
dd if=/dev/mapper/dk_test of="$DK_TEST_DIR/large-read.bin" bs=65536 count=4 2>/dev/null
cmp "$DK_TEST_DIR/large-plain.bin" "$DK_TEST_DIR/large-read.bin"
echo 'PASS large I/O: 256 KiB round trip with fsync'
# Discard must not silently succeed on the non-discard table.
if command -v blkdiscard >/dev/null 2>&1; then
  if blkdiscard /dev/mapper/dk_test 2>"$DK_TEST_DIR/discard.err"; then
    echo 'FAIL discard: succeeded without allow_discards' >&2; exit 1
  fi
  echo 'PASS discard: rejected without allow_discards'
else
  echo 'SKIP discard: blkdiscard not installed'
fi
# The error target is independent of the disposable backing image.
dmsetup create dk_err_backing --table '0 64 error'
if ! printf '0 64 default-key AES-256-XTS %s 0 /dev/mapper/dk_err_backing 0 2 sector_size:4096 iv_large_sectors\n' "$key" | dmsetup create dk_err_test; then
  dmsetup remove dk_err_backing || :
  echo 'FAIL error propagation: could not construct stacked target' >&2; exit 1
fi
if dd if=/dev/mapper/dk_err_test of=/dev/null bs=4096 count=1 iflag=direct 2>"$DK_TEST_DIR/error-read.err"; then
  echo 'FAIL error propagation: read unexpectedly succeeded' >&2; exit 1
fi
if dd if="$DK_VECTOR_DIR/xts-plain-4096.bin" of=/dev/mapper/dk_err_test bs=4096 count=1 oflag=direct 2>"$DK_TEST_DIR/error-write.err"; then
  echo 'FAIL error propagation: write unexpectedly succeeded' >&2; exit 1
fi
dmsetup remove dk_err_test
dmsetup remove dk_err_backing
echo 'PASS error propagation: failed reads and writes, successful teardown'
echo 'NOT TESTED: direct bio-level misalignment, FUA ordering, leak injection, async crypto faults'
