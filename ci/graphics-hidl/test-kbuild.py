#!/usr/bin/env python3
"""Exercise actual QEMU edit and GNU Make on the hash-verified source."""
import hashlib
import pathlib
import subprocess
import sys
import tempfile
import zipfile

archive = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
with archive.open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        digest.update(chunk)
assert digest.hexdigest() == '1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f'
helper = pathlib.Path(__file__).with_name('configure-kbuild.py').resolve()
with tempfile.TemporaryDirectory(dir=pathlib.Path.cwd()) as directory:
    root = pathlib.Path(directory)
    with zipfile.ZipFile(archive) as source:
        for name in ['drivers/Makefile', 'drivers/gpu/Makefile', 'drivers/gpu/drm/virtio/Kconfig']:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read('kernel_samsung_galileo-master/' + name))
    parent = (root / 'drivers/Makefile').read_bytes()
    subprocess.run([sys.executable, str(helper), str(root)], check=True)
    assert (root / 'drivers/Makefile').read_bytes() == parent
    makefile = root / 'probe.mk'
    makefile.write_text('include drivers/gpu/Makefile\n.PHONY: all\nall:\n\t@echo "$(obj-y)"\n')
    selected = subprocess.check_output(['make', '-sf', str(makefile)], cwd=root, text=True).split()
    assert 'drm/' in selected and 'vga/' in selected
    assert 'arm/' not in selected and 'exynos/' not in selected
    assert '\n\tselect HDMI\n' in (root / 'drivers/gpu/drm/virtio/Kconfig').read_text()
    result = subprocess.run([sys.executable, str(helper), str(root)], capture_output=True)
    assert result.returncode != 0
print('PASS pinned source hash, unchanged parent, GNU Make generic selection, repeat-edit rejection')
