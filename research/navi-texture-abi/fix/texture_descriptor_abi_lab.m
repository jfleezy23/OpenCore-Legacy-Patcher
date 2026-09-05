// Standalone diagnostic, or explicitly compiled NaviLab root dependency.
// Current Metal inserts colorSpaceConversionMatrix before three resolved fields.
// Only direct Monterey-derived Navi donor callers receive the 192-byte layout.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include "texture_descriptor_abi.h"
#include <crt_externs.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static _Atomic(IMP) predecessor;
static atomic_uint serial;
static ptrdiff_t privateOffset;
static int logFD=-1;
static char storageKey;
static Class descriptorClass;
static const char expectedEncoding[]=
    "{MTLTextureDescriptorPrivate=\"textureType\"Q\"pixelFormat\"Q\"width\"Q\"height\"Q\"depth\"Q\"mipmapLevelCount\"Q\"sampleCount\"Q\"arrayLength\"Q\"zeroFill\"c\"rotation\"Q\"framebufferOnly\"c\"isDrawable\"c\"swizzle\"I\"writeSwizzleEnabled\"c\"compressionMode\"Q\"\"(?=\"textureUsage\"Q\"usage\"Q)\"resourceOptions\"Q\"sparseSurfaceDefaultValue\"Q\"allowGPUOptimizedContents\"c\"forceResourceIndex\"c\"resourceIndex\"Q\"protectionOptions\"Q\"compressionFootprint\"Q\"compressionType\"q\"colorSpaceConversionMatrix\"Q\"resolvedUsage\"Q\"cpuCacheMode\"Q\"storageMode\"Q}";
static void record(NSDictionary *row) {
    if (logFD<0) return;
    // Successful-call sampling is bounded, but an untreated path must remain
    // visible even after a long run reaches the success-log limit.
    if ([row[@"event"] isEqual:@"translated"] && atomic_fetch_add(&serial,1)>=4096) return;
    @synchronized([MTLTextureDescriptor class]) {
        NSData *data=[NSJSONSerialization dataWithJSONObject:row options:0 error:NULL];
        if (data) { (void)write(logFD,data.bytes,data.length); (void)write(logFD,"\n",1); }
    }
}
static NSArray *tail(const uint8_t *bytes,size_t offset) {
    uint64_t values[3]; memcpy(values,bytes+offset,sizeof(values));
    return @[@(values[0]),@(values[1]),@(values[2])];
}
static NSData *retainedVersion(id descriptor,const uint8_t *bytes) {
    @synchronized(descriptor) {
        NSMutableDictionary *threads=objc_getAssociatedObject(descriptor,&storageKey);
        if (!threads) {
            threads=[NSMutableDictionary new];
            objc_setAssociatedObject(descriptor,&storageKey,threads,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSValue *key=[NSValue valueWithPointer:(void *)pthread_self()];
        NSMutableArray<NSData *> *versions=threads[key];
        if (!versions) { versions=[NSMutableArray new]; threads[key]=versions; }
        // Immutable versions preserve earlier pointers during nested calls and
        // concurrent descriptor readers. Lifetime matches the descriptor owner.
        NSData *last=versions.lastObject;
        if (last && !memcmp(last.bytes,bytes,NAVI_TEXTURE_DONOR_SIZE)) return last;
        if (versions.count>=4096) { record(@{@"event":@"version_limit"}); return nil; }
        NSData *version=[NSData dataWithBytes:bytes length:NAVI_TEXTURE_DONOR_SIZE];
        [versions addObject:version]; return version;
    }
}
typedef void *(*PrivateMethod)(id,SEL);
__attribute__((noinline)) static void *texturePrivate(id descriptor,SEL selector) {
    void *caller=__builtin_return_address(0);
    const uint8_t *source=((PrivateMethod)atomic_load(&predecessor))(descriptor,selector);
    Dl_info info={0};
    if (!source || !dladdr(caller,&info) || !navi_texture_abi_path_is_donor(info.dli_fname)) return (void *)source;
    Class deviceClass=NSClassFromString(@"GFX10_MtlDevice");
    const char *deviceImage=deviceClass?class_getImageName(deviceClass):NULL;
    if (!deviceImage || strcmp(deviceImage,info.dli_fname) || object_getClass(descriptor)!=descriptorClass) {
        record(@{@"event":@"unexpected_target_identity"}); return (void *)source;
    }
#if defined(NAVI_TEXTURE_ABI_ROOT) && NAVI_TEXTURE_ABI_ROOT == 1
    // First NaviLab deployment: only the two validation-first entry points
    // actually exercised by native reproduction and Chrome. In particular do
    // not change tiled/shared-property paths that validate AFTER the accessor.
    uintptr_t offset=(uintptr_t)caller-(uintptr_t)info.dli_fbase;
    if (offset!=0x14fc4d && offset!=0x152395) return (void *)source;
#endif
    const uint8_t *ownPrivate=(const uint8_t *)(__bridge void *)descriptor+privateOffset;
    if (source!=ownPrivate) {
        record(@{@"event":@"unexpected_source_owner",@"class":@(object_getClassName(descriptor))});
        return (void *)source;
    }
    uint64_t matrix=0; memcpy(&matrix,source+0xa8,sizeof(matrix));
    if (matrix) {
        record(@{@"event":@"unsupported_color_matrix",@"value":@(matrix)});
        return (void *)source;
    }
    uint8_t translated[NAVI_TEXTURE_DONOR_SIZE];
    navi_translate_texture_descriptor(translated,source);
    NSData *version=retainedVersion(descriptor,translated);
    if (!version) return (void *)source;
    record(@{@"event":@"translated",@"pid":@(getpid()),@"class":@(object_getClassName(descriptor)),
             @"donor":@(info.dli_fname),@"caller_offset":@((uintptr_t)caller-(uintptr_t)info.dli_fbase),
             @"source_tail":tail(source,0xb0),@"donor_tail":tail(version.bytes,0xa8),
             @"live_accessor_is_bridge":@(method_getImplementation(class_getInstanceMethod(object_getClass(descriptor),selector))==(IMP)texturePrivate)});
    return (void *)version.bytes;
}
__attribute__((constructor)) static void install(void) {
#if !defined(NAVI_TEXTURE_ABI_ROOT) || NAVI_TEXTURE_ABI_ROOT != 1
    const char *opt=getenv("NAVI_TEXTURE_ABI_LAB");
    if (!opt || strcmp(opt,"1")) return;
    BOOL allowed=!strcmp(getprogname(),"msaa_rectangle_minimal") ||
                 !strcmp(getprogname(),"texture_abi_lifetime_tests") ||
                 !strncmp(getprogname(),"msaa_titlebar_repro",19);
    // Chrome can use a generic helper executable and rename its process later.
    // Inspect the executable's actual enclosing testing bundle, not that label.
    char executablePath[PATH_MAX]={0}; uint32_t pathSize=sizeof(executablePath);
    BOOL chromeGPU=_NSGetExecutablePath(executablePath,&pathSize)==0 &&
        strstr(executablePath,"/Google Chrome for Testing.app/Contents/")!=NULL;
    for (int i=1;i<*_NSGetArgc();i++) if (chromeGPU && !strcmp((*_NSGetArgv())[i],"--type=gpu-process")) allowed=YES;
    if (!allowed) return;
#else
    char executablePath[PATH_MAX]={0}; uint32_t pathSize=sizeof(executablePath);
    (void)_NSGetExecutablePath(executablePath,&pathSize);
#endif
    @autoreleasepool {
        const char *path=getenv("NAVI_TEXTURE_ABI_TRACE");
#if defined(NAVI_TEXTURE_ABI_ROOT) && NAVI_TEXTURE_ABI_ROOT == 1
        // Logging is optional in the installed dependency; activation does
        // not depend on a process environment or writable trace destination.
        if (path && path[0]=='/') logFD=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
#else
        if (!path || path[0]!='/') return;
        logFD=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600); if (logFD<0) return;
#endif
        Class c=NSClassFromString(@"MTLTextureDescriptorInternal");
        SEL selector=NSSelectorFromString(@"descriptorPrivate");
        Method method=class_getInstanceMethod(c,selector);
        Ivar ivar=class_getInstanceVariable(c,"_private");
        NSUInteger size=0,alignment=0;
        if (ivar) NSGetSizeAndAlignment(ivar_getTypeEncoding(ivar),&size,&alignment);
        Dl_info owner={0}; IMP original=method?method_getImplementation(method):NULL;
        BOOL metalOwned=original && dladdr((void *)original,&owner) && owner.dli_fname && strstr(owner.dli_fname,"/Metal.framework/");
        BOOL exactEncoding=ivar && !strcmp(ivar_getTypeEncoding(ivar),expectedEncoding);
        BOOL exactSignature=method && !strcmp(method_getTypeEncoding(method),"r^{MTLTextureDescriptorPrivate=QQQQQQQQcQccIcQ(?=QQ)QQccQQQqQQQQ}16@0:8");
        if (!method || !ivar || size!=NAVI_TEXTURE_CURRENT_SIZE || !metalOwned || !exactEncoding || !exactSignature) {
            record(@{@"event":@"install_rejected",@"size":@(size),@"metal_owned":@(metalOwned),@"encoding":@(exactEncoding),@"signature":@(exactSignature)}); return;
        }
        descriptorClass=c;
        privateOffset=ivar_getOffset(ivar);
        atomic_store(&predecessor,original);
        if (!class_addMethod(c,selector,(IMP)texturePrivate,method_getTypeEncoding(method))) method_setImplementation(class_getInstanceMethod(c,selector),(IMP)texturePrivate);
        record(@{@"event":@"installed",@"pid":@(getpid()),@"program":@(getprogname()),@"executable":@(executablePath),@"selector":@"descriptorPrivate",@"source_size":@(size),
                 @"destination_size":@(NAVI_TEXTURE_DONOR_SIZE),@"private_offset":@(privateOffset),@"predecessor_owner":@(owner.dli_fname)});
    }
}
