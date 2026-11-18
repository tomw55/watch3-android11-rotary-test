#!/usr/bin/env python3
"""Exercise the actual ELF verifier on a real public AArch64 HAL plus mutations."""
import importlib.util
import pathlib
import struct
import sys

p=pathlib.Path(__file__).with_name('prepare-package.py')
spec=importlib.util.spec_from_file_location('prepare',p);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
data=pathlib.Path(sys.argv[1]).read_bytes();baseline=module.load_contract(data)
bookkeeping=bytearray(data);bookkeeping[40:48]=bytes(8);bookkeeping[60:64]=bytes(4)
assert module.load_contract(bookkeeping)==baseline
code=bytearray(data);offset=struct.unpack_from('<Q',data,32)[0];stride,count=struct.unpack_from('<HH',data,54)
for index in range(count):
 kind,flags,start,_,_,size,_,_=struct.unpack_from('<IIQQQQQQ',data,offset+index*stride)
 if kind==1 and flags&1 and size>64:code[start+64]^=1;break
else:raise AssertionError('No executable segment')
assert module.load_contract(code)!=baseline
abi=bytearray(data);abi[24]^=1;assert module.load_contract(abi)!=baseline
for invalid in [b'',data[:63],data[:70]]:
 try:module.load_contract(invalid)
 except ValueError:pass
 else:raise AssertionError('Truncated ELF accepted')
print('PASS actual ELF LOAD verifier, permitted section metadata, executable/entry-point mutations and truncation controls')
