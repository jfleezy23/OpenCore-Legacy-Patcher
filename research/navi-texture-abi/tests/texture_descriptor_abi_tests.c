#include "texture_descriptor_abi.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static void check(bool good,const char *message) {
    if (!good) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
int main(void) {
    uint8_t source[200], original[200], destination[194];
    for (unsigned i=0;i<200;i++) source[i]=(uint8_t)(i*73+19);
    memcpy(original,source,200); memset(destination,0xa5,194);
    navi_translate_texture_descriptor(destination+1,source);
    check(!memcmp(source,original,200),"source must remain unchanged");
    check(destination[0]==0xa5 && destination[193]==0xa5,"destination guard bytes");
    check(!memcmp(destination+1,source,0xa8),"unchanged descriptor prefix");
    check(!memcmp(destination+1+0xa8,source+0xb0,24),"resolved usage/cache/storage tail must shift down eight bytes");
    uint8_t prior[192]; memcpy(prior,destination+1,192);
    memset(source+0xa8,0xff,8);
    navi_translate_texture_descriptor(destination+1,source);
    check(!memcmp(prior,destination+1,192),"new matrix field must not leak into donor layout");
    check(navi_texture_abi_path_is_donor("/System/Library/Extensions/AMDRadeonX6000MTLDriver.bundle/Contents/MacOS/AMDRadeonX6000MTLDriver"),"accept exact Navi donor suffix");
    check(!navi_texture_abi_path_is_donor(NULL),"reject null path");
    check(!navi_texture_abi_path_is_donor("/System/Library/Frameworks/Metal.framework/Metal"),"do not translate Metal callers");
    check(!navi_texture_abi_path_is_donor("/System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/AMDMTLBronzeDriver"),"do not change D700 callers");
    check(!navi_texture_abi_path_is_donor("/System/Library/Extensions/AMDRadeonX6000MTLDriver.bundle/Contents/MacOS/AMDRadeonX6000MTLDriver.other"),"reject suffix lookalikes");
    puts("PASS: texture descriptor prefix/tail mapping, source preservation, guards and exact donor gate.");
    return 0;
}
