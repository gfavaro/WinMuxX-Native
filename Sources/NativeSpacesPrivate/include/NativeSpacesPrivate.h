#pragma once
#import "query.h"
#import "spaces.h"
#import "move.h"
// Posting is separate from asynchronous delay and observed arrival in Swift.
bool winmux_native_post_swipe(bool forward);
bool winmux_native_capabilities(void);
NSNumber * _Nullable winmux_native_window_owner_pid(uint32_t windowID);
bool winmux_native_is_content_window(uint32_t parentID, uint64_t tags);
NSArray<NSNumber *> * _Nullable winmux_native_all_space_windows(uint64_t spaceID);
NSArray<NSNumber *> * _Nullable winmux_native_window_spaces(uint32_t windowID);
