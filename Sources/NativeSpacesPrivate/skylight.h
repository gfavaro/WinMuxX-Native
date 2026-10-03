// Private SkyLight / CGS declarations and helpers shared by the .m files in DinkyPrivate.
// Signatures copied from yabai src/misc/extern.h.
#pragma once
#include <ApplicationServices/ApplicationServices.h>

extern int SLSMainConnectionID(void);
extern CFArrayRef SLSCopyManagedDisplaySpaces(int cid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef uuid);
extern int SLSSpaceGetType(int cid, uint64_t sid);
extern CFArrayRef SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list);
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner, CFArrayRef spaces, uint32_t options, uint64_t *set_tags, uint64_t *clear_tags);

extern CFTypeRef SLSWindowQueryWindows(int cid, CFArrayRef windows, int count);
extern CFTypeRef SLSWindowQueryResultCopyWindows(CFTypeRef window_query);
extern int SLSWindowIteratorGetCount(CFTypeRef iterator);
extern bool SLSWindowIteratorAdvance(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetParentID(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetWindowID(CFTypeRef iterator);
extern uint64_t SLSWindowIteratorGetTags(CFTypeRef iterator);
extern uint64_t SLSWindowIteratorGetAttributes(CFTypeRef iterator);
extern int SLSWindowIteratorGetLevel(CFTypeRef iterator);

// Moves dinky's own border windows only. PLAN.md: never a fallback for the bridged move of other apps' windows.
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list, uint64_t sid);

extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int *wcid);
extern CGError SLSConnectionGetPID(int cid, pid_t *pid);
extern CGError SLSGetConnectionIDForPSN(int cid, ProcessSerialNumber *psn, int *psnCID);
extern OSStatus _SLPSGetFrontProcess(ProcessSerialNumber *psn);

// The bridged window management dispatchers are non-exported C++ statics in SkyLight. They cannot be
// linked or dlsym'd; this finds one by walking SkyLight's Mach-O symbol table (yabai macho_find_symbol,
// mimi mimi_macho_find_symbol). NULL if the symbol is missing.
void *dinky_skylight_symbol(const char *mangledName);

// The front app's connection (front PSN -> connection, JankyBorders get_front_window), 0 if unknown.
int dinky_front_connection(void);

// Window tag and attribute tests, as yabai space_window_list and JankyBorders window_suitable read them.
static inline bool dinky_is_visible(uint64_t attributes, uint64_t tags)
{
    return (attributes & 0x2) || (tags & 0x400000000000000);
}

// A real document or modal window.
static inline bool dinky_has_document_tags(uint64_t tags)
{
    return (tags & (1ULL << 0)) || ((tags & (1ULL << 1)) && (tags & (1ULL << 31)));
}

// A top-level document window, whether shown or not. JankyBorders misc/window.h window_suitable:
// no parent, document tags, not attached (bit 7), not ignoring the cycle (bit 18).
static inline bool dinky_is_document_kind(uint32_t parentID, uint64_t tags)
{
    bool attached = tags & (1ULL << 7);
    bool ignoresCycle = tags & (1ULL << 18);
    return parentID == 0 && dinky_has_document_tags(tags) && !attached && !ignoresCycle;
}

// Minimized windows carry these instead of the visible ones.
static inline bool dinky_is_minimized(uint64_t attributes, uint64_t tags)
{
    return (attributes == 0x0 || attributes == 0x1) && ((tags & 0x1000000000000000) || (tags & 0x300000000000000));
}
