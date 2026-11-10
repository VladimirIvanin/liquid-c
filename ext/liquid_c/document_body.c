#include <ruby.h>
#include <stdalign.h>
#include "liquid.h"
#include "vm_assembler.h"
#include "document_body.h"

static VALUE cLiquidCDocumentBody;

static void document_body_mark(void *ptr)
{
    document_body_t *body = ptr;
    /* When Liquid::C::BlockBody#freeze is called, it calls
     * document_body_write_block_body which sets the document_body_entry but
     * does not yet set the compiled flag to true. During this time, the only
     * reference to this Liquid::C::DocumentBody object is in the instance
     * variables of the parse_context which is marked movable by Ruby. This
     * causes the self reference here to be moved by compaction causing it to
     * point to an incorrect object. */
    rb_gc_mark(body->self);
    rb_gc_mark(body->constants);
}

static void document_body_free(void *ptr)
{
    document_body_t *body = ptr;
    c_buffer_free(&body->buffer);
    c_buffer_free(&body->invalid_serials);
    xfree(body);
}

static size_t document_body_memsize(const void *ptr)
{
    const document_body_t *body = ptr;
    return sizeof(document_body_t) + c_buffer_capacity(&body->buffer) + c_buffer_capacity(&body->invalid_serials);
}

const rb_data_type_t document_body_data_type = {
    "liquid_document_body",
    { document_body_mark, document_body_free, document_body_memsize },
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};

static VALUE document_body_allocate(VALUE klass)
{
    document_body_t *body;

    VALUE obj = TypedData_Make_Struct(klass, document_body_t, &document_body_data_type, body);
    body->self = obj;
    body->frontend_cache_size = -1;
    body->constants = rb_ary_new();
    body->buffer = c_buffer_init();
    body->invalid_serials = c_buffer_init();

    return obj;
}

#define DocumentBody_Get_Struct(obj, sval) TypedData_Get_Struct(obj, document_body_t, &document_body_data_type, sval)

bool document_body_cache_stable(VALUE self, long size)
{
    if (RB_OBJ_FROZEN(self)) return false;
    document_body_t *body;
    DocumentBody_Get_Struct(self, body);
    bool stable = body->frontend_cache_size == size;
    body->frontend_cache_size = size;
    return stable;
}

void document_body_checkpoint(VALUE self, size_t *buffer_size, long *constants_len, size_t *serial)
{
    document_body_t *body;
    DocumentBody_Get_Struct(self, body);
    *buffer_size = c_buffer_size(&body->buffer);
    *constants_len = RARRAY_LEN(body->constants);
    *serial = body->next_serial;
}

void document_body_truncate(VALUE self, size_t buffer_size, long constants_len, size_t serial)
{
    document_body_t *body;
    DocumentBody_Get_Struct(self, body);
    assert(!RB_OBJ_FROZEN(self));
    assert(buffer_size <= c_buffer_size(&body->buffer));
    assert(constants_len <= RARRAY_LEN(body->constants));
    assert(serial <= body->next_serial);
    if (serial < body->next_serial)
        c_buffer_reserve_for_write(&body->invalid_serials, 2 * sizeof(size_t));
    rb_ary_resize(body->constants, constants_len);
    if (serial < body->next_serial) {
        size_t range[2] = { serial + 1, body->next_serial };
        c_buffer_write(&body->invalid_serials, range, sizeof(range));
    }
    if (buffer_size == 0) c_buffer_free(&body->buffer);
    else body->buffer.data_end = body->buffer.data + buffer_size;
}

void document_body_finish(VALUE self)
{
    document_body_t *body;
    DocumentBody_Get_Struct(self, body);
    size_t size = c_buffer_size(&body->buffer);
    size_t capacity = c_buffer_capacity(&body->buffer);
    if (capacity - size > 65536 && capacity - size > size / 4) {
        if (size) {
            body->buffer.data = xrealloc(body->buffer.data, size);
            body->buffer.data_end = body->buffer.data + size;
            body->buffer.capacity_end = body->buffer.data_end;
        } else {
            c_buffer_free(&body->buffer);
        }
    }
    rb_obj_freeze(self);
}

VALUE document_body_new_instance(void)
{
    return rb_class_new_instance(0, NULL, cLiquidCDocumentBody);
}

document_body_entry_t document_body_write_block_body(VALUE self, bool blank, uint32_t render_score, vm_assembler_t *code)
{
    assert(!RB_OBJ_FROZEN(self));

    document_body_t *body;
    DocumentBody_Get_Struct(self, body);

    if (c_buffer_size(&code->instructions) > UINT32_MAX ||
        c_buffer_size(&code->constants) / sizeof(VALUE) > UINT32_MAX ||
        (size_t)RARRAY_LEN(body->constants) > UINT32_MAX ||
        c_buffer_size(&code->constants) / sizeof(VALUE) > UINT32_MAX - (size_t)RARRAY_LEN(body->constants))
        rb_raise(rb_eRangeError, "Liquid document exceeds bytecode representation");
    if (body->next_serial == SIZE_MAX)
        rb_raise(rb_eRangeError, "Too many Liquid block bodies");

    size_t old_size = c_buffer_size(&body->buffer);
    size_t alignment = alignof(block_body_header_t);
    size_t padding = (alignment - old_size % alignment) % alignment;
    size_t instructions_bytes = c_buffer_size(&code->instructions);
    if (padding > SIZE_MAX - sizeof(block_body_header_t) ||
        instructions_bytes > SIZE_MAX - padding - sizeof(block_body_header_t))
        rb_raise(rb_eNoMemError, "Liquid document size overflow");
    // Reserve every byte before appending constants. rb_ary_cat may raise;
    // until it succeeds, the document's logical size is unchanged.
    vm_assembler_allocation_checkpoint();
    c_buffer_reserve_for_write(&body->buffer, padding + sizeof(block_body_header_t) + instructions_bytes);

    assert(c_buffer_size(&code->constants) % sizeof(VALUE) == 0);
    uint32_t constants_len = (uint32_t)(c_buffer_size(&code->constants) / sizeof(VALUE));

    vm_assembler_allocation_checkpoint();
    rb_ary_cat(body->constants, (VALUE *)code->constants.data, constants_len);
    c_buffer_zero_pad_for_alignment(&body->buffer, alignment);
    size_t buffer_offset = c_buffer_size(&body->buffer);
    block_body_header_t *buf_block_body = c_buffer_extend_for_write(&body->buffer, sizeof(block_body_header_t));
    buf_block_body->instructions_offset = (uint32_t)sizeof(block_body_header_t);
    buf_block_body->instructions_bytes = (uint32_t)c_buffer_size(&code->instructions);
    buf_block_body->constants_offset = (uint32_t)(RARRAY_LEN(body->constants) - constants_len);
    buf_block_body->constants_len = constants_len;
    buf_block_body->flags = 0;
    if (blank) buf_block_body->flags |= BLOCK_BODY_HEADER_FLAG_BLANK;
    buf_block_body->render_score = render_score;
    buf_block_body->max_stack_size = code->max_stack_size;

    c_buffer_concat(&body->buffer, &code->instructions);

    return (document_body_entry_t) { .body = body, .buffer_offset = buffer_offset,
        .serial = ++body->next_serial };
}

void liquid_define_document_body(void)
{
    cLiquidCDocumentBody = rb_define_class_under(mLiquidC, "DocumentBody", rb_cObject);
    rb_global_variable(&cLiquidCDocumentBody);
    rb_define_alloc_func(cLiquidCDocumentBody, document_body_allocate);
}
