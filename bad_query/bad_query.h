//
//  bad_query.h
//  bad_query
//
//  Created by Taj C on 7/21/26.
//

#ifndef bad_query_h
#define bad_query_h

#include <stdio.h>
#include <stdbool.h>

int64_t bad_query(char* path, bool create, char *group_identifier, bool is_group);
char *bad_query_list(char *path, int64_t max_inode);
char *bad_query_list_range(char *path, int64_t start_inode, int64_t end_inode);
void bad_query_release(int64_t handle);

// MHA route: resolve an app's data container by bundle ID (class 2), activate
// the sandbox extension, and keep it alive. Returns the container object
// pointer (>0) on success and copies the container root path to out_path.
// Release with bad_query_mha_release(). Returns negative on failure.
int64_t bad_query_mha(const char *bundle_id, char *out_path, size_t path_size);
void bad_query_mha_release(int64_t object_handle);

// MARK: - Sandbox Escape PoC

typedef struct {
    int success;        // 0 = success, non-zero = failure
    int activated;      // sandbox extension was activated
    int denied_before;  // target inaccessible before activation
    int denied_after;   // target inaccessible after revocation
    int restored;       // MHA: original canary data restored
    int writable;       // MG13: plist was writable after activation
    char message[512];  // human-readable result line
    char path[1024];    // relevant file path
} bq_poc_result;

bq_poc_result bq_run_mha_poc(const char *victim_bundle_id);
bq_poc_result bq_run_mg_class13_poc(void);

#endif /* bad_query_h */
