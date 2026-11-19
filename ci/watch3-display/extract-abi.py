#!/usr/bin/env python3
"""Derive a host ABI fixture from the exact source ZIP; execute no archive code."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

ARCHIVE_SHA = "1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f"
BASE = "drivers/video/fbdev/exynos/dpu_9110/"
PINNED = {
    BASE + "decon.h": "1c3f1c07f3af9362955085506585f0c6bc2b82da0d1e1c620f2d3e78b65090ae",
    BASE + "decon_core.c": "0f19ec0bf5440c162a9f97b343fbab7fe0af5baa9a97de9d7f6ca8b3d021c1ff",
    BASE + "helper.c": "a7b64669752f8422191b97fcca7e9e2722875544f0873b3b1e2417eebc718337",
    "arch/arm64/configs/tizen_noblesse_defconfig": "df517a69a19109107101dfcfd7ae690cd36c24ac0486fc22ff88690372b2fce6",
}


def declaration(source, prefix):
    """Copy an entire balanced declaration, including anonymous unions."""
    starts = list(re.finditer(r"(?m)^" + re.escape(prefix) + r"\s*\{", source))
    if len(starts) != 1:
        raise ValueError(f"expected one declaration: {prefix}")
    start = starts[0].start()
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if prefix.startswith(("struct ", "enum ")):
        assert source[end] == ";"
        end += 1
    return source[start:end], source.count("\n", 0, start) + 1


def derive(sources, sync_symbols):
    header = sources[BASE + "decon.h"]
    names = ["enum decon_idma_type", "enum decon_pixel_format", "enum decon_blending",
             "enum dpp_rotate", "enum dpp_csc_eq", "enum dpp_comp_src",
             "enum dpp_hdr_standard", "struct decon_win_rect", "struct dpp_params",
             "struct decon_frame", "struct decon_win_config", "struct decon_win_config_data"]
    blocks = [declaration(header, name) for name in names]
    constants = [re.search(r"(?m)^#define " + n + r"\s+\d+", header).group()
                 for n in ["MAX_PLANE_CNT", "MAX_DECON_WIN"]]
    ioctl = re.search(r"(?m)^#define S3CFB_WIN_CONFIG[^\n]+\\\n[^\n]+", header).group()
    preamble = header[:header.index("#ifndef")] + """
/* Generated host fixture, not an installed UAPI header or a device driver.
 * dma_addr_t is 64-bit in the pinned ARM64 Noblesse defconfig, line 29.
 * No packed attribute: preserve natural AAPCS64 alignment.
 */
#ifndef WATCH3_DECON_ABI_H
#define WATCH3_DECON_ABI_H
#include <stdbool.h>
#include <stdint.h>
#include <sys/ioctl.h>
typedef uint32_t u32;
typedef uint32_t __u32;
typedef uint64_t dma_addr_t;
"""
    generated = preamble + "\n".join(constants) + "\n\n"
    generated += "\n\n".join(f"/* decon.h:{line} */\n{block}" for block, line in blocks)
    generated += "\n\n" + ioctl + "\n#endif\n"
    helper, line = declaration(sources[BASE + "helper.c"], "u32 dpu_translate_fmt_to_dpp(u32 format)")
    core = sources[BASE + "decon_core.c"]
    # Copy the real kernel validation body; replace its unused device argument
    # and kernel logging only. This is a test oracle, not the driver itself.
    start = core.index("int decon_check_limitation(")
    body_start = core.index("{", start)
    depth, end = 1, body_start + 1
    while depth:
        depth += (core[end] == "{") - (core[end] == "}")
        end += 1
    body = core[body_start:end]
    body = body.replace("{", "{\n\t(void)idx;", 1)
    oracle = sources[BASE + "helper.c"].split("#include", 1)[0] + """
/* Samsung source-derived test oracles. Not a kernel execution test. */
#include <errno.h>
#include "watch3_decon_abi.h"
#define decon_err(...) ((void)0)
""" + f"/* helper.c:{line}: verbatim format translation */\n" + helper
    oracle += "\n/* decon_core.c:1404: body copied; unused device arg/logging removed. */\n"
    oracle += "int source_check_limitation(int idx, struct decon_win_config *config)\n" + body + "\n"
    provenance = {
        "archive_sha256": ARCHIVE_SHA, "source_sha256": PINNED,
        "abi_declarations": [{"name": n, "line": b[1]} for n, b in zip(names, blocks)],
        "assumptions": ["LP64 ARM64; 64-bit dma_addr_t; normal enum width; no packing",
                        "This fixture is not a complete kernel or graphics HAL"],
        "sync_contract": "CONFIG_SYNC guards Android fences; CONFIG_SYNC_FILE alone is insufficient",
        "all_kconfig_sync_definitions": sync_symbols,
    }
    return {"watch3_decon_abi.h": generated, "source_oracle.c": oracle,
            "provenance.json": json.dumps(provenance, indent=2, sort_keys=True) + "\n"}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("archive", type=Path)
    ap.add_argument("--check", action="store_true", help="compare existing generated files without writing")
    args = ap.parse_args()
    with args.archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != ARCHIVE_SHA:
        raise SystemExit("FAIL: source archive SHA-256 mismatch")
    sources = {}
    sync_symbols = {"SYNC": [], "SYNC_FILE": [], "DRM_DMA_SYNC": []}
    with zipfile.ZipFile(args.archive) as z:
        for path, sha in PINNED.items():
            raw = z.read("kernel_samsung_galileo-master/" + path)
            if hashlib.sha256(raw).hexdigest() != sha:
                raise SystemExit(f"FAIL: source member mismatch: {path}")
            sources[path] = raw.decode("utf-8")
        for name in z.namelist():
            if not name.rsplit("/", 1)[-1].startswith("Kconfig"):
                continue
            source = z.read(name).decode("utf-8", errors="replace")
            for match in re.finditer(r"(?m)^\s*(?:menu)?config (SYNC|SYNC_FILE|DRM_DMA_SYNC)\s*$", source):
                sync_symbols[match[1]].append({"path": name.split("/", 1)[1],
                    "line": source.count("\n", 0, match.start()) + 1})
    output = Path(__file__).resolve().parent / "abi"
    for name, content in derive(sources, sync_symbols).items():
        path = output / name
        if args.check:
            if not path.exists() or path.read_bytes() != content.encode():
                raise SystemExit(f"FAIL: generated fixture differs: {name}")
        else:
            output.mkdir(exist_ok=True)
            path.write_bytes(content.encode())
    print("PASS: pinned archive/member hashes and exact ABI/oracle generation")


if __name__ == "__main__":
    main()
