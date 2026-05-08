//
//  CGSPrivate.h
//  DesktopTitle
//
//  Private CoreGraphics API declarations for Space management
//  Based on: https://github.com/shabble/osx-space-id
//

#ifndef CGSPrivate_h
#define CGSPrivate_h

#include <CoreGraphics/CoreGraphics.h>

typedef int CGSConnectionID;
typedef uint64_t CGSSpaceID;
typedef int CGSSpaceType;

// Space type constants
static const CGSSpaceType kCGSSpaceUser = 0;
static const CGSSpaceType kCGSSpaceFullscreen = 1;
static const CGSSpaceType kCGSSpaceSystem = 2;

// Space selector masks
typedef enum {
    kCGSSpaceIncludesCurrent = 1 << 0,
    kCGSSpaceIncludesOthers = 1 << 1,
    kCGSSpaceIncludesUser = 1 << 2,
    kCGSAllSpacesMask = kCGSSpaceIncludesCurrent | kCGSSpaceIncludesOthers | kCGSSpaceIncludesUser
} CGSSpaceMask;

// Get the default connection to the window server
CG_EXTERN CGSConnectionID _CGSDefaultConnection(void);

// Get the main connection to the window server
CG_EXTERN CGSConnectionID CGSMainConnectionID(void);

// Get the ID of the currently active space
CG_EXTERN CGSSpaceID CGSGetActiveSpace(CGSConnectionID cid);

// Get the type of a space
CG_EXTERN CGSSpaceType CGSSpaceGetType(CGSConnectionID cid, CGSSpaceID space);

// Copy all managed display spaces (returns CFArrayRef of dictionaries)
CG_EXTERN CFArrayRef _Nullable CGSCopyManagedDisplaySpaces(CGSConnectionID cid) CF_RETURNS_RETAINED;

// Copy spaces for the given space mask
CG_EXTERN CFArrayRef _Nullable CGSCopySpaces(CGSConnectionID cid, CGSSpaceMask mask) CF_RETURNS_RETAINED;

// Copy spaces containing the given windows
CG_EXTERN CFArrayRef _Nullable CGSCopySpacesForWindows(CGSConnectionID cid, CGSSpaceMask mask, CFArrayRef _Nonnull windows) CF_RETURNS_RETAINED;

// Assign windows to Spaces
CG_EXTERN void CGSAddWindowsToSpaces(CGSConnectionID cid, CFArrayRef _Nonnull windows, CFArrayRef _Nonnull spaces);

// Remove windows from Spaces
CG_EXTERN void CGSRemoveWindowsFromSpaces(CGSConnectionID cid, CFArrayRef _Nonnull windows, CFArrayRef _Nonnull spaces);

// Get display UUID for a space
CG_EXTERN CFStringRef _Nullable CGSCopyManagedDisplayForSpace(CGSConnectionID cid, CGSSpaceID space) CF_RETURNS_RETAINED;

// Register / unregister a callback for SkyLight (CGS) notifications.
// `type` is one of the private CGSEvent* constants — there is no public
// header for these, so callers register a range and log what fires.
typedef void (*CGSNotifyProcPtr)(uint32_t type, void * _Nullable data, size_t length, void * _Nullable userInfo);
CG_EXTERN CGError CGSRegisterNotifyProc(CGSNotifyProcPtr _Nonnull proc, uint32_t type, void * _Nullable userInfo);
CG_EXTERN CGError CGSRemoveNotifyProc(CGSNotifyProcPtr _Nonnull proc, uint32_t type, void * _Nullable userInfo);

// Reorder a window in its Space's z-stack without forcing a Space switch.
// `place` follows kCGSOrder* constants: 0 below, 1 above. `relative` is
// the windowID we order relative to, or 0 for "the entire stack".
CG_EXTERN CGError CGSOrderWindow(CGSConnectionID cid, int windowID, int place, int relative);

#endif /* CGSPrivate_h */
