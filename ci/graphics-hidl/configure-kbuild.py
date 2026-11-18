#!/usr/bin/env python3
"""Retain generic DRM only in the disposable non-Exynos QEMU build."""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
if len(re.findall(r'^obj-y\s*\+=\s*gpu/\s*$',
                  (root / 'drivers/Makefile').read_text(), re.M)) != 1:
    raise SystemExit('Expected original GPU parent object selection')
gpu = root / 'drivers/gpu/Makefile'
source = gpu.read_text()
old = 'drm/ vga/ arm/ exynos/'
if source.count(old) != 1:
    raise SystemExit('Unexpected Samsung GPU object selection')
gpu.write_text(source.replace(old, 'drm/ vga/'))
# Samsung gates drm_edid.o behind HDMI. The generic virtio driver uses
# drm_get_edid; select its helper without enabling a Samsung HDMI driver.
# This dependency is already tested by the separate passing graphics fixture.
kconfig = root / 'drivers/gpu/drm/virtio/Kconfig'
source = kconfig.read_text()
if source.count('config DRM_VIRTIO_GPU\n') != 1:
    raise SystemExit('Unexpected original virtio GPU Kconfig')
kconfig.write_text(source + '\nconfig DRM_VIRTIO_GPU\n\tselect HDMI\n')
print('PASS disposable QEMU generic DRM Kbuild selection prepared')
