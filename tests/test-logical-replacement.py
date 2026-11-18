"""Exercise checked logical replacement using a synthetic single-device super."""
import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile

module_path = Path(__file__).resolve().parents[1] / "ci/arm64-reference/extract-logical.py"
spec = importlib.util.spec_from_file_location("logical", module_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    disk = bytearray(256 * 1024)
    geometry = bytearray(52)
    struct.pack_into("<II", geometry, 0, 0x616C4467, 52)
    struct.pack_into("<III", geometry, 40, 4096, 2, 4096)
    geometry[8:40] = hashlib.sha256(geometry).digest()
    disk[4096:4148] = geometry
    partition = struct.pack("<36sIIII", b"vendor", 0, 0, 2, 0)
    extents = struct.pack("<QIQI", 8, 0, 128, 0) + struct.pack("<QIQI", 8, 0, 160, 0)
    device = struct.pack("<QIIQ36sI", 64, 0, 0, len(disk), b"super", 0)
    table = partition + extents + device
    header = bytearray(128)
    struct.pack_into("<IHHI", header, 0, 0x414C5030, 10, 0, 128)
    struct.pack_into("<I", header, 44, len(table))
    header[48:80] = hashlib.sha256(table).digest()
    for offset, start, count, stride in [(80, 0, 1, 52), (92, 52, 2, 24),
                                         (104, 100, 0, 0), (116, 100, 1, 64)]:
        struct.pack_into("<III", header, offset, start, count, stride)
    header[12:44] = hashlib.sha256(header).digest()
    disk[12288:12416] = header
    disk[12416:12416 + len(table)] = table
    source, payload, output = root / "super", root / "payload", root / "output"
    source.write_bytes(disk)
    payload.write_bytes(b"A" * 4096 + b"B" * 4096)
    m.extract(source, "vendor", payload, replace=True)
    updated = source.read_bytes()
    expected = bytearray(disk)
    expected[65536:69632] = b"A" * 4096
    expected[81920:86016] = b"B" * 4096
    assert updated == expected, "replacement touched data outside selected extents"
    m.extract(source, "vendor", output)
    assert output.read_bytes() == payload.read_bytes()
    payload.write_bytes(b"short")
    try:
        m.extract(source, "vendor", payload, replace=True)
    except ValueError:
        pass
    else:
        raise AssertionError("short replacement accepted")
    assert source.read_bytes() == updated
    print("PASS split-extent replacement, metadata preservation, extraction, size rejection")
