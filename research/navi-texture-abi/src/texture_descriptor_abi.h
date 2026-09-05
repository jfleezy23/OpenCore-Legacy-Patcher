#ifndef NAVI_TEXTURE_DESCRIPTOR_ABI_H
#define NAVI_TEXTURE_DESCRIPTOR_ABI_H
#include <stdint.h>
#include <stdbool.h>
enum { NAVI_TEXTURE_CURRENT_SIZE=200, NAVI_TEXTURE_DONOR_SIZE=192 };
void navi_translate_texture_descriptor(uint8_t destination[NAVI_TEXTURE_DONOR_SIZE],
                                       const uint8_t source[NAVI_TEXTURE_CURRENT_SIZE]);
bool navi_texture_abi_path_is_donor(const char *path);
#endif
