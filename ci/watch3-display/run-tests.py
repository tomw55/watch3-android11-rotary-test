#!/usr/bin/env python3
"""Strict host regression/sanitizer/mutation checks. No device access."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def run(command, **kwargs):
    print("+", " ".join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--archive", type=Path, help="also rederive against the pinned ZIP")
    ap.add_argument("--no-lsan", action="store_true", help="explicitly mark leak sanitizer NOT RUN (e.g. ptrace sandbox)")
    ap.add_argument("--cross-cc", help="optionally compile all sources for AArch64 without executing them")
    args = ap.parse_args()
    if args.archive:
        run(["python3", ROOT / "extract-abi.py", args.archive, "--check"])
    cc = os.environ.get("CC", "cc")
    run([cc, "--version"])
    print("HOST", platform.platform(), flush=True)
    # Independently verify the manifest, without following entries outside this fixture.
    for line in (ROOT / "SOURCE_SHA256SUMS").read_text().splitlines():
        digest, name = line.split("  ", 1)
        path = (ROOT / name).resolve()
        if not path.is_relative_to(ROOT) or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise SystemExit(f"FAIL manifest: {name}")
    print("PASS source/fixture manifest", flush=True)
    common = [cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic", "-O1", "-g",
              "-I", ROOT, "-I", ROOT / "abi"]
    sources = [ROOT / "model.c", ROOT / "abi/source_oracle.c", ROOT / "tests.c"]
    with tempfile.TemporaryDirectory(prefix="watch3-display-") as tmp:
        tmp = Path(tmp)
        binary = tmp / "tests"
        run(common + sources + ["-o", binary])
        run([binary])
        symbols = subprocess.check_output(["nm", "-u", binary], text=True)
        for name in ("open", "open64", "ioctl", "mmap", "socket", "connect"):
            if any(line.split()[-1].split("@")[0] == name for line in symbols.splitlines()):
                raise SystemExit(f"FAIL unexpected device/network entry point: {name}")
        print("PASS compiled fixture imports no open/ioctl/mmap/socket/connect", flush=True)
        if args.cross_cc:
            triple = subprocess.check_output([args.cross_cc, "-dumpmachine"], text=True).strip()
            if not triple.startswith("aarch64"):
                raise SystemExit(f"FAIL cross compiler is not AArch64: {triple}")
            for i, source in enumerate(sources):
                run([args.cross_cc] + common[1:] + ["-c", source, "-o", tmp / f"arm64-{i}.o"])
                header = (tmp / f"arm64-{i}.o").read_bytes()[:20]
                if header[:6] != b"\x7fELF\x02\x01" or int.from_bytes(header[18:20], "little") != 183:
                    raise SystemExit("FAIL cross output is not ELF64 little-endian AArch64")
            print("PASS actual AArch64 compilation and ABI static assertions (not runtime)", flush=True)
        sanitized = tmp / "sanitized"
        run(common + ["-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-fno-pie", "-no-pie"]
            + sources + ["-o", sanitized])
        env = dict(os.environ, ASAN_OPTIONS=f"detect_leaks={int(not args.no_lsan)}:abort_on_error=1",
                   UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
        run([sanitized], env=env)
        # These mutations must compile and fail an actual assertion, not merely fail to build.
        mutations = {
            "unsafe-buffer-release": ("ops->quiescent(ops->ctx) != 1", "0"),
            "missing-width-validation": ("b->width != 360 || ", ""),
            "wrong-format-mapping": ("case W3_RGBA8888: *out = DECON_PIXEL_FORMAT_RGBA_8888;",
                                     "case W3_RGBA8888: *out = DECON_PIXEL_FORMAT_BGRA_8888;"),
            "ignore-duplicate-failure": ("return error;\n        }", "return error == -EMFILE ? 0 : error;\n        }"),
            "accept-missing-retire": ("if (returned < 0) return -EPROTO;", "/* mutant */"),
        }
        original = (ROOT / "model.c").read_text()
        for name, (old, new) in mutations.items():
            if original.count(old) != 1:
                raise SystemExit(f"FAIL mutation anchor: {name}")
            source = tmp / (name + ".c")
            source.write_text(original.replace(old, new))
            mutant = tmp / name
            run(common + [source] + sources[1:] + ["-o", mutant])
            result = subprocess.run([mutant], text=True, capture_output=True)
            if result.returncode == 0 or "Assertion" not in result.stderr:
                raise SystemExit(f"FAIL mutation not detected by assertion: {name}: {result.stderr}")
            print(f"PASS detected compiled mutant {name}: {result.stderr.strip()}", flush=True)
        # ABI regressions must be caught at compile time.
        for name, old, new in [("wrong-window-count", "#define MAX_DECON_WIN\t\t3", "#define MAX_DECON_WIN\t\t7"),
                               ("wrong-dma-width", "typedef uint64_t dma_addr_t;", "typedef uint32_t dma_addr_t;")]:
            isolated = tmp / name
            (isolated / "abi").mkdir(parents=True)
            shutil.copy(ROOT / "model.h", isolated / "model.h")
            shutil.copy(ROOT / "tests.c", isolated / "tests.c")
            text = (ROOT / "abi/watch3_decon_abi.h").read_text()
            if text.count(old) != 1:
                raise SystemExit(f"FAIL ABI mutation anchor: {name}")
            (isolated / "abi/watch3_decon_abi.h").write_text(text.replace(old, new))
            result = subprocess.run(common + ["-fsyntax-only", isolated / "tests.c"],
                                    text=True, capture_output=True)
            if result.returncode == 0 or "static assertion failed" not in result.stderr:
                raise SystemExit(f"FAIL ABI mutant not caught: {name}: {result.stderr}")
            print(f"PASS ABI compile-time negative control {name}", flush=True)
    print("PASS host regression + ASan/UBSan + 5 executed mutants + 2 ABI negative controls")
    print("NOT RUN LSan (explicit --no-lsan)" if args.no_lsan else "PASS LSan")
    if not args.cross_cc:
        print("NOT RUN ARM64 target compilation (no --cross-cc provided)")
    print("NOT RUN Android HAL build/runtime, dma-buf allocation, physical scanout")


if __name__ == "__main__":
    main()
