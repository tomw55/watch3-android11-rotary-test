#!/usr/bin/env python3
"""Pure configuration transforms for a future disposable QEMU vendor overlay."""
import re
import xml.etree.ElementTree as ET

HALS={
 'android.hardware.graphics.allocator':('2.0','IAllocator','hwbinder'),
 'android.hardware.graphics.mapper':('2.1','IMapper','passthrough'),
 'android.hardware.graphics.composer':('2.1','IComposer','hwbinder'),
}

def manifest(text):
 root=ET.fromstring(text)
 if root.tag!='manifest' or root.get('type')!='device':raise ValueError('expected device VINTF manifest')
 for name,(version,interface,transport) in HALS.items():
  nodes=[h for h in root.findall('hal') if h.findtext('name')==name]
  if len(nodes)!=1:raise ValueError('expected exactly one existing '+name)
  h=nodes[0]
  if h.get('format','hidl')!='hidl':raise ValueError('unexpected HAL format')
  for child in list(h):
   if child.tag in ('version','interface','fqname','transport'):h.remove(child)
  t=ET.SubElement(h,'transport');t.text=transport
  if transport=='passthrough':t.set('arch','64')
  ET.SubElement(h,'version').text=version
  i=ET.SubElement(h,'interface');ET.SubElement(i,'name').text=interface;ET.SubElement(i,'instance').text='default'
 return ET.tostring(root,encoding='unicode')+'\n'

def ranchu_rc(text):
 pattern=r'(?m)^(\s*)setprop\s+ro\.hardware\.egl\s+emulation\s*$'
 if len(re.findall(pattern,text))!=1:raise ValueError('expected one original early EGL selection')
 if re.search(r'(?m)^\s*setprop\s+ro\.hardware\.(gralloc|hwcomposer)\s',text):raise ValueError('existing graphics selection needs explicit review')
 return re.sub(pattern,lambda m:m[1]+'setprop ro.hardware.egl swiftshader\n'+m[1]+'setprop ro.hardware.gralloc minigbm\n'+m[1]+'setprop ro.hardware.hwcomposer drm_minigbm',text)
