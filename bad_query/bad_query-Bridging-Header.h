//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "bad_query.h"
#import "MCMBridge.h"
#import "BQMCMIntegration.h"
#import <Foundation/Foundation.h>
#include <zlib.h>
#include <stdlib.h>


// Raw DEFLATE decompression using libz (windowBits = -15).
// libcompression only has COMPRESSION_ZLIB which requires a full zlib
// stream (header + Adler-32 checksum). ZIP files store raw DEFLATE
// (RFC 1951) without the zlib wrapper, so we must use libz directly.
//
// Returns a malloc'd buffer (caller must free) or NULL on failure.
// Sets *out_size to the decompressed size.
static inline unsigned char *bq_inflate_raw(const unsigned char *src, size_t src_len,
                                             size_t expected_size, size_t *out_size) {
    z_stream stream;
    stream.zalloc = Z_NULL;
    stream.zfree = Z_NULL;
    stream.opaque = Z_NULL;
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_len;

    // windowBits = -15: raw deflate, no zlib header, no Adler-32
    if (inflateInit2(&stream, -15) != Z_OK) {
        *out_size = 0;
        return NULL;
    }

    size_t capacity = expected_size > 0 ? expected_size : src_len * 20;
    if (capacity < 65536) capacity = 65536;

    unsigned char *output = (unsigned char *)malloc(capacity);
    if (!output) {
        inflateEnd(&stream);
        *out_size = 0;
        return NULL;
    }

    stream.next_out = output;
    stream.avail_out = (uInt)capacity;

    int ret;
    size_t total_out = 0;

    do {
        ret = inflate(&stream, Z_NO_FLUSH);
        total_out = capacity - stream.avail_out;

        if (ret == Z_STREAM_END) break;

        if (ret != Z_OK) {
            if (total_out == 0) {
                free(output);
                inflateEnd(&stream);
                *out_size = 0;
                return NULL;
            }
            break;
        }

        // Output buffer full — grow it
        if (stream.avail_out == 0) {
            size_t new_cap = capacity * 2;
            unsigned char *new_out = (unsigned char *)realloc(output, new_cap);
            if (!new_out) {
                free(output);
                inflateEnd(&stream);
                *out_size = 0;
                return NULL;
            }
            output = new_out;
            stream.next_out = output + total_out;
            stream.avail_out = (uInt)(new_cap - total_out);
            capacity = new_cap;
        }
    } while (stream.avail_in > 0);

    inflateEnd(&stream);
    *out_size = total_out;
    return output;
}

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import <CoreGraphics/CoreGraphics.h>
@class _LSLazyPropertyList, _LSBundleIDValidationToken, _LSApplicationState, _LSDiskUsage, LSBundleProxy, LSApplicationProxy, LSInstallProgressList;
#import "CoreServices/_LSQueryResult.h"
#import "CoreServices/LSResourceProxy.h"
#import "CoreServices/LSBundleProxy.h"
#import "CoreServices/LSApplicationProxy.h"
#import "CoreServices/LSInstallProgressList.h"
#import "CoreServices/LSApplicationWorkspace.h"

// 通过 bundleId 获取 App 显示名称
// 优先级：LSApplicationProxy.localizedName > Info.plist(CFBundleDisplayName/CFBundleName) > nil
// 文件系统回退扫描 /var/containers/Bundle/Application (UUID/.app 两层)
// 和 /Applications (扁平结构)，匹配 Info.plist 的 CFBundleIdentifier。
// MHA 身份下可直接访问；沙盒下由 id2name.swift 的 bad_query 回退兜底。
static NSString *AppNameForBundleID(NSString *bundleId) {
    if (!bundleId.length) return nil;

    // 1. LaunchServices 私有 API 优先（最快、覆盖系统应用）
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if ([proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        id proxy = ((id (*)(id, SEL, NSString *))objc_msgSend)(
            proxyClass, NSSelectorFromString(@"applicationProxyForIdentifier:"), bundleId);
        if (proxy && [proxy respondsToSelector:@selector(localizedName)]) {
            NSString *name = ((NSString *(*)(id, SEL))objc_msgSend)(
                proxy, NSSelectorFromString(@"localizedName"));
            if (name.length) return name;
        }
    }

    // 2. 文件系统回退：扫 /var/containers/Bundle/Application (UUID/.app 两层)
    //    和 /Applications (扁平结构)，匹配 Info.plist 的 CFBundleIdentifier
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *roots = @[
        @"/var/containers/Bundle/Application",
        @"/Applications"
    ];
    for (NSString *root in roots) {
        BOOL nested = [root hasPrefix:@"/var/containers"];
        for (NSString *a in [fm contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
            NSString *dir = nested ? [root stringByAppendingPathComponent:a] : root;
            for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
                if (![item hasSuffix:@".app"]) continue;
                NSString *plist = [[dir stringByAppendingPathComponent:item]
                    stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
                if ([info[@"CFBundleIdentifier"] isEqualToString:bundleId]) {
                    NSString *name = info[@"CFBundleDisplayName"]
                        ?: info[@"CFBundleName"];
                    return name.length ? name : nil;
                }
            }
        }
    }

    // 3. 最终回退（返回 nil，由 Swift 层决定显示 bundleId 或其他）
    return nil;
}

// MARK: - App discovery (MHA-native)
//
// App discovery under MHA identity does NOT scan /var/containers/Bundle/Application
// — per SandboxEscape-Usage-Manual.md §10.2, MCM does not issue sandbox extensions
// for bundle directories. Instead, discovery uses:
//   1. BQMCMLaunchServicesStoreIdentifiers() — csstore parsing (iOS 26 primary)
//   2. BQMCMEnumerateIdentifiersForClass(2) — direct MCM enumeration (supplement)
//   3. bad_query inode scan on /var/mobile/Containers/Data/Application (fallback)
//
// Each candidate bundle ID is validated via BQMCMDataContainerPathQuery() (path
// only, no token activation — avoids iOS 26 activation failures). The actual
// sandbox extension is activated on-demand when the user navigates into a
// container (via ensureMHAExtension in BQFileSystem.swift).
