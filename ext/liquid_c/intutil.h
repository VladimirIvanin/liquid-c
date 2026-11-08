#ifndef LIQUID_INTUTIL_H
#define LIQUID_INTUTIL_H

#include <stdint.h>

static inline uint32_t bytes_to_uint32(const uint8_t *bytes)
{
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
        ((uint32_t)bytes[2] << 8) | bytes[3];
}

static inline void uint32_to_bytes(uint32_t num, uint8_t *bytes)
{
    bytes[0] = num >> 24;
    bytes[1] = num >> 16;
    bytes[2] = num >> 8;
    bytes[3] = num;
}

static inline unsigned int bytes_to_uint24(const uint8_t *bytes)
{
    return (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
}

static inline void uint24_to_bytes(unsigned int num, uint8_t *bytes)
{
    if (num >= (1U << 24)) rb_raise(rb_eRangeError, "Value exceeds 24-bit bytecode operand");

    bytes[0] = num >> 16;
    bytes[1] = num >> 8;
    bytes[2] = num;

    assert(bytes_to_uint24(bytes) == num);
}

#endif
