// Standalone CPU-tested Metal diagnostic. No external Chrome assets required.
// Build: xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation
//        -framework Metal -framework IOSurface msaa_rectangle_minimal.m -o repro
// --self-test and --describe do not enumerate devices or execute Metal.
// --run is the only GPU entry point; --out must name a new absolute directory.
// Geometry/load/resolve semantics derive from Skia Graphite DawnResourceProvider
// at 66cca05ab345fb894cc80ed412e2fa79f687f5d9 and the local draw11129 capture.
// Shaders below are independently simplified equivalents, not exact replay.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const NSUInteger Width=928, Height=256, MSAWidth=1024, Viewport=901;
static const NSUInteger Pitch=3712, ReadbackPitch=3840;
static const uint8_t Blue[4]={251,227,213,255};
static int receipt=-1;

static void require(BOOL condition,NSString *message) {
    if (!condition) { fprintf(stderr,"ERROR: %s\n",message.UTF8String); exit(70); }
}
static void emit(NSDictionary *record) {
    NSError *error=nil;
    NSData *json=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:&error];
    require(json!=nil,[NSString stringWithFormat:@"JSON: %@",error]);
    NSMutableData *line=[json mutableCopy]; [line appendBytes:"\n" length:1];
    require(fwrite(line.bytes,1,line.length,stdout)==line.length,@"stdout write failed"); fflush(stdout);
    if (receipt>=0) require(write(receipt,line.bytes,line.length)==(ssize_t)line.length,@"receipt write failed");
}
static NSArray *pixel(const uint8_t p[4]) { return @[@(p[0]),@(p[1]),@(p[2]),@(p[3])]; }

static NSString *shaderSource(void) {
    return @"#include <metal_stdlib>\n"
    "using namespace metal;\n#pragma METAL fp math_mode(safe)\n"
    "struct CopyOut { float4 position [[position]]; };\n"
    "vertex CopyOut copy_vertex(uint id [[vertex_id]]) {\n"
    "  const float2 p[3]={float2(-1,-1),float2(-1,3),float2(3,-1)};\n"
    "  CopyOut out; out.position=float4(p[id],1,1); return out;\n}\n"
    "fragment float4 load_fragment(float4 p [[position]], texture2d<float> src [[texture(0)]]) {\n"
    "  return src.read(uint2(p.xy),0);\n}\n"
    "fragment float4 resolve_fragment(float4 p [[position]], texture2d_ms<float,access::read> src [[texture(0)]]) {\n"
    "  float4 color=float4(0);\n"
    "  for (uint sample=0;sample<4;sample++) color=color+src.read(uint2(p.xy),sample);\n"
    "  return color*0.25f;\n}\n"
    "struct RectangleOut { float4 position [[position]]; float4 color [[user(locn0)]] [[center_no_perspective]]; };\n"
    "vertex RectangleOut rectangle_vertex(uint id [[vertex_id]]) {\n"
    "  float2 p=float2(float(id/2u)*900.0f,float(id%2u)*256.0f);\n"
    "  float2 scale=as_type<float2>(uint2(0x3b0d3dcbu,0xbc000000u));\n"
    "  RectangleOut out;\n"
    "  out.position=float4(scale*p-float2(1,-1),as_type<float>(0x3f7ffe00u),1);\n"
    "  out.color=as_type<float4>(uint4(0x3f55bfc0u,0x3f63fbc0u,0x3f7c5000u,0x3f800000u));\n"
    "  return out;\n}\n"
    "fragment float4 rectangle_fragment(RectangleOut in [[stage_in]]) { return in.color; }\n";
}

static NSDictionary *describe(BOOL rectangle,NSUInteger repeats) {
    return @{@"event":@"configuration",@"schema":@1,@"standalone":@YES,
        @"experiment":@"synthetic_blue_minimal_rectangle_msaa",
        @"source_width":@(Width),@"source_height":@(Height),@"source_pitch":@(Pitch),
        @"readback_pitch":@(ReadbackPitch),@"msaa_width":@(MSAWidth),@"samples":@4,
        @"copy_viewport":@(Viewport),@"rectangle_viewport":@928,@"rectangle_width":@900,
        @"rectangle_height":@256,@"scissor_width":@901,@"draw_rectangle":@(rectangle),
        @"depth_bits":@"3f7ffe00",@"depth":@0.999969482421875,
        @"rgba_float_bits":@[@"3f55bfc0",@"3f63fbc0",@"3f7c5000",@"3f800000"],
        @"expected_bgra":pixel(Blue),@"repeats":@(repeats),@"requested_math":@"Safe, explicit source pragma and compile option",
        @"state":@"BGRA8 managed IOSurface; private MSAA4 BGRA8 plus paired D32S8; Load/Store color; depth Clear1, stencil Clear0, both DontCare stores; load Always/no depth write; rectangle Less/write; shader resolve, no hardware resolve",
        @"limits":@"Synthetic uniform input and procedural vertex replace capture assets; no allocation history or exact compiler-body equivalence claimed"};
}

typedef struct {
    NSUInteger pixels, channels, firstX, firstY;
    uint8_t expected[4], actual[4];
} Difference;

static Difference compare(const uint8_t *expected, NSUInteger expectedPitch,
                          const uint8_t *actual, NSUInteger actualPitch,
                          NSUInteger width, NSUInteger height) {
    Difference result={0};
    for (NSUInteger y=0;y<height;y++) for (NSUInteger x=0;x<width;x++) {
        const uint8_t *a=actual+y*actualPitch+x*4;
        const uint8_t *e=expected+y*expectedPitch+x*4;
        NSUInteger channels=0;
        for (NSUInteger c=0;c<4;c++) channels+=(a[c]!=e[c]);
        if (channels) {
            if (!result.pixels) {
                result.firstX=x; result.firstY=y;
                memcpy(result.expected,e,4); memcpy(result.actual,a,4);
            }
            result.pixels++; result.channels+=channels;
        }
    }
    return result;
}

static int selfTest(void) {
    const uint8_t expected[16]={251,227,213,255, 251,227,213,255,
                               251,227,213,255, 251,227,213,255};
    // Padding must not count; the one corrupted pixel is at (1,1).
    const uint8_t actual[24]={251,227,213,255, 251,227,213,255, 1,2,3,4,
                             251,227,213,255, 125,113,234,157, 5,6,7,8};
    Difference d=compare(expected,8,actual,12,2,2);
    if (d.pixels!=1 || d.channels!=4 || d.firstX!=1 || d.firstY!=1 ||
        memcmp(d.expected,"\xfb\xe3\xd5\xff",4) ||
        memcmp(d.actual,"\x7d\x71\xea\x9d",4)) {
        fprintf(stderr,"FAIL: padded comparison must identify one literal half-mixture at (1,1)\n");
        return 1;
    }
    if (compare(expected,8,expected,8,2,2).pixels ||
        compare(expected,8,actual,12,0,2).pixels ||
        compare(expected,8,actual,12,2,0).pixels) {
        fprintf(stderr,"FAIL: identical or empty comparisons must be clean\n");
        return 1;
    }
    const uint32_t bits[4]={0x3f55bfc0,0x3f63fbc0,0x3f7c5000,0x3f800000};
    float rgba[4]; memcpy(rgba,bits,sizeof(rgba));
    if (lroundf(rgba[2]*255)!=251 || lroundf(rgba[1]*255)!=227 ||
        lroundf(rgba[0]*255)!=213 || lroundf(rgba[3]*255)!=255) {
        fprintf(stderr,"FAIL: captured float color must quantize to literal expected BGRA\n"); return 1;
    }
    puts("CPU comparator self-test: PASS"); return 0;
}

static void save(NSData *data,NSString *directory,NSString *name) {
    NSError *error=nil;
    require([data writeToFile:[directory stringByAppendingPathComponent:name]
                     options:NSDataWritingWithoutOverwriting error:&error],
            [NSString stringWithFormat:@"save %@: %@",name,error]);
}
static id<MTLDepthStencilState> depthState(id<MTLDevice> device,BOOL rectangle) {
    MTLStencilDescriptor *s=[MTLStencilDescriptor new];
    s.stencilCompareFunction=MTLCompareFunctionAlways;
    s.stencilFailureOperation=MTLStencilOperationKeep; s.depthFailureOperation=MTLStencilOperationKeep;
    s.depthStencilPassOperation=MTLStencilOperationKeep; s.readMask=UINT32_MAX; s.writeMask=UINT32_MAX;
    MTLDepthStencilDescriptor *d=[MTLDepthStencilDescriptor new];
    d.depthCompareFunction=rectangle?MTLCompareFunctionLess:MTLCompareFunctionAlways;
    d.depthWriteEnabled=rectangle; d.frontFaceStencil=s; d.backFaceStencil=s;
    id<MTLDepthStencilState> state=[device newDepthStencilStateWithDescriptor:d];
    require(state!=nil,@"depth state creation failed"); return state;
}
static id<MTLRenderPipelineState> pipeline(id<MTLDevice> device,id<MTLLibrary> library,
                                          NSString *vertex,NSString *fragment,BOOL msaa) {
    MTLRenderPipelineDescriptor *p=[MTLRenderPipelineDescriptor new];
    p.label=fragment; p.vertexFunction=[library newFunctionWithName:vertex];
    p.fragmentFunction=[library newFunctionWithName:fragment];
    require(p.vertexFunction!=nil && p.fragmentFunction!=nil,@"missing shader function");
    p.rasterSampleCount=msaa?4:1; p.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    p.colorAttachments[0].blendingEnabled=NO; p.colorAttachments[0].writeMask=MTLColorWriteMaskAll;
    p.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorOne;
    p.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorZero;
    p.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorOne;
    p.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorZero;
    p.colorAttachments[0].rgbBlendOperation=MTLBlendOperationAdd;
    p.colorAttachments[0].alphaBlendOperation=MTLBlendOperationAdd;
    p.alphaToCoverageEnabled=NO; p.alphaToOneEnabled=NO;
    if (msaa) {
        p.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
        p.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
    }
    NSError *error=nil; id<MTLRenderPipelineState> result=[device newRenderPipelineStateWithDescriptor:p error:&error];
    require(result!=nil,[NSString stringWithFormat:@"pipeline %@: %@",fragment,error]);
    emit(@{@"event":@"pipeline",@"fragment":fragment,@"vertex":vertex,@"samples":@(p.rasterSampleCount),
        @"color_format":@(p.colorAttachments[0].pixelFormat),@"depth_format":@(p.depthAttachmentPixelFormat),
        @"stencil_format":@(p.stencilAttachmentPixelFormat),@"alpha_to_coverage":@(p.alphaToCoverageEnabled),
        @"alpha_to_one":@(p.alphaToOneEnabled),@"blending":@(p.colorAttachments[0].blendingEnabled),
        @"write_mask":@(p.colorAttachments[0].writeMask),@"blend_rgb_source":@(p.colorAttachments[0].sourceRGBBlendFactor),
        @"blend_rgb_destination":@(p.colorAttachments[0].destinationRGBBlendFactor),
        @"blend_alpha_source":@(p.colorAttachments[0].sourceAlphaBlendFactor),
        @"blend_alpha_destination":@(p.colorAttachments[0].destinationAlphaBlendFactor),
        @"blend_rgb_operation":@(p.colorAttachments[0].rgbBlendOperation),
        @"blend_alpha_operation":@(p.colorAttachments[0].alphaBlendOperation)});
    return result;
}
static id<MTLTexture> msaaTexture(id<MTLDevice> device,BOOL depth) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor new];
    d.textureType=MTLTextureType2DMultisample; d.width=MSAWidth; d.height=Height;
    d.sampleCount=4; d.storageMode=MTLStorageModePrivate;
    d.pixelFormat=depth?MTLPixelFormatDepth32Float_Stencil8:MTLPixelFormatBGRA8Unorm;
    d.usage=depth?MTLTextureUsageRenderTarget:MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    id<MTLTexture> texture=[device newTextureWithDescriptor:d];
    require(texture!=nil,@"MSAA texture creation failed"); return texture;
}
static MTLRenderPassDescriptor *pass(id<MTLTexture> color,id<MTLTexture> depth) {
    MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor renderPassDescriptor];
    p.colorAttachments[0].texture=color; p.colorAttachments[0].loadAction=MTLLoadActionLoad;
    p.colorAttachments[0].storeAction=MTLStoreActionStore;
    p.colorAttachments[0].storeActionOptions=MTLStoreActionOptionNone;
    p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
    if (depth) {
        p.depthAttachment.texture=depth; p.stencilAttachment.texture=depth;
        p.depthAttachment.loadAction=MTLLoadActionClear; p.depthAttachment.clearDepth=1;
        p.depthAttachment.storeAction=MTLStoreActionDontCare;
        p.stencilAttachment.loadAction=MTLLoadActionClear; p.stencilAttachment.clearStencil=0;
        p.stencilAttachment.storeAction=MTLStoreActionDontCare;
    }
    return p;
}
static void setRasterState(id<MTLRenderCommandEncoder> e,NSUInteger viewport) {
    [e setViewport:(MTLViewport){0,0,(double)viewport,256,0,1}];
    [e setScissorRect:(MTLScissorRect){0,0,Viewport,Height}];
    [e setFrontFacingWinding:MTLWindingCounterClockwise]; [e setCullMode:MTLCullModeNone];
    [e setDepthClipMode:MTLDepthClipModeClip]; [e setDepthBias:0 slopeScale:0 clamp:0];
}
static NSDictionary *textureRecord(id<MTLTexture> t) {
    return @{@"width":@(t.width),@"height":@(t.height),@"samples":@(t.sampleCount),
        @"pixel_format":@(t.pixelFormat),@"type":@(t.textureType),@"usage":@(t.usage),
        @"storage":@(t.storageMode),@"hazard":@(t.hazardTrackingMode),
        @"gpu_optimized":@(t.allowGPUOptimizedContents),@"mip_levels":@(t.mipmapLevelCount),
        @"array_length":@(t.arrayLength)};
}
static void complete(id<MTLCommandBuffer> cb) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> finished) { (void)finished; dispatch_semaphore_signal(done); }];
    [cb commit];
    require(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))==0,@"GPU timeout; aborting test");
    require(cb.status==MTLCommandBufferStatusCompleted && cb.error==nil,
            [NSString stringWithFormat:@"GPU completion failed: %@",cb.error]);
}
static int run(NSString *directory,BOOL rectangle,NSUInteger repeats) {
    NSError *error=nil;
    require(directory.isAbsolutePath,@"--out must be absolute");
    require(![[NSFileManager defaultManager] fileExistsAtPath:directory],@"--out must be a new directory");
    require([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:&error],
            [NSString stringWithFormat:@"create output: %@",error]);
    receipt=open([[directory stringByAppendingPathComponent:@"results.jsonl"] fileSystemRepresentation],O_CREAT|O_EXCL|O_WRONLY,0600);
    require(receipt>=0,@"cannot create receipt");
    emit(describe(rectangle,repeats));
    save([shaderSource() dataUsingEncoding:NSUTF8StringEncoding],directory,@"minimal.metal");
    NSString *trace=[directory stringByAppendingPathComponent:@"compiler.log"];
    require(setenv("NAVI_SHIM_COMPILER_TRACE",trace.fileSystemRepresentation,1)==0,@"compiler trace environment failed");

    id<MTLDevice> device=nil;
    for (id<MTLDevice> candidate in MTLCopyAllDevices()) {
        if (!strcmp(object_getClassName(candidate),"GFX10_MtlDevice") && [candidate.name containsString:@"5700 XT"]) {
            require(device==nil,@"ambiguous target GPUs"); device=candidate;
        }
    }
    require(device!=nil,@"RX5700XT GFX10_MtlDevice not found");
    require([device supportsTextureSampleCount:4],@"four-sample textures unsupported");
    MTLCompileOptions *options=[MTLCompileOptions new];
    if (@available(macOS 15.0,*)) options.mathMode=MTLMathModeSafe;
    else require(NO,@"This diagnostic requires macOS 15 compile options");
    if (@available(macOS 15.0,*)) emit(@{@"event":@"compile_options",@"math_mode":@(options.mathMode),
        @"math_floating_point_functions":@(options.mathFloatingPointFunctions),@"source_pragma":@"safe",
        @"language_version":@(options.languageVersion)});
    id<MTLLibrary> library=[device newLibraryWithSource:shaderSource() options:options error:&error];
    require(library!=nil,[NSString stringWithFormat:@"Metal source compile: %@",error]);
    emit(@{@"event":@"device",@"name":device.name,@"class":@(object_getClassName(device)),
           @"registry_id":@(device.registryID),@"requested_math_mode":@0,@"source_pragma":@"safe",@"compiler_trace":trace});
    id<MTLRenderPipelineState> load=pipeline(device,library,@"copy_vertex",@"load_fragment",YES);
    id<MTLRenderPipelineState> resolve=pipeline(device,library,@"copy_vertex",@"resolve_fragment",NO);
    id<MTLRenderPipelineState> rect=pipeline(device,library,@"rectangle_vertex",@"rectangle_fragment",YES);
    id<MTLDepthStencilState> copyDepth=depthState(device,NO),rectDepth=depthState(device,YES);
    IOSurfaceRef surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (id)kIOSurfaceWidth:@(Width),(id)kIOSurfaceHeight:@(Height),(id)kIOSurfaceBytesPerElement:@4,
        (id)kIOSurfaceBytesPerRow:@(Pitch),(id)kIOSurfaceAllocSize:@(Pitch*Height),
        (id)kIOSurfacePixelFormat:@(0x42475241U)});
    require(surface!=NULL,@"IOSurface creation failed");
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:Width height:Height mipmapped:NO];
    d.storageMode=MTLStorageModeManaged; d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    id<MTLTexture> color=[device newTextureWithDescriptor:d iosurface:surface plane:0];
    id<MTLTexture> msaa=msaaTexture(device,NO),depth=msaaTexture(device,YES);
    require(color!=nil,@"IOSurface Metal texture failed");
    require(IOSurfaceGetBytesPerRow(surface)==Pitch,@"unexpected IOSurface pitch");
    id<MTLBuffer> readback=[device newBufferWithLength:ReadbackPitch*Height options:MTLResourceStorageModeManaged];
    id<MTLCommandQueue> queue=[device newCommandQueue]; require(readback!=nil && queue!=nil,@"queue or readback unavailable");
    emit(@{@"event":@"resources",@"surface_id":@(IOSurfaceGetID(surface)),@"surface_pitch":@(IOSurfaceGetBytesPerRow(surface)),
        @"source":textureRecord(color),@"msaa":textureRecord(msaa),@"depth_stencil":textureRecord(depth),
        @"readback_storage":@(readback.storageMode),@"readback_pitch":@(ReadbackPitch),
        @"readback_length":@(readback.length)});
    NSMutableData *input=[NSMutableData dataWithLength:Pitch*Height];
    for (NSUInteger p=0;p<Width*Height;p++) memcpy((uint8_t *)input.mutableBytes+p*4,Blue,4);
    save(input,directory,@"input.bgra");
    BOOL failed=NO;
    for (NSUInteger repeat=0;repeat<repeats;repeat++) @autoreleasepool {
        [color replaceRegion:MTLRegionMake2D(0,0,Width,Height) mipmapLevel:0 withBytes:input.bytes bytesPerRow:Pitch];
        id<MTLCommandBuffer> cb=[queue commandBuffer]; require(cb!=nil,@"command buffer unavailable");
        id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:pass(msaa,depth)]; require(e!=nil,@"load encoder unavailable");
        [e setRenderPipelineState:load]; [e setDepthStencilState:copyDepth]; setRasterState(e,Viewport);
        [e setFragmentTexture:color atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:3 instanceCount:1];
        if (rectangle) {
            [e setRenderPipelineState:rect]; [e setDepthStencilState:rectDepth]; setRasterState(e,Width);
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:1];
        }
        [e endEncoding];
        e=[cb renderCommandEncoderWithDescriptor:pass(color,nil)]; require(e!=nil,@"resolve encoder unavailable");
        [e setRenderPipelineState:resolve]; [e setDepthStencilState:copyDepth]; setRasterState(e,Viewport);
        [e setFragmentTexture:msaa atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:3 instanceCount:1]; [e endEncoding];
        id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder]; require(blit!=nil,@"readback encoder unavailable");
        [blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(Width,Height,1)
                    toBuffer:readback destinationOffset:0 destinationBytesPerRow:ReadbackPitch destinationBytesPerImage:ReadbackPitch*Height];
        [blit synchronizeResource:readback]; [blit endEncoding]; complete(cb);
        require(readback.contents!=NULL,@"readback contents unavailable");
        Difference all=compare(input.bytes,Pitch,readback.contents,ReadbackPitch,Width,Height);
        Difference roi=compare((uint8_t *)input.bytes+180*Pitch+32*4,Pitch,
                               (uint8_t *)readback.contents+180*ReadbackPitch+32*4,ReadbackPitch,836,60);
        NSMutableDictionary *row=[@{@"event":@"result",@"repeat":@(repeat),@"whole_bad_pixels":@(all.pixels),
            @"roi_bad_pixels":@(roi.pixels),@"roi_bad_channels":@(roi.channels),@"gpu_status":@(cb.status),
            @"status":all.pixels?@"different":@"identical"} mutableCopy];
        if (roi.pixels) row[@"first_roi_difference"]=@{@"x":@(roi.firstX+32),@"y":@(roi.firstY+180),
            @"expected_bgra":pixel(roi.expected),@"actual_bgra":pixel(roi.actual)};
        NSString *name=[NSString stringWithFormat:@"output-%04lu.bgra",(unsigned long)repeat]; row[@"output_file"]=name;
        NSMutableData *tight=[NSMutableData dataWithLength:Pitch*Height];
        for (NSUInteger y=0;y<Height;y++) memcpy((uint8_t *)tight.mutableBytes+y*Pitch,(uint8_t *)readback.contents+y*ReadbackPitch,Pitch);
        save(tight,directory,name); emit(row); failed|=(all.pixels!=0);
    }
    CFRelease(surface);
    emit(@{@"event":@"summary",@"status":failed?@"expected_pixels_diverged":@"identical",
           @"interpretation":failed?@"Synthetic valid-color redraw or copy path diverged; not yet a root-cause attribution":@"This simplified workload did not reproduce the corruption"});
    require(close(receipt)==0,@"receipt close failed"); receipt=-1;
    return failed?1:0;
}

int main(int argc,const char **argv) {
    @autoreleasepool {
        if (argc==2 && strcmp(argv[1],"--self-test")==0) return selfTest();
        BOOL execute=NO,description=NO,rectangle=YES; NSUInteger repeats=3; NSString *directory=nil;
        if (argc==1 || (argc==2 && !strcmp(argv[1],"--help"))) {
            puts("msaa_rectangle_minimal --self-test | --describe | --run --out NEW_ABSOLUTE_DIR [--repeat 1..16] [--load-resolve-only]\nOnly --run executes Metal. Exit 0=clean, 1=pixel mismatch, 70=setup/command failure."); return 0;
        }
        for (int i=1;i<argc;i++) {
            NSString *arg=@(argv[i]);
            if ([arg isEqualToString:@"--run"]) execute=YES;
            else if ([arg isEqualToString:@"--describe"]) description=YES;
            else if ([arg isEqualToString:@"--load-resolve-only"]) rectangle=NO;
            else if ([arg isEqualToString:@"--out"]) { require(++i<argc,@"--out value required"); directory=@(argv[i]); }
            else if ([arg isEqualToString:@"--repeat"]) {
                require(++i<argc,@"--repeat value required"); char *end=NULL; long value=strtol(argv[i],&end,10);
                require(end!=argv[i] && *end==0 && value>=1 && value<=16,@"--repeat must be 1..16"); repeats=(NSUInteger)value;
            } else require(NO,[NSString stringWithFormat:@"unknown argument %@",arg]);
        }
        require(execute!=description,@"choose exactly one of --run or --describe");
        if (description) { emit(describe(rectangle,repeats)); return 0; }
        return run(directory,rectangle,repeats);
    }
}
