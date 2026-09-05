// CPU-only regression tests. The real implementation is included to exercise
// its static retainedVersion function without exposing a production test API.
// Build: clang -arch x86_64 -mmacosx-version-min=14.5 -fobjc-arc -fmodules
// -Wall -Wextra -Werror -Isrc tests/texture_abi_lifetime_tests.m
// src/texture_descriptor_abi.c -framework Foundation -framework Metal -o /tmp/...
// Run with: env -u NAVI_TEXTURE_ABI_LAB -u NAVI_TEXTURE_ABI_TRACE
// -u DYLD_INSERT_LIBRARIES /tmp/.../texture_abi_lifetime_tests
#ifndef TEXTURE_ABI_LIFETIME_IMPLEMENTATION
#define TEXTURE_ABI_LIFETIME_IMPLEMENTATION "../tools/texture_descriptor_abi_lab.m"
#endif
#include TEXTURE_ABI_LIFETIME_IMPLEMENTATION
#include <signal.h>

static void deadlineExpired(int signalNumber) {
    (void)signalNumber;
    const char message[]="FAIL: CPU lifetime suite exceeded 30-second deadline\n";
    (void)write(STDERR_FILENO,message,sizeof(message)-1); _exit(124);
}

static void demand(BOOL condition,const char *message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
static void passed(const char *name) {
    printf("{\"event\":\"test_passed\",\"name\":\"%s\",\"gpu_initialized\":false}\n",name);
}
static void bytesForToken(uint8_t *bytes,uint64_t token) {
    memset(bytes,0x5a,NAVI_TEXTURE_DONOR_SIZE);
    memcpy(bytes,&token,sizeof(token));
}
static void expectToken(const void *pointer,uint64_t token,const char *message) {
    uint8_t expected[NAVI_TEXTURE_DONOR_SIZE]; bytesForToken(expected,token);
    demand(pointer && !memcmp(pointer,expected,sizeof(expected)),message);
}
static const void *makeVersion(id descriptor,uint64_t token) {
    uint8_t bytes[NAVI_TEXTURE_DONOR_SIZE]; bytesForToken(bytes,token);
    NSData *version=retainedVersion(descriptor,bytes);
    demand(version!=nil,"version unexpectedly unavailable below cap");
    demand(version.bytes!=bytes,"version must not alias caller stack storage");
    const void *pointer=version.bytes;
    // Catches switching dataWithBytes to a no-copy wrapper around caller memory.
    memset(bytes,0xe1,sizeof(bytes)); expectToken(pointer,token,"source mutation changed retained bytes");
    return pointer;
}
static void testOldPointers(void) {
    id descriptor=[MTLTextureDescriptor new]; const void *first=NULL;
    @autoreleasepool { first=makeVersion(descriptor,0x101); }
    for (uint64_t token=0x102;token<0x182;token++) @autoreleasepool {
        const void *current=makeVersion(descriptor,token);
        expectToken(first,0x101,"a later version overwrote the first pointer");
        expectToken(current,token,"new version bytes are incorrect");
    }
    uint8_t bytes[NAVI_TEXTURE_DONOR_SIZE]; bytesForToken(bytes,0x181);
    const void *last=retainedVersion(descriptor,bytes).bytes;
    @autoreleasepool {
        demand(retainedVersion(descriptor,bytes).bytes==last,"identical consecutive requests should reuse last immutable version");
    }
    expectToken(first,0x101,"first pointer did not survive autorelease drains");
    passed("old_raw_pointers_and_input_copy");
}
static void nestedVersions(id descriptor,NSUInteger depth) {
    const uint64_t token=0x9000+depth; const void *outer=NULL;
    @autoreleasepool { outer=makeVersion(descriptor,token); }
    if (depth) nestedVersions(descriptor,depth-1);
    expectToken(outer,token,"nested same-thread call overwrote an outer pointer");
}
static void testNested(void) {
    id descriptor=[MTLTextureDescriptor new]; nestedVersions(descriptor,32);
    passed("nested_same_thread_versions");
}
static void testOwnerLifetime(void) {
    __weak NSData *firstWeak=nil;
    __weak NSData *secondWeak=nil;
    const void *secondPointer=NULL;
    @autoreleasepool {
        id second=[MTLTextureDescriptor new];
        @autoreleasepool {
            id first=[MTLTextureDescriptor new];
            uint8_t a[NAVI_TEXTURE_DONOR_SIZE],b[NAVI_TEXTURE_DONOR_SIZE];
            bytesForToken(a,0xaaa); bytesForToken(b,0xbbb);
            @autoreleasepool {
                NSData *firstVersion=retainedVersion(first,a); firstWeak=firstVersion;
                NSData *secondVersion=retainedVersion(second,b); secondWeak=secondVersion;
                secondPointer=secondVersion.bytes;
            }
            demand(firstWeak!=nil && secondWeak!=nil,"descriptor association did not retain returned versions");
            for (NSUInteger i=0;i<32;i++) @autoreleasepool { (void)makeVersion(first,0x10000+i); }
            expectToken(secondPointer,0xbbb,"other descriptor mutated retained bytes");
        }
        demand(firstWeak==nil,"versions outlived their descriptor owner");
        // Keep weak-load temporaries inside the owner's surrounding pool.
        demand(secondWeak!=nil,"releasing another descriptor invalidated this owner");
        expectToken(secondPointer,0xbbb,"descriptor isolation lost surviving bytes");
        second=nil;
    }
    demand(secondWeak==nil,"second descriptor versions leaked after owner release");
    passed("descriptor_isolation_and_release");
}
enum { WorkerCount=4, WorkerVersions=128 };
typedef struct {
    void *descriptor;
    NSUInteger index;
    dispatch_semaphore_t ready,start,written,verify,done;
} WorkerContext;
static void waitSignal(dispatch_semaphore_t signal,const char *message) {
    demand(dispatch_semaphore_wait(signal,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,message);
}
static void *worker(void *opaque) {
    WorkerContext *context=opaque;
    @autoreleasepool {
        id descriptor=(__bridge id)context->descriptor;
        const void *pointers[WorkerVersions]={0};
        dispatch_semaphore_signal(context->ready); waitSignal(context->start,"worker start timeout");
        for (NSUInteger i=0;i<WorkerVersions;i++) @autoreleasepool {
            uint64_t token=((uint64_t)(context->index+1)<<32)|i;
            pointers[i]=makeVersion(descriptor,token);
        }
        dispatch_semaphore_signal(context->written); waitSignal(context->verify,"worker verify timeout");
        // Every other thread has completed its writes before old pointers read.
        for (NSUInteger i=0;i<WorkerVersions;i++)
            expectToken(pointers[i],((uint64_t)(context->index+1)<<32)|i,"concurrent thread invalidated immutable bytes");
        dispatch_semaphore_signal(context->done);
    }
    return NULL;
}
static void testConcurrent(void) {
    id descriptor=[MTLTextureDescriptor new]; pthread_t threads[WorkerCount];
    WorkerContext contexts[WorkerCount];
    dispatch_semaphore_t ready=dispatch_semaphore_create(0),start=dispatch_semaphore_create(0);
    dispatch_semaphore_t written=dispatch_semaphore_create(0),verify=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0);
    for (NSUInteger i=0;i<WorkerCount;i++) {
        contexts[i]=(WorkerContext){(__bridge void *)descriptor,i,ready,start,written,verify,done};
        demand(pthread_create(&threads[i],NULL,worker,&contexts[i])==0,"cannot create bounded test worker");
    }
    for (NSUInteger i=0;i<WorkerCount;i++) waitSignal(ready,"workers ready timeout");
    for (NSUInteger i=0;i<WorkerCount;i++) dispatch_semaphore_signal(start);
    for (NSUInteger i=0;i<WorkerCount;i++) waitSignal(written,"workers write timeout");
    for (NSUInteger i=0;i<WorkerCount;i++) dispatch_semaphore_signal(verify);
    for (NSUInteger i=0;i<WorkerCount;i++) waitSignal(done,"workers completion timeout");
    for (NSUInteger i=0;i<WorkerCount;i++) demand(pthread_join(threads[i],NULL)==0,"worker join failed");
    passed("four_threads_512_versions_read_after_all_writes");
}
static void testCapacity(void) {
    id descriptor=[MTLTextureDescriptor new]; const void *first=NULL,*last=NULL;
    for (NSUInteger i=0;i<4096;i++) @autoreleasepool {
        last=makeVersion(descriptor,i+1); if (!i) first=last;
    }
    uint8_t bytes[NAVI_TEXTURE_DONOR_SIZE]; bytesForToken(bytes,4097);
    demand(retainedVersion(descriptor,bytes)==nil,"4097th distinct version should report capacity exhaustion");
    expectToken(first,1,"capacity exhaustion invalidated oldest pointer");
    expectToken(last,4096,"capacity exhaustion changed last pointer");
    bytesForToken(bytes,4096);
    demand(retainedVersion(descriptor,bytes).bytes==last,"last duplicate should remain available at capacity");
    id other=[MTLTextureDescriptor new]; (void)makeVersion(other,0xabcdef);
    // A second real thread must still have its independent per-thread capacity.
    WorkerContext context={(__bridge void *)descriptor,0,dispatch_semaphore_create(0),dispatch_semaphore_create(0),
        dispatch_semaphore_create(0),dispatch_semaphore_create(0),dispatch_semaphore_create(0)};
    pthread_t thread; demand(pthread_create(&thread,NULL,worker,&context)==0,"cannot create capacity-isolation worker");
    waitSignal(context.ready,"capacity worker ready timeout"); dispatch_semaphore_signal(context.start);
    waitSignal(context.written,"capacity worker write timeout"); dispatch_semaphore_signal(context.verify);
    waitSignal(context.done,"capacity worker completion timeout"); demand(pthread_join(thread,NULL)==0,"capacity worker join failed");
    expectToken(first,1,"other thread changed capped thread's old pointer");
    puts("{\"event\":\"capacity_observed\",\"accepted_distinct_versions_per_thread\":4096,\"next_distinct_returns_nil\":true,\"duplicate_still_available\":true,\"other_thread_unaffected\":true}");
    passed("capacity_preserves_old_versions_and_isolation");
}
int main(int argc,const char **argv) {
    (void)argc; (void)argv;
    signal(SIGALRM,deadlineExpired); alarm(30);
    @autoreleasepool {
        demand(getenv("NAVI_TEXTURE_ABI_LAB")==NULL,"run with NAVI_TEXTURE_ABI_LAB absent, not merely zero");
        demand(getenv("DYLD_INSERT_LIBRARIES")==NULL,"run without injected libraries");
        demand(atomic_load(&predecessor)==NULL && logFD==-1,"constructor must remain inactive");
        testOldPointers(); testNested(); testOwnerLifetime(); testConcurrent(); testCapacity();
        demand(atomic_load(&predecessor)==NULL && logFD==-1,"tests must not activate the hook");
        puts("{\"event\":\"summary\",\"tests\":5,\"status\":\"passed\",\"hook_installed\":false,\"gpu_initialized\":false}");
    }
    alarm(0);
    return 0;
}
