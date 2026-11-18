#!/usr/bin/env python3
import importlib.util,pathlib,xml.etree.ElementTree as ET
p=pathlib.Path(__file__).with_name('vendor-config.py');s=importlib.util.spec_from_file_location('v',p);v=importlib.util.module_from_spec(s);s.loader.exec_module(v)
src='<manifest version="1.0" type="device" target-level="5">'
for name in v.HALS:
 src+='<hal format="hidl"><name>'+name+'</name><transport>hwbinder</transport><version>3.0</version><interface><name>Old</name><instance>default</instance></interface></hal>'
src+='<hal format="hidl"><name>untouched.test</name><transport>hwbinder</transport><version>1.0</version></hal></manifest>'
out=ET.fromstring(v.manifest(src));assert out.get('target-level')=='5'
for name,(version,interface,transport) in v.HALS.items():
 h=next(h for h in out.findall('hal') if h.findtext('name')==name)
 assert h.findtext('version')==version and h.findtext('interface/name')==interface and h.findtext('transport')==transport
h=next(h for h in out.findall('hal') if h.findtext('name')=='untouched.test');assert h.findtext('version')=='1.0'
rc='on early-init\n    setprop ro.hardware.egl emulation\n    setprop ro.hardware.vulkan ranchu\n'
changed=v.ranchu_rc(rc);assert 'ro.hardware.egl swiftshader' in changed and 'ro.hardware.vulkan ranchu' in changed
for bad in [rc+rc,changed,'on init\n']:
 try:v.ranchu_rc(bad)
 except ValueError:pass
 else:raise AssertionError('ambiguous property source accepted')
for bad in [src.replace('<name>android.hardware.graphics.mapper</name>','<name>other</name>'),src.replace('type="device"','type="framework"')]:
 try:v.manifest(bad)
 except ValueError:pass
 else:raise AssertionError('wrong manifest accepted')
print('PASS pure vendor configuration transforms and five ambiguity controls; image/runtime NOT RUN')
