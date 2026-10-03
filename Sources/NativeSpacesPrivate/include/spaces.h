#pragma once
#import <Foundation/Foundation.h>

// Creates one user Space on the display through the bridged SLSBridgedSpaceCreateOperation.
// Returns the new Space ID, or 0 with the reason on stderr.
uint64_t dinky_create_space(CFStringRef displayUUID);

// Removes a Space through the bridged SLSBridgedSpaceDestroyOperation. Its windows go to the display's current
// Space. Asynchronous: returns once the request is sent; false with the reason on stderr if it could not be.
bool dinky_destroy_space(uint64_t spaceID);
