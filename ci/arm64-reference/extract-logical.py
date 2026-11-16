"""Read a single-device Android liblp image and extract one logical partition."""
import hashlib
import json
import struct
import sys
from pathlib import Path

SECTOR = 512
GEOMETRY = 4096
METADATA = 12288
CHUNK = 1024 * 1024


def checked(blob, offset):
    digest = blob[offset:offset + 32]
    if hashlib.sha256(blob[:offset] + bytes(32) + blob[offset + 32:]).digest() != digest:
        raise ValueError("metadata checksum mismatch")


def extract(source, name, destination):
    size = source.stat().st_size
    with source.open("rb") as disk:
        disk.seek(GEOMETRY)
        geometry = disk.read(52)
        magic, length = struct.unpack_from("<II", geometry)
        if (magic, length) != (0x616C4467, 52):
            raise ValueError("unsupported primary liblp geometry")
        checked(geometry, 8)
        limit, slots, block = struct.unpack_from("<III", geometry, 40)
        if not 128 <= limit <= min(16 * CHUNK, size - METADATA) or not slots:
            raise ValueError("invalid metadata geometry")
        disk.seek(METADATA)
        first = disk.read(128)
        magic, major, minor, header_size = struct.unpack_from("<IHHI", first)
        if magic != 0x414C5030 or major != 10 or not 128 <= header_size <= limit:
            raise ValueError("unsupported primary liblp header")
        disk.seek(METADATA)
        header = disk.read(header_size)
        checked(header, 12)
        table_size, = struct.unpack_from("<I", header, 44)
        if table_size > limit - header_size:
            raise ValueError("tables outside metadata slot")
        table = disk.read(table_size)
        if hashlib.sha256(table).digest() != header[48:80]:
            raise ValueError("table checksum mismatch")

        def entries(descriptor, fmt):
            offset, count, stride = struct.unpack_from("<III", header, descriptor)
            if stride < struct.calcsize(fmt) or offset + count * stride > len(table):
                raise ValueError("invalid table descriptor")
            return [struct.unpack_from(fmt, table, offset + i * stride) for i in range(count)]

        parts = entries(80, "<36sIIII")
        extents = entries(92, "<QIQI")
        devices = entries(116, "<QIIQ36sI")
        if len(devices) != 1:
            raise ValueError("only single-device super images are supported")
        names = [p[0].split(b"\0", 1)[0].decode("ascii") for p in parts]
        print(json.dumps({"major": major, "minor": minor, "slots": slots,
                          "block_size": block, "partitions": names}), flush=True)
        for candidate in (name, name + "_a"):
            if candidate in names:
                partition = parts[names.index(candidate)]
                break
        else:
            raise ValueError(f"logical partition {name} missing")
        start, count = partition[2:4]
        if not count or start + count > len(extents):
            raise ValueError("extent range outside table")
        selected = extents[start:start + count]
        total = sum(item[0] * SECTOR for item in selected)
        if not 0 < total <= size:
            raise ValueError("invalid logical partition size")
        with destination.open("wb") as output:
            for sectors, kind, data, device in selected:
                length = sectors * SECTOR
                if kind == 1:
                    output.seek(length, 1)
                    continue
                position = data * SECTOR
                if kind != 0 or device != 0 or position + length > size:
                    raise ValueError("unsupported or out-of-bounds extent")
                disk.seek(position)
                while length:
                    chunk = disk.read(min(length, CHUNK))
                    if not chunk:
                        raise ValueError("truncated extent")
                    if chunk.count(0) != len(chunk):
                        output.write(chunk)
                    else:
                        output.seek(len(chunk), 1)
                    length -= len(chunk)
            output.truncate(total)


if __name__ == "__main__":
    extract(Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]))
