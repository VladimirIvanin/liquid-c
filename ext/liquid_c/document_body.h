#ifndef LIQUID_DOCUMENT_BODY_H
#define LIQUID_DOCUMENT_BODY_H

#include "c_buffer.h"
#include "vm_assembler.h"

typedef struct block_body_header {
    uint32_t instructions_offset;
    uint32_t instructions_bytes;
    uint32_t constants_offset;
    uint32_t constants_len;
    uint32_t flags;
    uint32_t render_score;
    uint64_t max_stack_size;
} block_body_header_t;

#define BLOCK_BODY_HEADER_FLAG_BLANK (1 << 0)
#define BLOCK_BODY_HEADER_BLANK_P(header) (header->flags & BLOCK_BODY_HEADER_FLAG_BLANK)

typedef struct document_body {
    VALUE self;
    VALUE constants;
    long frontend_cache_size;
    c_buffer_t buffer;
    c_buffer_t invalid_serials;
    size_t next_serial;
} document_body_t;

typedef struct document_body_entry {
    document_body_t *body;
    size_t buffer_offset;
    size_t serial;
} document_body_entry_t;

void liquid_define_document_body(void);
VALUE document_body_new_instance(void);
bool document_body_cache_stable(VALUE self, long size);
document_body_entry_t document_body_write_block_body(VALUE self, bool blank, uint32_t render_score, vm_assembler_t *code);
void document_body_checkpoint(VALUE self, size_t *buffer_size, long *constants_len, size_t *serial);
void document_body_truncate(VALUE self, size_t buffer_size, long constants_len, size_t serial);
void document_body_finish(VALUE self);

static inline void document_body_entry_mark(document_body_entry_t *entry)
{
    rb_gc_mark(entry->body->self);
    rb_gc_mark(entry->body->constants);
}

static inline block_body_header_t *document_body_get_block_body_header_ptr(const document_body_entry_t *entry)
{
    const size_t *ranges = (const size_t *)entry->body->invalid_serials.data;
    size_t range_count = c_buffer_size(&entry->body->invalid_serials) / (2 * sizeof(size_t));
    size_t low = 0, high = range_count;
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        if (ranges[middle * 2 + 1] < entry->serial) low = middle + 1;
        else high = middle;
    }
    if (low < range_count && entry->serial >= ranges[low * 2])
        rb_raise(rb_eRuntimeError, "Liquid block body was discarded during parsing");
    size_t size = c_buffer_size(&entry->body->buffer);
    if (entry->buffer_offset > size || size - entry->buffer_offset < sizeof(block_body_header_t))
        rb_raise(rb_eRuntimeError, "Liquid block body was discarded during parsing");
    return (block_body_header_t *)(entry->body->buffer.data + entry->buffer_offset);
}

static inline const VALUE *document_body_get_constants_ptr(const document_body_entry_t *entry)
{
    block_body_header_t *header = document_body_get_block_body_header_ptr(entry);
    return RARRAY_CONST_PTR(entry->body->constants) + header->constants_offset;
}

static inline void document_body_ensure_compile_finished(document_body_t *body)
{
    if (RB_UNLIKELY(!RB_OBJ_FROZEN(body->self))) {
        rb_raise(rb_eRuntimeError, "Liquid document hasn't finished compilation");
    }
}

#endif
