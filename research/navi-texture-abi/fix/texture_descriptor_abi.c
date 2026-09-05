#include "texture_descriptor_abi.h"
#include <string.h>
void navi_translate_texture_descriptor(uint8_t destination[NAVI_TEXTURE_DONOR_SIZE],
                                       const uint8_t source[NAVI_TEXTURE_CURRENT_SIZE]) {
    memcpy(destination,source,0xa8);
    memcpy(destination+0xa8,source+0xb0,0x18);
}
bool navi_texture_abi_path_is_donor(const char *path) {
    static const char suffix[]="/AMDRadeonX6000MTLDriver.bundle/Contents/MacOS/AMDRadeonX6000MTLDriver";
    if (!path) return false;
    size_t size=strlen(path), length=sizeof(suffix)-1;
    return size>=length && !strcmp(path+size-length,suffix);
}
