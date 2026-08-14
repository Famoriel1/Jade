//
//  BQMCMIntegration.h
//  bad_query
//
//  High-level MHA (MobileHouseArrest) container access for BQTools.
//  Ported and slimmed from FilzaSlop's MCMFilzaIntegration: keeps the
//  identity check, lease cache, container-class routing, and iOS 26
//  csstore-based identifier discovery. Drops Filza's virtual root, README
//  generation, experimental probes, LiveContainer, and Files-portal code.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The signed-code-identifier MHA requires. The app's CodeDirectory identifier
/// must equal this string for containermanagerd to treat the caller as MHA.
FOUNDATION_EXPORT NSString *const BQMCMRequiredIdentifier;

/// True iff the process signed-code-identifier equals BQMCMRequiredIdentifier.
/// Computed once via SecTaskCopySigningIdentifier and cached.
FOUNDATION_EXPORT BOOL BQMCMIsMobileHouseArrest(void);

/// True iff all required containermanager symbols were dlsym'd.
FOUNDATION_EXPORT BOOL BQMCMBridgeAvailable(void);

/// Validate that an identifier contains only [a-zA-Z0-9.-_] and is not "."/"..".
/// Used to reject path-injection attempts before querying containermanagerd.
FOUNDATION_EXPORT BOOL BQMCMSafeIdentifier(NSString *identifier);

/// MHA flags for the standard container lookup (no part-domain traversal).
/// Matches FilzaSlop's kMCMFlags = 0x900000000.
FOUNDATION_EXPORT const uint64_t BQMCMFlags;

/// MHA flags for part-domain read-write traversal (class 13 part 3 etc.).
/// Matches FilzaSlop's kMCMReadWritePartFlags = 0x8100000000.
FOUNDATION_EXPORT const uint64_t BQMCMReadWritePartFlags;

/// Activate (or reuse the cached activation for) a container of the given
/// class and identifier. On success the sandbox extension for the returned
/// root path is active in this process and open()/readdir()/read() on it
/// (and descendants) will be permitted.
///
/// On iOS 26 the sandbox token may be refused, but the path can still be
/// returned; this function falls back to open(path, O_RDONLY|O_DIRECTORY)
/// in that case and succeeds if the directory is readable.
///
/// @param containerClass  See the container-class table (2=app data, 7=app
///                        group, 13=system group, etc.).
/// @param identifier      bundle ID (group=NO) or group ID (group=YES).
/// @param group           YES when identifier is a group ID.
/// @param error           Optional error description.
/// @return The container root path (absolute, /private/...-normalized),
///         or nil on failure.
FOUNDATION_EXPORT NSString *_Nullable BQMCMActivate(uint64_t containerClass,
                                                    NSString *identifier,
                                                    BOOL group,
                                                    NSString * _Nullable * _Nullable error);

/// Scoped variant of BQMCMActivate for part-domain traversal (e.g. class 13
/// part 3, or class 12 part 3 with a relative part-domain). Used by the
/// MobileGestalt cache and install-coordination probes.
FOUNDATION_EXPORT NSString *_Nullable BQMCMActivateScoped(
    uint64_t containerClass, NSString *identifier, BOOL group,
    uint64_t part, NSString * _Nullable partDomain, uint64_t flags,
    NSString * _Nullable * _Nullable error);

/// Convenience: BQMCMActivate(2, identifier, NO, error).
/// Returns the app-data container root for a bundle ID.
FOUNDATION_EXPORT NSString *_Nullable BQMCMDataContainerPath(
    NSString *identifier, NSString * _Nullable * _Nullable error);

/// Query-only variant: returns the class-2 container root path WITHOUT
/// activating the sandbox token. On iOS 26, token activation frequently fails
/// but the path is still returned by the query. Use this for app discovery
/// (where only the path is needed); use BQMCMDataContainerPath when the
/// sandbox extension must be active for immediate file access.
///
/// Per SandboxEscape-Usage-Manual.md §7.3: validate csstore candidates by
/// querying their class-2 container. This avoids the activation overhead
/// (1 XPC round-trip vs XPC + kernel token + open).
FOUNDATION_EXPORT NSString *_Nullable BQMCMDataContainerPathQuery(
    NSString *identifier, NSString * _Nullable * _Nullable error);

/// True iff `path` is inside a currently-active lease's root (or is the root).
/// Used to decide whether a file operation needs a fresh extension.
FOUNDATION_EXPORT BOOL BQMCMPathHasActiveLease(NSString *path);

/// Release every cached lease. Safe to call repeatedly.
FOUNDATION_EXPORT void BQMCMReleaseAllLeases(void);

/// Number of currently-cached leases (active or not).
FOUNDATION_EXPORT NSUInteger BQMCMActiveLeaseCount(void);

/// Enumerate registered identifiers under a container class. iOS 26 often
/// returns near-empty — see BQMCMLaunchServicesStoreIdentifiers.
FOUNDATION_EXPORT NSArray<NSString *> *BQMCMEnumerateIdentifiersForClass(
    uint64_t containerClass, NSUInteger limit,
    NSString * _Nullable * _Nullable error);

/// iOS 26 app-discovery fallback: activate com.apple.lsd's class-10 container,
/// mmap each com.apple.LaunchServices-*-v2.csstore in Library/Caches, and
/// extract candidate bundle IDs from the byte stream. Returns deduped,
/// MCMSafeIdentifier-filtered candidates (each contains at least one ".").
/// Caller should validate each candidate via BQMCMDataContainerPath().
FOUNDATION_EXPORT NSArray<NSString *> *BQMCMLaunchServicesStoreIdentifiers(void);

NS_ASSUME_NONNULL_END
