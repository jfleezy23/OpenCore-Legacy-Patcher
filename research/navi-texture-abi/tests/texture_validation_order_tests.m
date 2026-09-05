// Diagnostic only: no hooks, texture allocations, command queues, or submission.
// --run enumerates devices and calls the actual current-Metal validator against
// the exact loaded GFX10 donor. Run only with the coordinated device/GPU lease.
// Build: xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation
//        -framework Metal tests/texture_validation_order_tests.m -o /tmp/probe
// Run: probe --run --out /absolute/new-validation-order.jsonl
// --describe does not enumerate devices or call the validator.
// This characterizes duplicate-validation idempotence; it does NOT fix or test
// the complete tiled/shared-property allocation path, nor prove zero side effects.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum { PrivateSize=200 };
static int receipt=-1;
static Class descriptorClass;
static ptrdiff_t privateOffset;
static SEL validateSelector;
static IMP validateImplementation;
static const char ExpectedPrivateEncoding[]=
    "{MTLTextureDescriptorPrivate=\"textureType\"Q\"pixelFormat\"Q\"width\"Q\"height\"Q\"depth\"Q\"mipmapLevelCount\"Q\"sampleCount\"Q\"arrayLength\"Q\"zeroFill\"c\"rotation\"Q\"framebufferOnly\"c\"isDrawable\"c\"swizzle\"I\"writeSwizzleEnabled\"c\"compressionMode\"Q\"\"(?=\"textureUsage\"Q\"usage\"Q)\"resourceOptions\"Q\"sparseSurfaceDefaultValue\"Q\"allowGPUOptimizedContents\"c\"forceResourceIndex\"c\"resourceIndex\"Q\"protectionOptions\"Q\"compressionFootprint\"Q\"compressionType\"q\"colorSpaceConversionMatrix\"Q\"resolvedUsage\"Q\"cpuCacheMode\"Q\"storageMode\"Q}";
static const char DonorImage[]=
    "/System/Library/Extensions/AMDRadeonX6000MTLDriver.bundle/Contents/MacOS/AMDRadeonX6000MTLDriver";

static void demand(BOOL condition,const char *message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message); exit(70); }
}
static void emit(NSDictionary *row) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:NULL];
    demand(data!=nil,"JSON serialization");
    demand(fwrite(data.bytes,1,data.length,stdout)==data.length,"stdout write");
    demand(fputc('\n',stdout)!=EOF,"stdout newline"); fflush(stdout);
    if (receipt>=0) {
        demand(write(receipt,data.bytes,data.length)==(ssize_t)data.length,"receipt write");
        demand(write(receipt,"\n",1)==1,"receipt newline");
    }
}
static void timeoutHandler(int value) {
    (void)value;
    const char message[]="FAIL: descriptor-only validation exceeded45 seconds\n";
    (void)write(STDERR_FILENO,message,sizeof(message)-1); _exit(124);
}
static const uint8_t *privateBytes(id descriptor) {
    demand(object_getClass(descriptor)==descriptorClass,"unexpected descriptor class");
    return (const uint8_t *)(__bridge void *)descriptor+privateOffset;
}
static NSData *snapshot(id descriptor) {
    return [NSData dataWithBytes:privateBytes(descriptor) length:PrivateSize];
}
static NSString *hex(NSData *data) {
    const uint8_t *bytes=data.bytes;
    NSMutableString *result=[NSMutableString stringWithCapacity:data.length*2];
    for (NSUInteger i=0;i<data.length;i++) [result appendFormat:@"%02x",bytes[i]];
    return result;
}
static NSArray *changes(NSData *before,NSData *after) {
    demand(before.length==PrivateSize && after.length==PrivateSize,"snapshot length");
    const uint8_t *a=before.bytes,*b=after.bytes;
    NSMutableArray *result=[NSMutableArray new];
    for (NSUInteger i=0;i<PrivateSize;i++) if(a[i]!=b[i])
        [result addObject:@{@"offset":@(i),@"before":@(a[i]),@"after":@(b[i])}];
    return result;
}
static NSArray *tail(NSData *data) {
    uint64_t values[3]; memcpy(values,(const uint8_t *)data.bytes+0xb0,sizeof(values));
    return @[@(values[0]),@(values[1]),@(values[2])];
}
static NSDictionary *validate(id descriptor,id<MTLDevice> device) {
    Method method=class_getInstanceMethod(descriptorClass,validateSelector);
    demand(method_getImplementation(method)==validateImplementation,"validator changed during diagnostic");
    @try {
        BOOL result=((BOOL(*)(id,SEL,id))validateImplementation)(descriptor,validateSelector,device);
        return @{@"returned":@(result),@"exception":[NSNull null]};
    } @catch(NSException *exception) {
        return @{@"returned":[NSNull null],@"exception":exception.name?:@"unknown",
                 @"reason":exception.reason?:@""};
    }
}

// Catches a changed return value, extra normalized-field mutation on the second
// call, exception, or unreadable source layout. Expectations do not come from
// the bridge: the actual validator is invoked twice and all200 bytes compared.
static BOOL runCase(MTLTextureDescriptor *descriptor,id<MTLDevice> device,
                    NSString *profile,NSString *lifecycle,NSUInteger usage,
                    NSUInteger *rejected) {
    NSData *before=snapshot(descriptor);
    NSDictionary *first=validate(descriptor,device); NSData *afterFirst=snapshot(descriptor);
    NSDictionary *second=validate(descriptor,device); NSData *afterSecond=snapshot(descriptor);
    BOOL sameResults=[first isEqual:second];
    BOOL sameBytes=[afterFirst isEqualToData:afterSecond];
    BOOL noException=first[@"exception"]==[NSNull null] && second[@"exception"]==[NSNull null];
    BOOL accepted=noException && [first[@"returned"] boolValue] && [second[@"returned"] boolValue];
    if (!accepted) ++*rejected;
    BOOL stable=sameResults && sameBytes && noException;
    emit(@{@"event":@"validation_case",@"profile":profile,@"lifecycle":lifecycle,
           @"requested_usage":@(usage),@"first":first,@"second":second,
           @"same_results":@(sameResults),@"all_200_bytes_equal":@(sameBytes),
           @"stable":@(stable),@"accepted":@(accepted),
           @"initial_tail":tail(before),@"first_tail":tail(afterFirst),@"second_tail":tail(afterSecond),
           @"first_changes":changes(before,afterFirst),@"second_changes":changes(afterFirst,afterSecond),
           @"initial_hex":hex(before),@"first_hex":hex(afterFirst),@"second_hex":hex(afterSecond)});
    return stable;
}
static void configure(MTLTextureDescriptor *descriptor,NSUInteger profile,NSUInteger usage) {
    descriptor.textureType=profile==2?MTLTextureType2DMultisample:MTLTextureType2D;
    descriptor.pixelFormat=MTLPixelFormatBGRA8Unorm;
    descriptor.width=profile==0?928:1024; descriptor.height=256; descriptor.depth=1;
    descriptor.mipmapLevelCount=1; descriptor.arrayLength=1; descriptor.sampleCount=profile==2?4:1;
    descriptor.storageMode=profile==0?MTLStorageModeManaged:MTLStorageModePrivate;
    descriptor.cpuCacheMode=MTLCPUCacheModeDefaultCache;
    descriptor.hazardTrackingMode=MTLHazardTrackingModeTracked;
    descriptor.usage=(MTLTextureUsage)usage;
    descriptor.allowGPUOptimizedContents=YES;
}
static NSDictionary *description(void) {
    return @{@"event":@"description",@"schema":@1,@"descriptor_only":@YES,
        @"profiles":@[@"managed_2d_iosurface_like",@"private_2d",@"private_msaa4"],
        @"usages":@[@0,@1,@4,@5],
        @"lifecycles":@[@"fresh",@"copy_unvalidated",@"copy_validated",@"reuse_mutated"],
        @"cases":@48,@"private_bytes":@200,@"device_enumeration_requires_run":@YES,
        @"textures_allocated":@0,@"command_queues":@0,@"commands_submitted":@0,
        @"limits":@"No IOSurface allocation/import, tiled texture construction, shared-property construction, matrix support, concurrency, failure-path ownership, or production compatibility claim. Keep stderr to inspect validator diagnostics."};
}
static void verifyLayout(void) {
    descriptorClass=NSClassFromString(@"MTLTextureDescriptorInternal");
    demand(descriptorClass!=Nil,"missing current descriptor class");
    Ivar ivar=class_getInstanceVariable(descriptorClass,"_private");
    demand(ivar && !strcmp(ivar_getTypeEncoding(ivar),ExpectedPrivateEncoding),"unexpected private encoding");
    NSUInteger size=0,alignment=0; NSGetSizeAndAlignment(ivar_getTypeEncoding(ivar),&size,&alignment);
    privateOffset=ivar_getOffset(ivar);
    demand(size==PrivateSize && privateOffset>=0 &&
           class_getInstanceSize(descriptorClass)>=(NSUInteger)privateOffset+PrivateSize,"private bounds");
    validateSelector=sel_registerName("validateWithDevice:");
    Method method=class_getInstanceMethod(descriptorClass,validateSelector);
    demand(method && !strcmp(method_getTypeEncoding(method),"c24@0:8@16"),"unexpected validator signature");
    validateImplementation=method_getImplementation(method);
    Dl_info owner={0};
    demand(dladdr((void *)validateImplementation,&owner) && owner.dli_fname &&
           !strcmp(owner.dli_fname,"/System/Library/Frameworks/Metal.framework/Versions/A/Metal"),"validator not current system Metal");
    emit(@{@"event":@"validated_runtime_contract",@"private_size":@(size),@"private_offset":@(privateOffset),
           @"validator_owner":@(owner.dli_fname),@"validator_image_offset":@((uintptr_t)validateImplementation-(uintptr_t)owner.dli_fbase),
           @"signature":@(method_getTypeEncoding(method)),@"encoding":@(ivar_getTypeEncoding(ivar))});
}
int main(int argc,char **argv) {
    @autoreleasepool {
        if(argc==2 && !strcmp(argv[1],"--describe")) { emit(description()); return 0; }
        if(argc!=4 || strcmp(argv[1],"--run") || strcmp(argv[2],"--out") || argv[3][0]!='/') {
            fprintf(stderr,"Usage: %s --describe | --run --out /absolute/new.jsonl\n",argv[0]); return 64;
        }
        receipt=open(argv[3],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
        demand(receipt>=0,"receipt must be a new absolute file");
        signal(SIGALRM,timeoutHandler); alarm(45);
        emit(description());
        id<MTLDevice> selected=nil;
        for(id<MTLDevice> device in MTLCopyAllDevices()) {
            Class c=object_getClass(device); const char *image=class_getImageName(c);
            if(!strcmp(class_getName(c),"GFX10_MtlDevice") && image && !strcmp(image,DonorImage) &&
               [device.name containsString:@"5700"]) {
                demand(selected==nil,"multiple matching Navi devices"); selected=device;
            }
        }
        demand(selected!=nil,"exact loaded RX5700 GFX10 donor device not found");
        emit(@{@"event":@"device",@"name":selected.name,@"registry_id":@(selected.registryID),
               @"class":@(object_getClassName(selected)),@"image":@(class_getImageName(object_getClass(selected))),
               @"enumerated":@YES,@"commands_submitted":@0});
        verifyLayout();
        NSUInteger total=0,failed=0,rejected=0;
        const NSUInteger usages[]={0,1,4,5};
        NSArray<NSString *> *profiles=@[@"managed_2d_iosurface_like",@"private_2d",@"private_msaa4"];
        for(NSUInteger p=0;p<profiles.count;p++) {
            MTLTextureDescriptor *reuse=[MTLTextureDescriptor new];
            for(NSUInteger u=0;u<4;u++) @autoreleasepool {
                MTLTextureDescriptor *fresh=[MTLTextureDescriptor new]; configure(fresh,p,usages[u]);
                MTLTextureDescriptor *copyUnvalidated=[fresh copy];
                failed+=!runCase(fresh,selected,profiles[p],@"fresh",usages[u],&rejected); total++;
                failed+=!runCase(copyUnvalidated,selected,profiles[p],@"copy_unvalidated",usages[u],&rejected); total++;
                MTLTextureDescriptor *copyValidated=[fresh copy];
                failed+=!runCase(copyValidated,selected,profiles[p],@"copy_validated",usages[u],&rejected); total++;
                configure(reuse,p,usages[u]);
                failed+=!runCase(reuse,selected,profiles[p],@"reuse_mutated",usages[u],&rejected); total++;
            }
        }
        emit(@{@"event":@"summary",@"cases":@(total),@"unstable_or_exception_cases":@(failed),
               @"rejected_cases":@(rejected),@"all_idempotent":@(failed==0),
               @"all_accepted":@(rejected==0),@"commands_submitted":@0,
               @"limits":@"Idempotence of results and descriptor bytes only; no allocation-order fix or general production claim."});
        alarm(0); close(receipt); receipt=-1;
        return failed?1:(rejected?2:0);
    }
}
