#include "BodyCodec.h"
#include <limits.h>
#include <string.h>
#include <zlib.h>

int proxylab_inflate(const uint8_t *input, size_t input_size,
                     uint8_t *output, size_t output_capacity,
                     size_t *output_size, int window_bits) {
    if (input_size > UINT_MAX || output_capacity > UINT_MAX) return 2;
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, window_bits) != Z_OK) return 2;
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_size;
    stream.next_out = output;
    stream.avail_out = (uInt)output_capacity;
    int result = inflate(&stream, Z_FINISH);
    *output_size = stream.total_out;
    int status = result == Z_STREAM_END ? 0 : (stream.avail_out == 0 ? 1 : 2);
    inflateEnd(&stream);
    return status;
}
