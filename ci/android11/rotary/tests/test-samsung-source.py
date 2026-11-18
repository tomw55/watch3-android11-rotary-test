#!/usr/bin/env python3
"""Compile actual hash-pinned decoder/work functions with synthetic GPIO stubs.

No driver probe, regulator, IRQ, sysfs, firmware, or device operation is linked.
Generated Samsung function excerpts retain their GPL-2.0-or-later provenance.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

archive = Path(sys.argv[1])
digest = hashlib.sha256()
with archive.open('rb') as stream:
    for part in iter(lambda: stream.read(1024*1024), b''):
        digest.update(part)
assert digest.hexdigest() == '1cb5b1a9a7024ac28366559324fac6d07a359af19b73c2fe392d838305e7be3f'
with zipfile.ZipFile(archive) as source:
    data = source.read('kernel_samsung_galileo-master/drivers/input/misc/tizen_bezel.c')
assert hashlib.sha256(data).hexdigest() == '1d328f906788b0e30567d1f136ec42838ef00fe0440f335503e0611f8337fe90'
text = data.decode()

def function(name):
    match = re.search(r'^static (?:int|void) '+name+r'\([^)]*\)\n\{', text, re.M)
    assert match, name
    depth = 1; end = match.end()
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[match.start():end]+'\n'

prefix = r'''
/* Test-only Samsung excerpts: GPL-2.0-or-later, original copyright Samsung. */
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
enum bezel_event { BZ_CC=-1, BZ_NA=0, BZ_CW=1, BZ_MAX };
enum status_patten { Status_S=0, Status_A=1, Status_B=2, Status_C=4, Status_MAX };
#define REL_X_EVENT_MASK 0x07
#define REL_WHEEL 8
#define REL_X 0
struct device { int unused; };
struct platform_device { struct device dev; };
struct input_dev { int unused; };
struct bezel_ddata;
struct work_struct { struct bezel_ddata *owner; };
struct bezel_ddata {
 struct platform_device *pdev; struct input_dev *input_dev;
 struct work_struct work; int hall_lock, last_status, last_value;
 int gpio_a,gpio_b,gpio_c;
 bool a_status,b_status,c_status,factory_mode;
 unsigned int dqa_cw_cnt,dqa_ccw_cnt,dqa_err_cnt;
};
#define container_of(ptr, type, member) ((ptr)->owner)
#define dev_dbg(device, ...) ((void)(device))
#define dev_info(device, ...) ((void)(device))
#define dev_err(device, ...) ((void)(device))
static int levels[3], captured[3][3], event_count, held;
static int gpio_get_value(int gpio) { assert(gpio>=0 && gpio<3); return levels[gpio]; }
static void mutex_lock(int *lock) { (void)lock; assert(held==0); ++held; }
static void mutex_unlock(int *lock) { (void)lock; assert(held==1); --held; }
static void input_report_rel(struct input_dev *dev, int code, int value) {
 (void)dev; assert(event_count<3); captured[event_count][0]=2;
 captured[event_count][1]=code; captured[event_count++][2]=value;
}
static void input_sync(struct input_dev *dev) {
 (void)dev; assert(event_count<3); memset(captured[event_count++],0,sizeof(captured[0]));
}
'''
prefix=prefix.replace('enum bezel_event { BZ_CC=-1, BZ_NA=0, BZ_CW=1, BZ_MAX };',re.search(r'enum bezel_event \{.*?\n\};',text,re.S).group())
prefix=prefix.replace('enum status_patten { Status_S=0, Status_A=1, Status_B=2, Status_C=4, Status_MAX };',re.search(r'enum status_patten \{.*?\n\};',text,re.S).group())
prefix=prefix.replace('#define REL_X_EVENT_MASK 0x07',re.search(r'^#define\s+REL_X_EVENT_MASK.*$',text,re.M).group())
suffix = r'''
static int expected(int last,int current) {
 if ((last==1&&current==2)||(last==2&&current==4)||(last==4&&current==1)) return 1;
 if ((last==1&&current==4)||(last==4&&current==2)||(last==2&&current==1)) return -1;
 return 0;
}
int main(void) {
 struct platform_device platform={0}; struct input_dev input={0};
 struct bezel_ddata d={.pdev=&platform,.input_dev=&input,.gpio_a=0,.gpio_b=1,.gpio_c=2};
 d.work.owner=&d;
 for (int last=-2;last<=8;++last) for (int value=-2;value<=8;++value) {
  d.last_status=last; assert(bezel_get_direction(&d,value)==expected(last,value));
 }
 for (int factory=0;factory<=1;++factory) for (int last=0;last<8;++last) for (int value=0;value<8;++value) {
  d.last_status=last;d.last_value=last;d.factory_mode=factory;
  d.dqa_cw_cnt=d.dqa_ccw_cnt=d.dqa_err_cnt=0;event_count=0;held=0;
  for (int bit=0;bit<3;++bit) levels[bit]=!(value&(1<<bit));
  assert(bezel_get_status(&d)==value);bezel_work_func(&d.work);assert(held==0);
  int direction=expected(last,value);
  bool valid=factory||value==last||value==0||value==1||value==2||value==4;
  assert(event_count==(valid&&direction?3:0));
  assert(d.last_status==(valid?value:last));
  assert(d.last_value==(valid&&direction?value:last));
  assert(d.dqa_err_cnt==(valid?0u:1u));
  if (valid&&direction) {
   assert(captured[0][0]==2&&captured[0][1]==8&&captured[0][2]==direction);
   assert(captured[1][0]==2&&captured[1][1]==0&&captured[1][2]==((~value)&7));
   assert(captured[2][0]==0&&captured[2][1]==0&&captured[2][2]==0);
   assert(d.dqa_cw_cnt==(direction>0?1u:0u));assert(d.dqa_ccw_cnt==(direction<0?1u:0u));
  }
 }
 puts("PASS actual Samsung functions: 121 bounded direction pairs, 128 work/state cases, active-low GPIO, reset/repeat/invalid/factory controls");
 return 0;
}
'''
with tempfile.TemporaryDirectory(dir=Path.cwd()) as tmp:
    root=Path(tmp);unit=root/'source-test.c';binary=root/'source-test'
    unit.write_text(prefix+'\n'.join(function(n) for n in
                    ['bezel_get_direction','bezel_get_status','bezel_check_validation','bezel_work_func'])+suffix)
    flags=['-std=c11','-Wall','-Wextra','-Werror','-pedantic','-O1','-g']
    for extra in [[],['-fsanitize=address,undefined','-fno-omit-frame-pointer']]:
        subprocess.run([os.environ.get('CC','cc'),*flags,*extra,str(unit),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)
print('PASS hash-pinned source extraction in strict C11 and ASan/UBSan; stock DWK2 raw evdev NOT RUN')
