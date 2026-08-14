//
//  MCMBridge.h
//  bad_query
//
//  Low-level bridge to libsystem_containermanager.dylib.
//  Ported from FilzaSlop (MCMBridge.h) — dlopen + dlsym of the private
//  container_query_* / container_object_* symbols, plus the MCMLease class
//  that wraps a single query → activate lifecycle.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps one container query and (optionally) its activated sandbox extension.
/// The query is created by `leaseForClass:...` and activated by `activate:`.
/// Call `invalidate` (or let dealloc fire it) to release the kernel object.
@interface MCMLease : NSObject

@property(nonatomic, readonly) uint64_t containerClass;
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *rootPath;
@property(nonatomic, readonly) BOOL groupIdentifier;
@property(nonatomic, readonly) BOOL tokenPresent;
@property(nonatomic, readonly) BOOL activated;

+ (nullable instancetype)leaseForClass:(uint64_t)containerClass
                             identifier:(NSString *)identifier
                                  group:(BOOL)group
                                   part:(uint64_t)part
                                  flags:(uint64_t)flags
                                  error:(NSString * _Nullable * _Nullable)error;

+ (nullable instancetype)leaseForClass:(uint64_t)containerClass
                             identifier:(NSString *)identifier
                                  group:(BOOL)group
                                   part:(uint64_t)part
                             partDomain:(nullable NSString *)partDomain
                                  flags:(uint64_t)flags
                                  error:(NSString * _Nullable * _Nullable)error;

- (BOOL)activate:(NSString * _Nullable * _Nullable)error;
- (void)invalidate;

@end

/// True when every required containermanager symbol was dlsym'd successfully.
FOUNDATION_EXPORT BOOL MCMBridgeAvailable(void);

/// Enumerate the identifiers registered under a container class. Returns an
/// empty array (and sets *error) on denial or when the iterate API is absent.
/// iOS 26 often returns near-empty results — see BQMCMLaunchServicesStoreIdentifiers.
FOUNDATION_EXPORT NSArray<NSString *> *MCMEnumerateIdentifiersForClass(
    uint64_t containerClass, NSUInteger limit,
    NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
