#include "qemu49_layout.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    uint32_t s=7,h=8,n=9;
    assert(qemu49_rgb_layout(0, 1, &s,&h,&n)==-EINVAL);
    assert(s==7 && h==8 && n==9);
    assert(qemu49_rgb_layout(1, 0, &s,&h,&n)==-EINVAL);
    assert(qemu49_rgb_layout(UINT32_MAX, 1, &s,&h,&n)==-EOVERFLOW);
    assert(qemu49_rgb_layout(1, UINT32_MAX, &s,&h,&n)==-EOVERFLOW);
    assert(qemu49_rgb_layout(65536,65536,&s,&h,&n)==-EOVERFLOW);
    for (uint32_t w=1;w<=2050;w++) {
        for (uint32_t y=1;y<=129;y++) {
            assert(qemu49_rgb_layout(w,y,&s,&h,&n)==0);
            assert(s>=w*4 && !(s%256) && h>=y && !(h%64));
            assert(n>=(uint64_t)s*h && !(n%4096));
        }
    }
    puts("PASS checked RGB layout: 264450 geometry cases plus invalid/overflow cases");
}
