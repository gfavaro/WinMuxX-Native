// Adapted from mikker/Dinky e05ae28f3e814bbae1cf171567be14e0dcba6548.
// See legal/native-spaces for MIT licenses and upstream attributions.
#import "query.h"
#import "skylight.h"

@implementation DinkySpace
- (BOOL)isUser { return self.type == DinkySpaceTypeUser; }
- (BOOL)isFullscreen { return self.type == DinkySpaceTypeFullscreen; }
@end

@implementation DinkyDisplay
@end

int dinky_connection(void)
{
    static int cid = 0;
    if (!cid) cid = SLSMainConnectionID();
    return cid;
}

static uint64_t number_u64(CFNumberRef n)
{
    uint64_t v = 0;
    if (n) CFNumberGetValue(n, kCFNumberSInt64Type, &v);
    return v;
}

// "Main" is what SLSCopyManagedDisplaySpaces reports when displays do not have separate Spaces.
static NSString *real_uuid(NSString *identifier, CGDirectDisplayID *outID)
{
    if ([identifier isEqualToString:@"Main"]) {
        *outID = CGMainDisplayID();
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(*outID);
        NSString *s = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
        CFRelease(uuid);
        return s;
    }
    CFUUIDRef uuid = CFUUIDCreateFromString(NULL, (__bridge CFStringRef)identifier);
    *outID = uuid ? CGDisplayGetDisplayIDFromUUID(uuid) : 0;
    if (uuid) CFRelease(uuid);
    return identifier;
}

NSArray<DinkyDisplay *> *dinky_displays(void)
{
    int cid = dinky_connection();
    NSMutableArray *result = [NSMutableArray array];
    NSArray *managed = CFBridgingRelease(SLSCopyManagedDisplaySpaces(cid));

    for (NSDictionary *entry in managed) {
        NSString *identifier = entry[@"Display Identifier"];
        DinkyDisplay *display = [DinkyDisplay new];
        CGDirectDisplayID did = 0;
        display.uuid = real_uuid(identifier, &did);
        display.displayID = did;
        display.currentSpaceID = SLSManagedDisplayGetCurrentSpace(cid, (__bridge CFStringRef)identifier);

        NSMutableArray *spaces = [NSMutableArray array];
        for (NSDictionary *spaceDict in entry[@"Spaces"]) {
            DinkySpace *space = [DinkySpace new];
            space.uuid = [spaceDict[@"uuid"] isKindOfClass:NSString.class] ? spaceDict[@"uuid"] : @"";
            space.spaceID = number_u64((__bridge CFNumberRef)spaceDict[@"id64"]);
            space.type = SLSSpaceGetType(cid, space.spaceID);
            [spaces addObject:space];
        }
        display.spaces = spaces;
        [result addObject:display];
    }
    return result;
}

NSArray<NSNumber *> *dinky_current_space_ids(void)
{
    int cid = dinky_connection();
    NSMutableArray *result = [NSMutableArray array];
    NSArray *managed = CFBridgingRelease(SLSCopyManagedDisplaySpaces(cid));
    for (NSDictionary *entry in managed) {
        CFStringRef identifier = (__bridge CFStringRef)entry[@"Display Identifier"];
        [result addObject:@(SLSManagedDisplayGetCurrentSpace(cid, identifier))];
    }
    return result;
}

uint64_t dinky_current_space_id(CFStringRef displayUUID)
{
    return SLSManagedDisplayGetCurrentSpace(dinky_connection(), displayUUID);
}

uint64_t dinky_window_space_id(uint32_t windowID)
{
    NSArray *windows = @[@(windowID)];
    NSArray *spaces = CFBridgingRelease(SLSCopySpacesForWindows(dinky_connection(), 0x7, (__bridge CFArrayRef)windows));
    return spaces.count ? number_u64((__bridge CFNumberRef)spaces[0]) : 0;
}

// yabai space_window_list_for_connection with owner 0. yabai also keeps any window its
// window manager already tracks; we have no such table, so only the tag filter applies.
NSArray<NSNumber *> *dinky_space_window_ids(uint64_t spaceID, bool includeMinimized)
{
    int cid = dinky_connection();
    uint64_t set_tags = 0;
    uint64_t clear_tags = 0;
    uint32_t options = includeMinimized ? 0x7 : 0x2;

    NSArray *spaces = @[@(spaceID)];
    CFArrayRef windows = SLSCopyWindowsWithOptionsAndTags(cid, 0, (__bridge CFArrayRef)spaces, options, &set_tags, &clear_tags);
    if (!windows) return @[];

    NSMutableArray *result = [NSMutableArray array];
    int count = (int)CFArrayGetCount(windows);
    if (count) {
        CFTypeRef query = SLSWindowQueryWindows(cid, windows, count);
        CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);

        while (SLSWindowIteratorAdvance(iterator)) {
            uint64_t tags = SLSWindowIteratorGetTags(iterator);
            uint64_t attributes = SLSWindowIteratorGetAttributes(iterator);
            uint32_t parent = SLSWindowIteratorGetParentID(iterator);
            uint32_t wid = SLSWindowIteratorGetWindowID(iterator);
            int level = SLSWindowIteratorGetLevel(iterator);

            if (parent != 0) continue;
            if (!(level == 0 || level == 3 || level == 8)) continue;

            bool shown = dinky_is_visible(attributes, tags) || (includeMinimized && dinky_is_minimized(attributes, tags));
            if (shown && dinky_has_document_tags(tags)) [result addObject:@(wid)];
        }

        CFRelease(query);
        CFRelease(iterator);
    }
    CFRelease(windows);
    return result;
}
