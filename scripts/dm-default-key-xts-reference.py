#!/usr/bin/env python3
"""Independent AES-256-XTS reference vectors for dm-default-key CI.

Requires Python cryptography. This is a HOST reference generator, not a
kernel test. The guest harness must compare backing-device ciphertext.
"""
import argparse
import hashlib
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

KEY = bytes(range(64))
PLAINTEXT = bytes((i * 29 + 7) & 0xff for i in range(4096))

def encrypt(plain, iv_offset, rel_sector, sector_size=4096):
    sectors_per_unit = sector_size // 512
    assert sector_size == 4096
    assert (iv_offset + rel_sector) % sectors_per_unit == 0
    dun = (iv_offset + rel_sector) // sectors_per_unit
    tweak = dun.to_bytes(16, "little")
    cipher = Cipher(algorithms.AES(KEY), modes.XTS(tweak))
    ctx = cipher.encryptor()
    return ctx.update(plain) + ctx.finalize()

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--output", required=True, help="directory for reference vectors")
    args = p.parse_args()
    from pathlib import Path
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    (out / "xts-key.hex").write_text(KEY.hex() + "\n")
    (out / "xts-plain-4096.bin").write_bytes(PLAINTEXT)
    for offset, sector, label in [(0, 0, "zero"), (16, 0, "offset16"), (16, 8, "offset16-sector8")]:
        ct = encrypt(PLAINTEXT, offset, sector)
        name = f"xts-{label}-4096.bin"
        (out / name).write_bytes(ct)
        print(f"{label}: iv_offset={offset} rel_sector={sector} dun={(offset + sector) // 8} sha256={hashlib.sha256(ct).hexdigest()}")
    assert encrypt(PLAINTEXT, 16, 0) != encrypt(PLAINTEXT, 0, 16 * 8), "offset regression"
    assert encrypt(PLAINTEXT, 16, 0) == encrypt(PLAINTEXT, 0, 16), "IV units regression"
    print("PASS: independent AES-XTS reference generation and offset checks")

if __name__ == "__main__":
    main()
