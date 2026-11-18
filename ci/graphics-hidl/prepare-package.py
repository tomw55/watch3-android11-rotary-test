#!/usr/bin/env python3
"""Strip disposable public HAL copies, requiring identical ELF load contracts."""
import hashlib
import json
import pathlib
import shutil
import struct
import subprocess
import sys

def load_contract(data):
 if len(data)<64 or data[:6]!=b'\x7fELF\x02\x01':raise ValueError('Expected ELF64 little-endian')
 if struct.unpack_from('<H',data,18)[0]!=183:raise ValueError('Expected AArch64')
 offset=struct.unpack_from('<Q',data,32)[0];stride,count=struct.unpack_from('<HH',data,54)
 if stride!=56 or not 0<count<128 or offset+stride*count>len(data):raise ValueError('Invalid program headers')
 headers=data[offset:offset+stride*count];segments=[]
 for index in range(count):
  kind,flags,start,va,pa,size,memsize,align=struct.unpack_from('<IIQQQQQQ',data,offset+index*stride)
  if kind!=1:continue
  if size>memsize or start+size>len(data):raise ValueError('Invalid LOAD segment')
  value=bytearray(data[start:start+size])
  # strip changes section-table bookkeeping in the mapped ELF header. This
  # is the only permitted difference inside LOAD bytes; code/data are exact.
  if start==0:
   value[40:48]=bytes(8);value[58:64]=bytes(6)
  segments.append(hashlib.sha256(value).hexdigest())
 if not segments:raise ValueError('No LOAD segments')
 header=bytearray(data[:64]);header[40:48]=bytes(8);header[58:64]=bytes(6)
 return bytes(header),headers,segments

def main():
 source,destination=map(pathlib.Path,sys.argv[1:])
 tool=shutil.which('aarch64-linux-gnu-strip')
 if not tool:raise SystemExit('Missing AArch64 strip tool')
 if destination.exists():raise SystemExit('Refusing existing derived package directory')
 shutil.copytree(source,destination)
 records=[]
 for original in sorted(source.rglob('*')):
  if not original.is_file():continue
  relative=original.relative_to(source);target=destination/relative;before=original.read_bytes()
  if before.startswith(b'\x7fELF'):
   subprocess.run([tool,'--strip-unneeded',str(target)],check=True)
   if load_contract(before)!=load_contract(target.read_bytes()):raise SystemExit('ELF load contract changed: '+str(relative))
  records.append({'path':str(relative),'original_bytes':len(before),'derived_bytes':target.stat().st_size,'sha256':hashlib.sha256(target.read_bytes()).hexdigest()})
 (destination.parent/'derived-package.json').write_text(json.dumps({'strip':subprocess.check_output([tool,'--version'],text=True).splitlines()[0],'files':records},indent=2)+'\n')
 print('PASS stripped copies preserve exact program headers and LOAD bytes except ELF section-table bookkeeping')
 print('Package bytes before='+str(sum(r['original_bytes'] for r in records))+' after='+str(sum(r['derived_bytes'] for r in records)))

if __name__=='__main__':main()
