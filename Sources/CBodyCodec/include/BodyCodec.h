#include <stddef.h>
#include <stdint.h>

/* 0 = complete stream, 1 = output limit, 2 = invalid/incomplete stream. */
int proxylab_inflate(const uint8_t *input, size_t input_size,
                     uint8_t *output, size_t output_capacity,
                     size_t *output_size, int window_bits);
