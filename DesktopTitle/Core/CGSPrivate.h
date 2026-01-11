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

// Get the ID of the currently active space
CG_EXTERN CGSSpaceID CGSGetActiveSpace(CGSConnectionID cid);

// Get the type of a space
CG_EXTERN CGSSpaceType CGSSpaceGetType(CGSConnectionID cid, CGSSpaceID space);

// Copy all managed display spaces (returns CFArrayRef of dictionaries)
CG_EXTERN CFArrayRef _Nullable CGSCopyManagedDisplaySpaces(CGSConnectionID cid) CF_RETURNS_RETAINED;

// Copy spaces for the given space mask
CG_EXTERN CFArrayRef _Nullable CGSCopySpaces(CGSConnectionID cid, CGSSpaceMask mask) CF_RETURNS_RETAINED;

// Get display UUID for a space
CG_EXTERN CFStringRef _Nullable CGSCopyManagedDisplayForSpace(CGSConnectionID cid, CGSSpaceID space) CF_RETURNS_RETAINED;

#endif /* CGSPrivate_h */
