// Adapted from mikker/Dinky e05ae28f3e814bbae1cf171567be14e0dcba6548.
// See legal/native-spaces for MIT licenses and upstream attributions.
#import "NativeSpacesPrivate.h"
#import "skylight.h"
#import <objc/runtime.h>

bool winmux_native_capabilities(void) {
    dinky_connection();
    Class create = objc_getClass("SLSBridgedSpaceCreateOperation");
    Class move = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
    Class destroy = objc_getClass("SLSBridgedSpaceDestroyOperation");
    return create && move && destroy &&
        class_getInstanceMethod(create, @selector(initWithOptions:values:)) &&
        class_getInstanceMethod(move, @selector(initWithWindows:spaceID:)) &&
        class_getInstanceMethod(destroy, @selector(initWithSpaceID:)) &&
        class_getInstanceMethod(destroy, @selector(performWithWMBridgeDelegate)) &&
        dinky_skylight_symbol("__ZL54_SLSPerformSynchronousBridgedWindowManagementOperationP46SLSSynchronousBridgedWindowManagementOperation") &&
        dinky_skylight_symbol("__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
}

NSArray<NSNumber *> *winmux_native_all_space_windows(uint64_t spaceID) {
    uint64_t set = 0, clear = 0;
    // No document/level/parent filter: auxiliary or minimized windows prevent deletion too.
    return CFBridgingRelease(SLSCopyWindowsWithOptionsAndTags(dinky_connection(), 0,
        (__bridge CFArrayRef)@[@(spaceID)], 0x7, &set, &clear));
}
NSArray<NSNumber *> *winmux_native_window_spaces(uint32_t windowID) {
    return CFBridgingRelease(SLSCopySpacesForWindows(dinky_connection(), 0x7,
        (__bridge CFArrayRef)@[@(windowID)]));
}
