SDKROOT := $(shell xcrun --sdk macosx --show-sdk-path)
BUILD := build
COMMON := -arch x86_64 -isysroot $(SDKROOT) -mmacosx-version-min=14.5 -O2 -fPIC -Wall -Wextra -Werror -Ifix
OBJC := $(COMMON) -fobjc-arc -fmodules
ABI := fix/texture_descriptor_abi.c fix/texture_descriptor_abi.h

.PHONY: all diagnostics test root-prototype
# Default: build the scoped fix only. Tests and diagnostics are opt-in.
all: root-prototype

diagnostics: $(BUILD)/texture-descriptor-abi-lab.dylib $(BUILD)/msaa_rectangle_minimal $(BUILD)/texture_validation_order_tests

$(BUILD):
	mkdir -p $@

$(BUILD)/texture-descriptor-abi-lab.dylib: fix/texture_descriptor_abi_lab.m $(ABI) | $(BUILD)
	clang $(OBJC) -dynamiclib fix/texture_descriptor_abi_lab.m fix/texture_descriptor_abi.c -framework Foundation -framework Metal -o $@
	codesign --force --sign - $@

$(BUILD)/texture_descriptor_abi_tests: tests/texture_descriptor_abi_tests.c $(ABI) | $(BUILD)
	clang $(COMMON) -std=c11 tests/texture_descriptor_abi_tests.c fix/texture_descriptor_abi.c -o $@

$(BUILD)/texture_abi_lifetime_tests: tests/texture_abi_lifetime_tests.m fix/texture_descriptor_abi_lab.m $(ABI) | $(BUILD)
	clang $(OBJC) tests/texture_abi_lifetime_tests.m fix/texture_descriptor_abi.c -framework Foundation -framework Metal -o $@

$(BUILD)/msaa_rectangle_minimal: tests/msaa_rectangle_minimal.m | $(BUILD)
	clang $(OBJC) $< -framework Foundation -framework Metal -framework IOSurface -o $@

$(BUILD)/texture_validation_order_tests: tests/texture_validation_order_tests.m | $(BUILD)
	clang $(OBJC) $< -framework Foundation -framework Metal -o $@

test: $(BUILD)/texture_descriptor_abi_tests $(BUILD)/texture_abi_lifetime_tests $(BUILD)/msaa_rectangle_minimal
	$(BUILD)/texture_descriptor_abi_tests
	env -u NAVI_TEXTURE_ABI_LAB -u NAVI_TEXTURE_ABI_TRACE -u DYLD_INSERT_LIBRARIES $(BUILD)/texture_abi_lifetime_tests
	$(BUILD)/msaa_rectangle_minimal --self-test

# Build only. This target NEVER installs into an OS or modifies an EFI.
# Its exact-donor caller offsets are intentionally not a portable deployment API.
root-prototype: $(BUILD)/NaviTextureABI.dylib

$(BUILD)/NaviTextureABI.dylib: fix/texture_descriptor_abi_lab.m $(ABI) | $(BUILD)
	clang $(OBJC) -DNAVI_TEXTURE_ABI_ROOT=1 -dynamiclib fix/texture_descriptor_abi_lab.m fix/texture_descriptor_abi.c -framework Foundation -framework Metal -Wl,-reexport_framework,IOSurface -Wl,-install_name,@loader_path/NaviTextureABI.dylib -o $@
	codesign --force --sign - $@
