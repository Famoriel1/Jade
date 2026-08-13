//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "bad_query.h"

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
