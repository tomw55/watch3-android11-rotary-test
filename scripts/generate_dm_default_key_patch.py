#!/usr/bin/env python3
"""Generate a kernel patch from reviewed raw C, never from pasted Markdown."""
import argparse
import pathlib
import re
import subprocess

def command(*args, cwd):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--kernel", required=True, type=pathlib.Path)
    p.add_argument("--source", required=True, type=pathlib.Path)
    p.add_argument("--output", required=True, type=pathlib.Path)
    a = p.parse_args()
    root = a.kernel.resolve()
    src = a.source.resolve().read_text()
    if any(s in src for s in ("Use code with caution.", "• ", "[L1]")):
        p.error("Pasted formatting contamination in source")
    if not src.startswith("// SPDX-License-Identifier:") or not re.search(
        r"static struct target_type\s+default_key_target\s*=", src
    ):
        p.error("Not a complete standalone driver source")
    if not (root / ".git").exists() or command("git", "status", "--porcelain", cwd=root).stdout.strip():
        p.error("Requires clean disposable Samsung git tree")
    md = root / "drivers/md"
    k, m, c = md / "Kconfig", md / "Makefile", md / "dm-default-key.c"
    original_k, original_m = k.read_text(), m.read_text()
    if c.exists() or original_k.count("endif # MD") != 1 or "config DM_DEFAULT_KEY" in original_k:
        p.error("Target already exists or Kconfig anchor is ambiguous")
    fragment = """config DM_DEFAULT_KEY
    tristate "Default key target support"
    depends on BLK_DEV_DM
    select CRYPTO_SKCIPHER
    select CRYPTO_XTS
    help
      Android metadata encryption default-key target.

"""
    try:
        k.write_text(original_k.replace("endif # MD", fragment + "endif # MD"))
        m.write_text(original_m + "\nobj-$(CONFIG_DM_DEFAULT_KEY) += dm-default-key.o\n")
        c.write_text(src)
        command("git", "add", "-N", "drivers/md/dm-default-key.c", cwd=root)
        diff = command("git", "diff", "--", "drivers/md/Kconfig", "drivers/md/Makefile", "drivers/md/dm-default-key.c", cwd=root).stdout
        if b"dm-default-key.c" not in diff:
            raise RuntimeError("Driver missing from diff")
        out = a.output.resolve()
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(diff)
        command("git", "apply", "--check", "--reverse", str(out), cwd=root)
        print("PASS patch format and reverse application:", out)
        print("NOT VERIFIED: compilation, bio semantics, crypto correctness, QEMU")
    finally:
        k.write_text(original_k)
        m.write_text(original_m)
        command("git", "reset", "-q", "--", "drivers/md/dm-default-key.c", cwd=root)
        c.unlink(missing_ok=True)

if __name__ == "__main__":
    main()
