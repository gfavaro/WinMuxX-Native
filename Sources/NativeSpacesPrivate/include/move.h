#pragma once
#import <Foundation/Foundation.h>

// Bridged operation only. False if the dispatcher could not be resolved or the operation could not be created.
bool dinky_move_windows_to_space(const uint32_t *windowIDs, int count, uint64_t spaceID);
