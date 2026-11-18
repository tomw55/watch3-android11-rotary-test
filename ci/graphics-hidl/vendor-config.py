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
 if re.search(r'(?m)^\s*setprop\s+ro\.hardware\.(gralloc|hwcomposer)\s',text):raise ValueError('existing graphics selection needs explicit review')
 lines=text.splitlines(keepends=True);action=None;found=[]
 for index,line in enumerate(lines):
  if line and not line[0].isspace() and not line.startswith('#'):action=line.strip()
  m=re.fullmatch(r'([ \t]*)setprop\s+ro\.hardware\.egl\s+emulation[ \t]*\n?',line)
  if m:found.append((index,action,m[1]))
 if [a for _,a,_ in found].count('on early-init')!=1:raise ValueError('expected one early-init EGL selection')
 if any(a not in ('on early-init','on boot') for _,a,_ in found) or [a for _,a,_ in found].count('on boot')>1:raise ValueError('unexpected EGL selection action')
 for index,action,indent in found:
  lines[index]=indent+'setprop ro.hardware.egl swiftshader\n'
  if action=='on early-init':lines[index]+=indent+'setprop ro.hardware.gralloc minigbm\n'+indent+'setprop ro.hardware.hwcomposer drm_minigbm\n'
 return ''.join(lines)

def selinux_label(data):
 if data.endswith(b'\0'):data=data[:-1]
 value=data.decode('ascii')
 if not re.fullmatch(r'u:object_r:[A-Za-z0-9_]+:s0',value):raise ValueError('invalid source file label')
 return value
