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
    CFArrayRef windows = SLSCopyWindowsWithOptionsAndTags(dinky_connection(), 0,
        (__bridge CFArrayRef)@[@(spaceID)], 0x7, &set, &clear);
    if (!windows) return nil;
    CFTypeRef query = SLSWindowQueryWindows(dinky_connection(), windows, (int)CFArrayGetCount(windows));
    CFRelease(windows);
    if (!query) return nil;
    CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);
    CFRelease(query);
    if (!iterator) return nil;
    NSMutableArray<NSNumber *> *result = [NSMutableArray array];
    while (SLSWindowIteratorAdvance(iterator)) {
        // Backgrounds, desktop dimmers and menu chrome have no document/modal
        // tags. Keep content and attached auxiliary windows, including minimized
        // ones, so unknown application content still prevents reassignment/deletion.
        if (winmux_native_is_content_window(SLSWindowIteratorGetParentID(iterator), SLSWindowIteratorGetTags(iterator))) {
            [result addObject:@(SLSWindowIteratorGetWindowID(iterator))];
        }
    }
    CFRelease(iterator);
    return result;
}
NSArray<NSNumber *> *winmux_native_window_spaces(uint32_t windowID) {
    return CFBridgingRelease(SLSCopySpacesForWindows(dinky_connection(), 0x7,
        (__bridge CFArrayRef)@[@(windowID)]));
}

bool winmux_native_is_content_window(uint32_t parentID, uint64_t tags) {
    return parentID != 0 || dinky_has_document_tags(tags);
}
