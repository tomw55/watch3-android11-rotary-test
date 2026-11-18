#!/usr/bin/env python3
"""Inspect the HIDL evidence ZIP; never execute its binaries."""
import hashlib
import pathlib
import struct
import sys
import zipfile


def require(ok, message):
    if not ok:
        raise ValueError(message)


def unpack_newc(data):
    result = {}
    pos = 0
    while True:
        require(pos + 110 <= len(data), 'truncated newc header')
        require(data[pos:pos + 6] == b'070701', 'unexpected cpio format')
        fields = [int(data[pos + 6 + i * 8:pos + 14 + i * 8], 16) for i in range(13)]
        size, namesize = fields[6], fields[11]
        start = pos + 110
        require(namesize > 0 and start + namesize <= len(data), 'truncated cpio name')
        require(data[start + namesize - 1] == 0, 'unterminated cpio name')
        name = data[start:start + namesize - 1].decode().removeprefix('./').lstrip('/')
        payload = (start + namesize + 3) & ~3
        require(payload + size <= len(data), 'truncated cpio data')
        if name == 'TRAILER!!!':
            return result
        require(name not in result, 'duplicate cpio entry: ' + name)
        result[name] = data[payload:payload + size]
        pos = (payload + size + 3) & ~3


def verify(path, expected_zip_sha):
    require(hashlib.sha256(path.read_bytes()).hexdigest() == expected_zip_sha, 'ZIP digest mismatch')
    with zipfile.ZipFile(path) as archive:
        prefix = 'samsung-virt-evidence/'
        for line in archive.read(prefix + 'SHA256SUMS').decode().splitlines():
            expected, name = line.split(maxsplit=1)
            require(hashlib.sha256(archive.read(prefix + name)).hexdigest() == expected, name)
        files = unpack_newc(archive.read(prefix + 'initramfs.cpio'))
        require(files['test.policy'] == archive.read(prefix + 'test.policy'), 'embedded policy mismatch')
        for line in archive.read('servicemanager-binary/hidl-guest-SHA256SUMS').decode().splitlines():
            expected, name = line.split(maxsplit=1)
            name = name.removeprefix('./')
            require(hashlib.sha256(files[name]).hexdigest() == expected, 'packaged guest: ' + name)
        for name in ('system/bin/hidl-client', 'system/bin/hwservicemanager', 'system/lib64/libhidlbase.so'):
            elf = files[name]
            require(elf[:4] == b'\x7fELF' and struct.unpack_from('<H', elf, 18)[0] == 183, name + ' is not ARM64 ELF')
        config = archive.read(prefix + 'config.final').decode()
        for marker in ('CONFIG_ANDROID_BINDER_IPC=y', 'CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"', 'CONFIG_SECURITY_SELINUX=y', 'CONFIG_DEFAULT_SECURITY="selinux"', 'CONFIG_TIMERFD=y', 'CONFIG_UNIX=y'):
            require(marker in config.splitlines(), 'missing resolved config: ' + marker)
        serial = archive.read(prefix + 'serial.log').decode()
        for marker in ('Linux version 4.9.59', 'PASS fixture SELinux policy loaded and readable', 'enforcing=1', 'PASS hwservicemanager alive', 'HIDL REGISTRY android.hidl.manager@1.0::IServiceManager/default', 'PASS HIDL manager list', 'HIDL CHAIN android.hidl.manager@1.0::IServiceManager', 'PASS HIDL self lookup ping interfaceChain', 'PASS HIDL transport baseline'):
            require(marker in serial, 'missing runtime evidence: ' + marker)
        require(all(m not in serial for m in ('FAIL ', 'Kernel panic', 'Call trace:')), 'guest failure')
        print('PASS ZIP and kernel manifests, packaged ARM64 ELFs, resolved config and HIDL runtime markers')
        print('NOT RUN normal property-ready discovery, custom HAL registration, full Android boot, physical hardware')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: verify-hidl-evidence.py ARTIFACT.zip EXPECTED_ZIP_SHA256')
    verify(pathlib.Path(sys.argv[1]), sys.argv[2])
