// Adapted from mikker/Dinky e05ae28f3e814bbae1cf171567be14e0dcba6548.
// See legal/native-spaces for MIT licenses and upstream attributions.
#import "NativeSpacesPrivate.h"
#import "query.h"

#import <AppKit/AppKit.h>
#import <mach/mach_time.h>

// Switches Spaces with mimi's augmented Dock swipe (mimi internal/native/space.m + dockswipe.m).
// RESULTS.md records the other paths the spike tried and why this one won.

// Private CGEvent field numbers for a synthetic Dock swipe.
static const int kEventTypeField = 55;             // kCGSEventTypeField
static const int kEventDockControl = 30;           // kCGSEventDockControl
static const int kGestureHIDType = 110;            // kCGEventGestureHIDType
static const int kHIDEventTypeDockSwipe = 23;      // kIOHIDEventTypeDockSwipe
static const int kGestureSwipeMask = 115;          // kCGEventGestureSwipeMask
static const int kGestureSwipeMotion = 123;        // kCGEventGestureSwipeMotion
static const int kGestureMotionHorizontal = 1;     // kCGGestureMotionHorizontal
static const int kGestureSwipeProgress = 124;      // kCGEventGestureSwipeProgress
static const int kGestureSwipePositionX = 125;     // kCGEventGestureSwipePositionX
static const int kGestureSwipePositionY = 126;     // kCGEventGestureSwipePositionY
static const int kGestureSwipeVelocityX = 129;     // kCGEventGestureSwipeVelocityX
static const int kGestureSwipeVelocityY = 130;     // kCGEventGestureSwipeVelocityY
static const int kGesturePhase = 132;              // kCGEventGesturePhase
static const int kGesturePhaseAlias = 134;         // kCGEventGesturePhaseAlias
static const int kGestureZoomDeltaY = 138;         // kCGEventGestureZoomDeltaY
static const int kSourceUnixProcessIDAlias = 169;  // kCGEventSourceUnixProcessIDAlias
static const int kPhaseBegan = 1;
static const int kPhaseChanged = 2;
static const int kPhaseEnded = 4;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// IOHID queue layout the Dock reads out of a synthetic dock swipe on macOS 27+. From mimi dockswipe.m.
#pragma pack(push, 1)
typedef struct {
    uint32_t size;
    uint32_t type;
    uint32_t options;
    uint8_t depth;
    uint8_t reserved[3];
} IOHIDEventBase;

typedef struct {
    IOHIDEventBase base;
    int32_t positionX;
    int32_t positionY;
    int32_t positionZ;
    uint32_t swipeMask;
    uint16_t gestureMotion;
    uint16_t gestureFlavor;
    int32_t swipeProgress;
} IOHIDFluidTouchGestureData;

typedef struct {
    IOHIDEventBase base;
    int32_t velocityX;
    int32_t velocityY;
    int32_t velocityZ;
} IOHIDVelocityEventData;

typedef struct {
    uint64_t timestamp;
    uint64_t senderID;
    uint32_t options;
    uint32_t attributeLength;
    uint32_t eventCount;
} IOHIDSystemQueueElementHeader;
#pragma pack(pop)

_Static_assert(sizeof(IOHIDEventBase) == 16, "unexpected IOHID event base layout");
_Static_assert(sizeof(IOHIDFluidTouchGestureData) == 40, "unexpected IOHID fluid gesture layout");
_Static_assert(sizeof(IOHIDVelocityEventData) == 28, "unexpected IOHID velocity layout");
_Static_assert(sizeof(IOHIDSystemQueueElementHeader) == 28, "unexpected IOHID queue header layout");

static const uint32_t kIOHIDEventTypeVelocity = 9;
static const uint32_t kIOHIDEventTypeFluidTouchGesture = 23;
static const uint16_t kIOHIDGestureFlavorDockPrimary = 3;
static const uint16_t kRawIOHIDPayloadField = 4205;
static const uint8_t kEventDataFormatVersion = 2;

static const double kMimiZoomDeltaY = 3.0;          // empirically required
static const double kMimiPositionX = 0.1;           // empirically required
static const double kMimiVelocity = 9999.0;         // high enough to skip the animation

static int32_t fixed_1616(double value)
{
    int32_t fixed = (int32_t)(value * 65536.0);
    if (fixed == 0 && value != 0.0) return value > 0.0 ? 1 : -1;
    return fixed;
}

static uint8_t *build_iohid_payload(CGEventRef event, size_t *outLength)
{
    int64_t phase = CGEventGetIntegerValueField(event, kGesturePhase);
    int64_t motion = CGEventGetIntegerValueField(event, kGestureSwipeMotion);
    int64_t swipeMask = CGEventGetIntegerValueField(event, kGestureSwipeMask);
    double progress = CGEventGetDoubleValueField(event, kGestureSwipeProgress);
    double posX = CGEventGetDoubleValueField(event, kGestureSwipePositionX);
    double posY = CGEventGetDoubleValueField(event, kGestureSwipePositionY);
    double velX = CGEventGetDoubleValueField(event, kGestureSwipeVelocityX);
    double velY = CGEventGetDoubleValueField(event, kGestureSwipeVelocityY);

    // A real trackpad only reports velocity once the fingers lift.
    bool includeVelocity = (velX != 0.0 || velY != 0.0 || phase == kPhaseEnded);

    size_t length = sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData);
    if (includeVelocity) length += sizeof(IOHIDVelocityEventData);

    uint8_t *payload = calloc(1, length);
    if (!payload) return NULL;

    IOHIDSystemQueueElementHeader *header = (IOHIDSystemQueueElementHeader *)payload;
    uint64_t timestamp = CGEventGetTimestamp(event);
    header->timestamp = timestamp != 0 ? timestamp : mach_absolute_time();
    header->eventCount = includeVelocity ? 2 : 1;

    IOHIDFluidTouchGestureData *fluid = (IOHIDFluidTouchGestureData *)(payload + sizeof(IOHIDSystemQueueElementHeader));
    fluid->base.size = sizeof(IOHIDFluidTouchGestureData);
    fluid->base.type = kIOHIDEventTypeFluidTouchGesture;
    fluid->base.options = (uint32_t)((phase & 0xFF) << 24);
    fluid->positionX = fixed_1616(posX);
    fluid->positionY = fixed_1616(posY);
    fluid->swipeMask = (uint32_t)swipeMask;
    fluid->gestureMotion = (uint16_t)motion;
    fluid->gestureFlavor = kIOHIDGestureFlavorDockPrimary;
    fluid->swipeProgress = fixed_1616(progress);

    if (includeVelocity) {
        IOHIDVelocityEventData *velocity = (IOHIDVelocityEventData *)(payload + sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData));
        velocity->base.size = sizeof(IOHIDVelocityEventData);
        velocity->base.type = kIOHIDEventTypeVelocity;
        velocity->base.depth = 1;
        velocity->velocityX = fixed_1616(velX);
        velocity->velocityY = fixed_1616(velY);
    }

    *outLength = length;
    return payload;
}

// mimi MimiDockSwipeAugment: serialize the event, append the IOHID payload as a trailing field, rebuild.
static CGEventRef dock_swipe_augment(CGEventRef event)
{
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) {
        fputs("switch: could not serialize dock swipe event\n", stderr);
        return NULL;
    }

    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);
    if (length < 4 || bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 0 || bytes[3] != kEventDataFormatVersion) {
        fprintf(stderr, "switch: unexpected event data format (length=%ld)\n", (long)length);
        CFRelease(data);
        return NULL;
    }

    size_t payloadLength = 0;
    uint8_t *payload = build_iohid_payload(event, &payloadLength);
    if (!payload) {
        CFRelease(data);
        return NULL;
    }

    // Serialized event, then big-endian payload length and field ID, then the payload.
    size_t newLength = (size_t)length + 4 + payloadLength;
    uint8_t *newBytes = malloc(newLength);
    if (!newBytes) {
        free(payload);
        CFRelease(data);
        return NULL;
    }
    memcpy(newBytes, bytes, (size_t)length);
    newBytes[length] = (uint8_t)((payloadLength >> 8) & 0xFF);
    newBytes[length + 1] = (uint8_t)(payloadLength & 0xFF);
    newBytes[length + 2] = (uint8_t)((kRawIOHIDPayloadField >> 8) & 0xFF);
    newBytes[length + 3] = (uint8_t)(kRawIOHIDPayloadField & 0xFF);
    memcpy(newBytes + length + 4, payload, payloadLength);
    free(payload);
    CFRelease(data);

    CFDataRef newData = CFDataCreate(kCFAllocatorDefault, newBytes, (CFIndex)newLength);
    free(newBytes);
    if (!newData) return NULL;

    CGEventRef augmented = CGEventCreateFromData(kCFAllocatorDefault, newData);
    CFRelease(newData);
    if (!augmented) fputs("switch: could not rebuild dock swipe event from data\n", stderr);
    return augmented;
}

// mimi mimiCreateAugmentedDockSwipeEvent. sign is +1 toward higher Space indices.
static CGEventRef mimi_create_event(int phase, double sign)
{
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return NULL;

    CGEventSetIntegerValueField(event, kEventTypeField, kEventDockControl);
    CGEventSetIntegerValueField(event, kGestureHIDType, kHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(event, kGestureSwipeMotion, kGestureMotionHorizontal);
    CGEventSetIntegerValueField(event, kGesturePhase, phase);
    CGEventSetIntegerValueField(event, kGesturePhaseAlias, phase);

    // The payload uses the raw HID sign convention, opposite to the Space-index direction.
    CGEventSetDoubleValueField(event, kGestureSwipeProgress, -sign);
    CGEventSetDoubleValueField(event, kGestureSwipePositionX, kMimiPositionX);
    CGEventSetDoubleValueField(event, kGestureZoomDeltaY, kMimiZoomDeltaY);
    CGEventSetDoubleValueField(event, kSourceUnixProcessIDAlias, (double)mach_absolute_time());

    if (phase == kPhaseEnded) {
        CGEventSetDoubleValueField(event, kGestureSwipeVelocityX, -sign * kMimiVelocity);
    }

    CGEventRef augmented = dock_swipe_augment(event);
    CFRelease(event);
    return augmented;
}

// mimi mimiPostAugmentedDockSwipe.
static bool mimi_post_swipe(double sign)
{
    static const int phases[] = {kPhaseBegan, kPhaseChanged, kPhaseEnded};
    for (size_t i = 0; i < sizeof(phases) / sizeof(phases[0]); i++) {
        CGEventRef event = mimi_create_event(phases[i], sign);
        if (!event) {
            fprintf(stderr, "switch: failed to build augmented dock swipe event (phase=%d)\n", phases[i]);
            return false;
        }
        CGEventPost(kCGSessionEventTap, event);
        CFRelease(event);
    }
    return true;
}


bool winmux_native_post_swipe(bool forward) { return mimi_post_swipe(forward ? 1.0 : -1.0); }

#pragma clang diagnostic pop
