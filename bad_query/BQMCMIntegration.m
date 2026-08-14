//
//  BQMCMIntegration.m
//  bad_query
//
//  Slimmed port of FilzaSlop's MCMFilzaIntegration.m. Keeps the core MHA
//  primitives (identity check, lease cache, container-class routing, csstore
//  parsing) and drops Filza's virtual-root / symlink-farm / README / probe /
//  LiveContainer / Files-portal code, which BQTools does not use.
//

#import "BQMCMIntegration.h"
#import "MCMBridge.h"

#import <fcntl.h>
#import <limits.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const BQMCMRequiredIdentifier = @"com.apple.mobile.MobileHouseArrest";
const uint64_t BQMCMFlags = 0x900000000ULL;
const uint64_t BQMCMReadWritePartFlags = 0x8100000000ULL;

static NSMutableDictionary<NSString *, MCMLease *> *gLeases;
static dispatch_once_t gStateOnce;

// MARK: - SecTask (private) for signed-code-identifier

typedef CFTypeRef SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFStringRef SecTaskCopySigningIdentifier(SecTaskRef task, CFErrorRef *error);

static NSString *BQMCMSignedCodeIdentifier(void)
{
    static NSString *identifier;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (!task) return;
        CFErrorRef error = NULL;
        CFStringRef value = SecTaskCopySigningIdentifier(task, &error);
        if (value) identifier = [(__bridge NSString *)value copy];
        if (value) CFRelease(value);
        if (error) CFRelease(error);
        CFRelease(task);
    });
    return identifier;
}

BOOL BQMCMIsMobileHouseArrest(void)
{
    return [BQMCMSignedCodeIdentifier() isEqualToString:BQMCMRequiredIdentifier];
}

BOOL BQMCMBridgeAvailable(void) { return MCMBridgeAvailable(); }

BOOL BQMCMSafeIdentifier(NSString *identifier)
{
    if (identifier.length == 0 || identifier.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![identifier isEqualToString:@"."] && ![identifier isEqualToString:@".."];
}

// MARK: - Lease cache

static void BQMCMEnsureState(void)
{
    dispatch_once(&gStateOnce, ^{ gLeases = [NSMutableDictionary dictionary]; });
}

static NSString *BQMCMKey(uint64_t containerClass, NSString *identifier)
{
    return [NSString stringWithFormat:@"%llu:%@", containerClass, identifier];
}

static NSString *BQMCMScopedKey(uint64_t containerClass, NSString *identifier,
                                uint64_t part, NSString *partDomain, uint64_t flags)
{
    return [NSString stringWithFormat:@"%llu:%@:%llu:%@:%llx", containerClass,
        identifier, part, partDomain ?: @"", flags];
}

static BOOL BQMCMPathIsInsideRoot(NSString *path, NSString *root)
{
    NSString *(^normalized)(NSString *) = ^NSString *(NSString *value) {
        NSString *result = value.stringByStandardizingPath;
        if ([result isEqualToString:@"/var"] || [result hasPrefix:@"/var/"])
            result = [@"/private" stringByAppendingString:result];
        return result;
    };
    NSString *candidate = normalized(path);
    NSString *base = normalized(root);
    return [candidate isEqualToString:base] ||
        [candidate hasPrefix:[base stringByAppendingString:@"/"]];
}

// MARK: - Activate

NSString *BQMCMActivate(uint64_t containerClass, NSString *identifier,
                        BOOL group, NSString **error)
{
    BQMCMEnsureState();
    if (![BQMCMSignedCodeIdentifier() isEqualToString:BQMCMRequiredIdentifier]) {
        if (error) *error = @"signed code identifier is not the required MCM caller identity";
        return nil;
    }
    if (!BQMCMSafeIdentifier(identifier)) {
        if (error) *error = @"identifier contains unsupported path characters";
        return nil;
    }
    @synchronized (gLeases) {
        MCMLease *existing = gLeases[BQMCMKey(containerClass, identifier)];
        if (existing.rootPath.length) return existing.rootPath;
        NSString *detail = nil;
        MCMLease *lease = [MCMLease leaseForClass:containerClass identifier:identifier
            group:group part:0 flags:BQMCMFlags error:&detail];
        BOOL activated = lease && [lease activate:&detail];
        if (!lease) {
            if (error) *error = detail ?: @"MCM activation failed";
            return nil;
        }
        // iOS 26 containermanagerd lacks genericExtensionsAllowedForAll, so
        // it refuses sandbox tokens for callers not in the per-class allowed
        // set. The path is still valid — try opening it before giving up.
        int descriptor = open(lease.rootPath.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (descriptor < 0) {
            if (!activated) {
                if (error) *error = detail ?: @"MCM activation failed";
                [lease invalidate];
                return nil;
            }
            if (error) *error = [NSString stringWithFormat:@"container root open failed errno=%d", errno];
            [lease invalidate];
            return nil;
        }
        close(descriptor);
        gLeases[BQMCMKey(containerClass, identifier)] = lease;
        return lease.rootPath;
    }
}

NSString *BQMCMActivateScoped(uint64_t containerClass, NSString *identifier,
                              BOOL group, uint64_t part,
                              NSString *partDomain, uint64_t flags,
                              NSString **error)
{
    BQMCMEnsureState();
    if (![BQMCMSignedCodeIdentifier() isEqualToString:BQMCMRequiredIdentifier]) {
        if (error) *error = @"signed code identifier is not the required MCM caller identity";
        return nil;
    }
    if (!BQMCMSafeIdentifier(identifier)) {
        if (error) *error = @"identifier contains unsupported path characters";
        return nil;
    }
    NSString *key = BQMCMScopedKey(containerClass, identifier, part, partDomain, flags);
    @synchronized (gLeases) {
        MCMLease *existing = gLeases[key];
        if (existing.rootPath.length) return existing.rootPath;
        NSString *detail = nil;
        MCMLease *lease = [MCMLease leaseForClass:containerClass
            identifier:identifier group:group part:part partDomain:partDomain
            flags:flags error:&detail];
        BOOL activated = lease && [lease activate:&detail];
        if (!lease) {
            if (error) *error = detail ?: @"scoped MCM activation failed";
            return nil;
        }
        int descriptor = open(lease.rootPath.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (descriptor < 0) {
            if (!activated) {
                if (error) *error = detail ?: @"scoped MCM activation failed";
                [lease invalidate];
                return nil;
            }
            if (error) *error = [NSString stringWithFormat:
                @"scoped directory open failed errno=%d", errno];
            [lease invalidate];
            return nil;
        }
        close(descriptor);
        gLeases[key] = lease;
        return lease.rootPath;
    }
}

NSString *BQMCMDataContainerPath(NSString *identifier, NSString **error)
{
    return BQMCMActivate(2, identifier, NO, error);
}

// Query-only: return the class-2 container root path WITHOUT activating the
// sandbox token. On iOS 26, token activation frequently fails (containermanagerd
// lacks genericExtensionsAllowedForAll), but the path itself is still returned
// by the query. This function is used for app discovery where we only need the
// path to populate the list — the actual sandbox extension is activated later
// when the user navigates into a container (via ensureMHAExtension).
//
// Per SandboxEscape-Usage-Manual.md §7.3: validate csstore candidates by
// querying their class-2 container. This function does that without the
// activation overhead (1 XPC round-trip vs XPC + kernel token + open).
NSString *BQMCMDataContainerPathQuery(NSString *identifier, NSString **error)
{
    if (![BQMCMSignedCodeIdentifier() isEqualToString:BQMCMRequiredIdentifier]) {
        if (error) *error = @"signed code identifier is not the required MCM caller identity";
        return nil;
    }
    if (!BQMCMSafeIdentifier(identifier)) {
        if (error) *error = @"identifier contains unsupported path characters";
        return nil;
    }
    // Check lease cache first — if a lease was already activated (e.g. by a
    // prior BQMCMDataContainerPath call), reuse its rootPath.
    BQMCMEnsureState();
    @synchronized (gLeases) {
        MCMLease *existing = gLeases[BQMCMKey(2, identifier)];
        if (existing.rootPath.length) return existing.rootPath;
    }
    // Query the path without activating. leaseForClass does the XPC
    // round-trip to containermanagerd and stores rootPath.
    NSString *detail = nil;
    MCMLease *lease = [MCMLease leaseForClass:2 identifier:identifier
        group:NO part:0 flags:BQMCMFlags error:&detail];
    if (!lease) {
        if (error) *error = detail ?: @"MCM query returned no lease";
        return nil;
    }
    NSString *path = [lease.rootPath copy];
    // Don't cache or activate — just return the path. The lease is
    // invalidated so it doesn't hold kernel resources.
    [lease invalidate];
    if (!path.length) {
        if (error) *error = @"MCM query returned empty path";
        return nil;
    }
    return path;
}

// MARK: - Lease state queries

BOOL BQMCMPathHasActiveLease(NSString *path)
{
    if (path.length == 0 || !path.isAbsolutePath) return NO;
    BQMCMEnsureState();
    @synchronized (gLeases) {
        for (MCMLease *lease in gLeases.allValues)
            if (lease.activated && BQMCMPathIsInsideRoot(path, lease.rootPath)) return YES;
    }
    return NO;
}

void BQMCMReleaseAllLeases(void)
{
    BQMCMEnsureState();
    @synchronized (gLeases) {
        for (MCMLease *lease in gLeases.allValues) [lease invalidate];
        [gLeases removeAllObjects];
    }
}

NSUInteger BQMCMActiveLeaseCount(void)
{
    BQMCMEnsureState();
    @synchronized (gLeases) { return gLeases.count; }
}

// MARK: - Enumeration

NSArray<NSString *> *BQMCMEnumerateIdentifiersForClass(
    uint64_t containerClass, NSUInteger limit, NSString **error)
{
    return MCMEnumerateIdentifiersForClass(containerClass, limit, error);
}

// MARK: - iOS 26 csstore identifier discovery

static BOOL BQCMIdentifierByte(uint8_t value)
{
    return (value >= 'a' && value <= 'z') ||
        (value >= 'A' && value <= 'Z') ||
        (value >= '0' && value <= '9') ||
        value == '.' || value == '-' || value == '_';
}

NSArray<NSString *> *BQMCMLaunchServicesStoreIdentifiers(void)
{
    static const NSUInteger kMaximumCandidateCount = 65536;
    NSString *error = nil;
    NSString *container = BQMCMActivate(10, @"com.apple.lsd", NO, &error);
    if (!container.length) return @[];

    NSString *caches = [container stringByAppendingPathComponent:@"Library/Caches"];
    NSArray<NSString *> *names = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:caches error:nil];
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    BOOL reachedLimit = NO;
    for (NSString *name in names ?: @[]) {
        if (![name hasPrefix:@"com.apple.LaunchServices-"] ||
            ![name hasSuffix:@"-v2.csstore"])
            continue;
        NSString *path = [caches stringByAppendingPathComponent:name];
        NSNumber *size = [[NSFileManager.defaultManager attributesOfItemAtPath:path
            error:nil] objectForKey:NSFileSize];
        if (!size || size.unsignedLongLongValue == 0 ||
            size.unsignedLongLongValue > 64 * 1024 * 1024)
            continue;
        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfFile:path
            options:NSDataReadingMappedIfSafe error:&readError];
        if (!data) continue;
        const uint8_t *bytes = data.bytes;
        NSUInteger start = NSNotFound;
        for (NSUInteger index = 0; index <= data.length; index++) {
            BOOL allowed = index < data.length && BQCMIdentifierByte(bytes[index]);
            if (allowed) {
                if (start == NSNotFound) start = index;
                continue;
            }
            if (start == NSNotFound) continue;
            NSUInteger length = index - start;
            if (length >= 3 && length <= 255) {
                NSString *identifier = [[NSString alloc]
                    initWithBytes:bytes + start length:length
                    encoding:NSUTF8StringEncoding];
                BOOL malformedDots = [identifier containsString:@".."];
                BOOL looksLikeIdentifier = BQMCMSafeIdentifier(identifier) &&
                    [identifier containsString:@"."] &&
                    ![identifier hasPrefix:@"."] &&
                    ![identifier hasSuffix:@"."] && !malformedDots;
                if (looksLikeIdentifier) {
                    [result addObject:identifier];
                    if (result.count >= kMaximumCandidateCount) {
                        reachedLimit = YES;
                        break;
                    }
                }
            }
            start = NSNotFound;
        }
        if (reachedLimit) break;
    }
    return result.array;
}
