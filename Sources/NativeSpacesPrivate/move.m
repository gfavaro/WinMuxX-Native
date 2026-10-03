// Adapted from mikker/Dinky e05ae28f3e814bbae1cf171567be14e0dcba6548.
// See legal/native-spaces for MIT licenses and upstream attributions.
#import "move.h"
#import "skylight.h"
#import <objc/runtime.h>

// The asynchronous bridged dispatcher; its argument is the operation object.
typedef int64_t (*SLSPerformAsynchronousBridgedWindowManagementOperationFn)(void *operation);

static SLSPerformAsynchronousBridgedWindowManagementOperationFn dinky_dispatcher(void)
{
    static SLSPerformAsynchronousBridgedWindowManagementOperationFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (SLSPerformAsynchronousBridgedWindowManagementOperationFn)dinky_skylight_symbol(
            "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
    });
    return fn;
}

// Declared so ARC knows init returns +1.
@protocol DinkyBridgedMoveOperation <NSObject>
- (instancetype)initWithWindows:(id)windows spaceID:(uint64_t)spaceID;
@end

bool dinky_move_windows_to_space(const uint32_t *windowIDs, int count, uint64_t spaceID)
{
    @try {

    SLSPerformAsynchronousBridgedWindowManagementOperationFn perform = dinky_dispatcher();
    if (!perform) {
        fputs("move: SLSPerformAsynchronousBridgedWindowManagementOperation not found in SkyLight symtab\n", stderr);
        return false;
    }

    Class cls = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
    if (!cls) {
        fputs("move: class SLSBridgedMoveWindowsToManagedSpaceOperation not found\n", stderr);
        return false;
    }

    NSMutableArray *windows = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; ++i) {
        int32_t wid = (int32_t)windowIDs[i];
        [windows addObject:CFBridgingRelease(CFNumberCreate(NULL, kCFNumberSInt32Type, &wid))];
    }

    id<DinkyBridgedMoveOperation> operation = [(id<DinkyBridgedMoveOperation>)[cls alloc] initWithWindows:windows spaceID:spaceID];
    if (!operation) {
        fputs("move: initWithWindows:spaceID: returned nil\n", stderr);
        return false;
    }

    perform((__bridge void *)operation);
    return true;

    } @catch (NSException *exception) {
        fprintf(stderr, "native Spaces bridge exception: %s\n", exception.name.UTF8String);
        return false;
    }
}
