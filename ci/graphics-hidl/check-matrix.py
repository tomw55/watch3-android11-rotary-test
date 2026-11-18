#!/usr/bin/env python3
"""Check selected versions against the real published SDK system FCM, unmodified."""
import pathlib,re,subprocess,sys,xml.etree.ElementTree as ET
image=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);matrix=out/'sdk-framework-matrix5.xml'
for source in ['/system/etc/vintf/compatibility_matrix.5.xml','/etc/vintf/compatibility_matrix.5.xml']:
 matrix.unlink(missing_ok=True)
 subprocess.run(['debugfs','-R',f'dump {source} {matrix}',str(image)],capture_output=True)
 if matrix.is_file() and matrix.stat().st_size:break
else:raise SystemExit('Actual SDK level-5 framework matrix is unavailable')
root=ET.fromstring(matrix.read_bytes())
def accepts(name,version):
 h=[x for x in root.findall('hal') if x.findtext('name')==name]
 if len(h)!=1:return False
 major,minor=map(int,version.split('.'))
 for v in h[0].findall('version'):
  m=re.fullmatch(r'(\d+)\.(\d+)(?:-(\d+))?',v.text)
  if m and major==int(m[1]) and int(m[2])<=minor<=int(m[3]or m[2]):return True
 return False
for kind,version in [('allocator','2.0'),('mapper','2.1'),('composer','2.1')]:
 if not accepts('android.hardware.graphics.'+kind,version):raise SystemExit('SDK FCM rejects '+kind+' '+version)
 print('PASS actual SDK FCM accepts '+kind+' '+version)
if accepts('android.hardware.graphics.mapper','2.0'):raise SystemExit('Unexpected matrix: verify the negative-control premise')
print('PASS actual SDK FCM negative control rejects mapper 2.0; no matrix changed')
