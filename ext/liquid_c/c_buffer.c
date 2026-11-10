#include "c_buffer.h"

static void c_buffer_expand_for_write(c_buffer_t *buffer, size_t write_size)
{
    size_t capacity = c_buffer_capacity(buffer);
    size_t size = c_buffer_size(buffer);
    if (write_size > PTRDIFF_MAX - size)
        rb_raise(rb_eNoMemError, "Liquid buffer size overflow");
    size_t required_capacity = size + write_size;

    if (capacity < 1)
        capacity = 1;
    do {
        if (capacity > PTRDIFF_MAX / 2) {
            capacity = required_capacity;
            break;
        }
        capacity *= 2;
    } while (capacity < required_capacity);
    buffer->data = xrealloc(buffer->data, capacity);
    buffer->data_end = buffer->data + size;
    buffer->capacity_end = buffer->data + capacity;
}

void c_buffer_zero_pad_for_alignment(c_buffer_t *buffer, size_t alignment)
{
    size_t unaligned_bytes = c_buffer_size(buffer) % alignment;
    if (unaligned_bytes) {
        size_t pad_size = alignment - unaligned_bytes;
        uint8_t *padding = c_buffer_extend_for_write(buffer, pad_size);
        memset(padding, 0, pad_size);
    }
}

void c_buffer_reserve_for_write(c_buffer_t *buffer, size_t write_size)
{
    if (write_size > c_buffer_capacity(buffer) - c_buffer_size(buffer)) {
        c_buffer_expand_for_write(buffer, write_size);
    }
}

void c_buffer_write(c_buffer_t *buffer, void *write_data, size_t write_size)
{
    if (!write_size) return;
    c_buffer_reserve_for_write(buffer, write_size);
    memcpy(buffer->data_end, write_data, write_size);
    buffer->data_end += write_size;
}
