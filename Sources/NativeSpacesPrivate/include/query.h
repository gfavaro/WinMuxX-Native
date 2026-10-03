#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// SLSSpaceGetType values, as yabai reads them.
typedef NS_ENUM(int, DinkySpaceType) {
    DinkySpaceTypeUser = 0,
    DinkySpaceTypeSystem = 2,
    DinkySpaceTypeFullscreen = 4,
};

@interface DinkySpace : NSObject
@property (nonatomic) uint64_t spaceID;
@property (nonatomic, copy) NSString *uuid;
@property (nonatomic) DinkySpaceType type;
@property (nonatomic, readonly) BOOL isUser;
@property (nonatomic, readonly) BOOL isFullscreen;
@end

@interface DinkyDisplay : NSObject
@property (nonatomic, copy) NSString *uuid;          // real display UUID, never "Main"
@property (nonatomic) CGDirectDisplayID displayID;
@property (nonatomic, copy) NSArray<DinkySpace *> *spaces;  // Mission Control order
@property (nonatomic) uint64_t currentSpaceID;
@end

int dinky_connection(void);

// One entry per display, in SLSCopyManagedDisplaySpaces order.
NSArray<DinkyDisplay *> *dinky_displays(void);

// Each display's current Space, in SLSCopyManagedDisplaySpaces order. Cheaper than dinky_displays:
// no UUID conversion and no per-Space type lookups.
NSArray<NSNumber *> *dinky_current_space_ids(void);

uint64_t dinky_current_space_id(CFStringRef displayUUID);

// First Space of the window (SLSCopySpacesForWindows selector 0x7), 0 if none.
uint64_t dinky_window_space_id(uint32_t windowID);

// Window IDs on a Space, filtered like yabai space_window_list.
NSArray<NSNumber *> *dinky_space_window_ids(uint64_t spaceID, bool includeMinimized);

NS_ASSUME_NONNULL_END
