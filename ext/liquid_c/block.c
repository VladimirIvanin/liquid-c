#include "liquid.h"
#include "block.h"
#include "intutil.h"
#include "tokenizer.h"
#include "stringutil.h"
#include "liquid_vm.h"
#include "variable.h"
#include "context.h"
#include "parse_context.h"
#include "vm_assembler.h"
#include <stdio.h>

static VALUE native_block_body_class;

static ID
    intern_raise_missing_variable_terminator,
    intern_raise_missing_tag_terminator,
    intern_is_blank,
    intern_parse,
    intern_unknown_tag_in_liquid_tag;

typedef struct tag_markup {
    VALUE name;
    VALUE markup;
} tag_markup_t;

typedef struct parse_context {
    tokenizer_t *tokenizer;
    VALUE tokenizer_obj;
    VALUE ruby_obj;
    variable_compile_guard_t variable_guard;
} parse_context_t;

static void ensure_body_compiled(const block_body_t *body)
{
    if (!body->compiled) {
        rb_raise(rb_eRuntimeError, "Liquid::C::BlockBody has not been compiled");
    }
}

static void block_body_mark(void *ptr)
{
    block_body_t *body = ptr;
    if (body->compiled) {
        document_body_entry_mark(&body->as.compiled.document_body_entry);
        rb_gc_mark(body->as.compiled.nodelist);
    } else {
        rb_gc_mark(body->as.intermediate.parse_context);
        if (body->as.intermediate.vm_assembler_pool)
            rb_gc_mark(body->as.intermediate.vm_assembler_pool->self);
        if (body->as.intermediate.code)
            vm_assembler_gc_mark(body->as.intermediate.code);
    }
}

static void block_body_free(void *ptr)
{
    block_body_t *body = ptr;
    if (!body->compiled && body->as.intermediate.code) {
        // Free the assembler instead of recycling it because the vm_assembler_pool may have been GC'd
        vm_assembler_pool_free_assembler(body->as.intermediate.code);
    }
    xfree(body);
}

static size_t block_body_memsize(const void *ptr)
{
    const block_body_t *body = ptr;
    if (!ptr) return 0;
    if (body->compiled) {
        return sizeof(block_body_t);
    } else {
        return sizeof(block_body_t) + vm_assembler_alloc_memsize(body->as.intermediate.code);
    }
}

const rb_data_type_t block_body_data_type = {
    "liquid_block_body",
    { block_body_mark, block_body_free, block_body_memsize, },
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};

#define BlockBody_Get_Struct(obj, sval) TypedData_Get_Struct(obj, block_body_t, &block_body_data_type, sval)

static VALUE block_body_allocate(VALUE klass)
{
    block_body_t *body;
    VALUE obj = TypedData_Make_Struct(klass, block_body_t, &block_body_data_type, body);

    body->compiled = false;
    body->as.intermediate.blank = true;
    body->as.intermediate.render_score = 0;
    body->as.intermediate.vm_assembler_pool = NULL;
    body->as.intermediate.code = NULL;
    return obj;
}

static VALUE block_body_initialize(VALUE self, VALUE parse_context)
{
    rb_check_frozen(self);
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    if (body->compiled || body->as.intermediate.code)
        rb_raise(rb_eRuntimeError, "Liquid::C::BlockBody is already initialized");

    body->as.intermediate.parse_context = parse_context;
    body->as.intermediate.vm_assembler_pool = parse_context_get_vm_assembler_pool(parse_context);
    body->as.intermediate.code = vm_assembler_pool_alloc_assembler(body->as.intermediate.vm_assembler_pool);
    vm_assembler_add_leave(body->as.intermediate.code);

    return Qnil;
}

static VALUE block_body_initialize_copy(VALUE self, VALUE other)
{
    if (self == other) return self;
    rb_obj_init_copy(self, other);
    block_body_t *body, *original;
    BlockBody_Get_Struct(self, body);
    BlockBody_Get_Struct(other, original);
    if (body->compiled || body->as.intermediate.code)
        rb_raise(rb_eRuntimeError, "Liquid::C::BlockBody is already initialized");
    if (original->compiled) {
        *body = *original;
    } else if (original->as.intermediate.code) {
        body->as.intermediate.parse_context = original->as.intermediate.parse_context;
        body->as.intermediate.vm_assembler_pool = original->as.intermediate.vm_assembler_pool;
        body->as.intermediate.blank = original->as.intermediate.blank;
        body->as.intermediate.render_score = original->as.intermediate.render_score;
        vm_assembler_t *src = original->as.intermediate.code;
        vm_assembler_t *dest = vm_assembler_pool_alloc_assembler(body->as.intermediate.vm_assembler_pool);
        body->as.intermediate.code = dest;
        c_buffer_concat(&dest->instructions, &src->instructions);
        c_buffer_concat(&dest->constants, &src->constants);
        st_table *table = st_copy(src->constants_table);
        st_free_table(dest->constants_table);
        dest->constants_table = table;
        dest->max_stack_size = src->max_stack_size;
        dest->stack_size = src->stack_size;
        dest->protected_stack_size = src->protected_stack_size;
        dest->parsing = src->parsing;
    }
    RB_GC_GUARD(other);
    return self;
}

static int is_id(int c)
{
    return rb_isalnum(c) || c == '_';
}

static tag_markup_t internal_block_body_parse(VALUE body_obj, block_body_t *body, parse_context_t *parse_context);
static VALUE control_try_parse(VALUE klass, VALUE name, VALUE markup, variable_parse_args_t *args, parse_context_t *context);

typedef struct {
    VALUE body_obj;
    block_body_t *body;
    parse_context_t *context;
    tokenizer_t saved;
    tag_markup_t result;
} liquid_parse_frame_t;

static VALUE parse_liquid_body(VALUE opaque)
{
    liquid_parse_frame_t *frame = (void *)opaque;
    frame->result = internal_block_body_parse(frame->body_obj, frame->body, frame->context);
    return Qnil;
}

static VALUE restore_liquid_tokenizer(VALUE opaque)
{
    liquid_parse_frame_t *frame = (void *)opaque;
    *frame->context->tokenizer = frame->saved;
    return Qnil;
}

static tag_markup_t internal_block_body_parse(VALUE body_obj, block_body_t *body, parse_context_t *parse_context)
{
    if (ruby_stack_check()) rb_raise(rb_eSysStackError, "stack level too deep");
    tokenizer_t *tokenizer = parse_context->tokenizer;
    token_t token;
    tag_markup_t unknown_tag = { Qnil, Qnil };
    int render_score_increment = 0;
    VALUE environment = Qundef;
    variable_compile_guard_t *variable_guard = &parse_context->variable_guard;

    while (true) {
        VALUE token_start_line_number = tokenizer->line_number;
        if (!NIL_P(token_start_line_number)) {
            rb_ivar_set(parse_context->ruby_obj, id_ivar_line_number, token_start_line_number);
        }
        tokenizer_next(tokenizer, &token);

        switch (token.type) {
            case TOKENIZER_TOKEN_NONE:
                goto loop_break;

            case TOKEN_INVALID:
            {
                VALUE str = rb_enc_str_new(token.str_full, token.len_full, utf8_encoding);

                ID raise_method_id = intern_raise_missing_variable_terminator;
                if (token.str_full[1] == '%') raise_method_id = intern_raise_missing_tag_terminator;

                variable_guard->valid = false;
                rb_funcall(cLiquidBlockBody, raise_method_id, 2, str, parse_context->ruby_obj);
                goto loop_break;
            }
            case TOKEN_RAW:
            {
                const char *start = token.str_full, *end = token.str_full + token.len_full;
                const char *token_start = start, *token_end = end;

                if (token.lstrip)
                    token_start = read_while(start, end, rb_isspace);

                if (token.rstrip) {
                    if (tokenizer->bug_compatible_whitespace_trimming) {
                        token_end = read_while_reverse(token_start + 1, end, rb_isspace);
                    } else {
                        token_end = read_while_reverse(token_start, end, rb_isspace);
                    }
                }

                // Skip token entirely if there is no data to be rendered.
                if (token_start == token_end)
                    break;

                vm_assembler_add_write_raw(body->as.intermediate.code, token_start, token_end - token_start);
                render_score_increment += 1;

                if (body->as.intermediate.blank) {
                    const char *end = token.str_full + token.len_full;

                    if (read_while(token.str_full, end, rb_isspace) < end)
                        body->as.intermediate.blank = false;
                }
                break;
            }
            case TOKEN_VARIABLE:
            {
                variable_parse_args_t parse_args = {
                    .source = tokenizer->source,
                    .markup = token.str_trimmed,
                    .markup_end = token.str_trimmed + token.len_trimmed,
                    .code = body->as.intermediate.code,
                    .code_obj = body_obj,
                    .parse_context = parse_context->ruby_obj,
                    .guard = variable_guard,
                };
                internal_variable_compile(&parse_args, token_start_line_number);
                render_score_increment += 1;
                body->as.intermediate.blank = false;
                break;
            }
            case TOKEN_TAG:
            {
                const char *start = token.str_trimmed, *end = token.str_trimmed + token.len_trimmed;

                // Imitate \s*(\w+)\s*(.*)? regex
                const char *name_start = read_while(start, end, rb_isspace);
                const char *name_end = read_while(name_start, end, is_id);
                long name_len = name_end - name_start;

                if (name_len == 0) {
                    if (name_start < end && *name_start == '#') { // inline comment
                        name_end++;
                        name_len++;
                    } else {
                        const char *invalid = tokenizer->for_liquid_tag ? token.str_trimmed : token.str_full;
                        long invalid_len = tokenizer->for_liquid_tag ? token.len_trimmed : token.len_full;
                        VALUE str = rb_enc_str_new(invalid, invalid_len, utf8_encoding);
                        unknown_tag = (tag_markup_t) { str, str };
                        goto loop_break;
                    }
                }

                if (name_len == 6 && strncmp(name_start, "liquid", 6) == 0) {
                    const char *markup_start = read_while(name_end, end, rb_isspace);
                    VALUE line_number = token_start_line_number;
                    if (!NIL_P(line_number)) {
                        int lines = count_newlines(token.str_full, markup_start) - (tokenizer->for_liquid_tag ? 1 : 0);
                        if (lines) line_number = rb_funcall(line_number, rb_intern("+"), 1, INT2NUM(lines));
                    }

                    liquid_parse_frame_t frame = { body_obj, body, parse_context, *tokenizer, { Qnil, Qnil } };
                    tokenizer_setup_for_liquid_tag(tokenizer, markup_start, end, line_number);
                    rb_ensure(parse_liquid_body, (VALUE)&frame, restore_liquid_tokenizer, (VALUE)&frame);
                    unknown_tag = frame.result;
                    if (unknown_tag.name != Qnil) {
                        variable_guard->valid = false;
                        rb_funcall(cLiquidBlockBody, intern_unknown_tag_in_liquid_tag, 2, unknown_tag.name, parse_context->ruby_obj);
                        goto loop_break;
                    }
                    break;
                }

                const char *markup_start = read_while(name_end, end, rb_isspace);
                if (!NIL_P(token_start_line_number)) {
                    // FullToken counts newlines in the whitespace on either
                    // side of the tag name before constructing the Ruby tag.
                    int lines = count_newlines(start, name_start) + count_newlines(name_end, markup_start);
                    if (lines) {
                        VALUE line_number = rb_funcall(token_start_line_number, rb_intern("+"), 1, INT2NUM(lines));
                        rb_ivar_set(parse_context->ruby_obj, id_ivar_line_number, line_number);
                    }
                }

                VALUE tag_name = rb_enc_str_new(name_start, name_end - name_start, utf8_encoding);
                variable_parse_args_t args = {
                    .parse_context = parse_context->ruby_obj, .code_obj = body_obj,
                    .code = body->as.intermediate.code, .guard = variable_guard,
                };
                if (environment == Qundef) {
                    if (variable_guard->valid && native_compiler_guard(&args)) environment = rb_ivar_get(parse_context->ruby_obj, rb_intern("@environment"));
                    else {
                        variable_guard->valid = false;
                        environment = rb_funcall(parse_context->ruby_obj, rb_intern("environment"), 0);
                    }
                }
                VALUE tag_class = native_registered_tag(&args, environment, tag_name);
                if (tag_class == Qundef) {
                    variable_guard->valid = false;
                    tag_class = rb_funcall(environment, rb_intern("tag_for_name"), 1, tag_name);
                }
                VALUE markup = rb_enc_str_new(markup_start, end - markup_start, utf8_encoding);
                if (tag_class == Qnil) {
                    unknown_tag = (tag_markup_t) { tag_name, markup };
                    goto loop_break;
                }
                VALUE new_tag = control_try_parse(tag_class, tag_name, markup, &args, parse_context);
                if (new_tag == Qundef) {
                    variable_guard->valid = false;
                    new_tag = rb_funcall(tag_class, intern_parse, 4,
                        tag_name, markup, parse_context->tokenizer_obj, parse_context->ruby_obj);
                }
                if (body->as.intermediate.blank) {
                    VALUE blank;
                    if (variable_guard->valid && (native_control_kind(CLASS_OF(new_tag)) || native_assignment_class_p(CLASS_OF(new_tag)) ||
                        native_include_class_p(CLASS_OF(new_tag))) &&
                        native_control_guard(&args)) {
                        if (native_include_class_p(CLASS_OF(new_tag))) blank = Qfalse;
                        else if (native_assignment_class_p(CLASS_OF(new_tag)) || native_control_kind(CLASS_OF(new_tag)) == 3) blank = Qtrue;
                        else blank = rb_ivar_get(new_tag, rb_intern("@blank"));
                    } else {
                        variable_guard->valid = false;
                        blank = rb_funcall(new_tag, intern_is_blank, 0);
                    }
                    if (!RTEST(blank)) body->as.intermediate.blank = false;
                }

                if (!NIL_P(tokenizer->raw_tag_body)) {
                    vm_assembler_add_write_raw_value(body->as.intermediate.code, tokenizer->raw_tag_body);
                    tokenizer->raw_tag_body = Qnil;
                } else {
                    vm_assembler_add_write_node(body->as.intermediate.code, new_tag);
                }

                render_score_increment += 1;
                break;
            }
            case TOKEN_BLANK_LIQUID_TAG_LINE:
                break;
        }
    }
loop_break:
    RB_GC_GUARD(body_obj);
    RB_GC_GUARD(environment);
    body->as.intermediate.render_score += render_score_increment;
    return unknown_tag;
}

static void ensure_intermediate(VALUE self, block_body_t *body)
{
    rb_check_frozen(self);
    if (body->compiled) {
        rb_raise(rb_eRuntimeError, "Liquid::C::BlockBody is already compiled");
    }
    if (!body->as.intermediate.code)
        rb_raise(rb_eRuntimeError, "Liquid::C::BlockBody has not been initialized");
}

static void ensure_intermediate_not_parsing(VALUE self, block_body_t *body)
{
    ensure_intermediate(self, body);

    if (body->as.intermediate.code->parsing) {
        rb_raise(rb_eRuntimeError, "Liquid::C::BlockBody is in a incompletely parsed state");
    }
}

static VALUE block_body_parse(VALUE self, VALUE tokenizer_obj, VALUE parse_context_obj)
{
    rb_check_frozen(self);
    parse_context_t parse_context = {
        .tokenizer_obj = tokenizer_obj,
        .ruby_obj = parse_context_obj,
    };
    Tokenizer_Get_Struct(tokenizer_obj, parse_context.tokenizer);
    parse_context_get_document_body(parse_context_obj);
    block_body_t *body;
    BlockBody_Get_Struct(self, body);

    ensure_intermediate_not_parsing(self, body);
    if (body->as.intermediate.parse_context != parse_context_obj) {
        rb_raise(rb_eArgError, "Liquid::C::BlockBody#parse called with different parse context");
    }
    vm_assembler_remove_leave(body->as.intermediate.code); // to extend block

    tag_markup_t unknown_tag = internal_block_body_parse(self, body, &parse_context);
    vm_assembler_add_leave(body->as.intermediate.code);

    return rb_yield_values(2, unknown_tag.name, unknown_tag.markup);
}

static VALUE block_body_freeze(VALUE self)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);

    if (body->compiled) return rb_call_super(0, NULL);

    ensure_intermediate_not_parsing(self, body);

    VALUE parse_context = body->as.intermediate.parse_context;
    VALUE document_body = parse_context_get_document_body(parse_context);
    rb_check_frozen(document_body);

    vm_assembler_pool_t *assembler_pool = body->as.intermediate.vm_assembler_pool;
    vm_assembler_t *assembler = body->as.intermediate.code;
    bool blank = body->as.intermediate.blank;
    uint32_t render_score = body->as.intermediate.render_score;
    vm_assembler_t *code = body->as.intermediate.code;
    body->as.compiled.document_body_entry = document_body_write_block_body(document_body, blank, render_score, code);
    body->as.compiled.nodelist = Qundef;
    body->compiled = true;
    vm_assembler_pool_recycle_assembler(assembler_pool, assembler);

    return rb_call_super(0, NULL);
}

// Build the ordinary Ruby tag objects, but keep standard structural parsing
// in the same C interval as their child bodies. Runtime tag methods are intact.
typedef struct {
    VALUE tag, body;
    variable_parse_args_t *args;
    parse_context_t *context;
    tag_markup_t end;
} control_segment_t;

static bool control_interval_current(variable_parse_args_t *args)
{
    return args->guard->valid && args->guard->control_validated && args->guard->gc_count == rb_gc_count() && native_control_guard(args);
}

static VALUE control_new_body(VALUE tag, variable_parse_args_t *args)
{
    if (native_control_kind(CLASS_OF(tag)) && control_interval_current(args)) {
        size_t gc = rb_gc_count();
        VALUE body = block_body_allocate(native_block_body_class);
        if (gc == rb_gc_count()) block_body_initialize(body, args->parse_context);
        else {
            args->guard->valid = false;
            rb_funcall(body, rb_intern("initialize"), 1, args->parse_context);
        }
        RB_GC_GUARD(body);
        return body;
    }
    args->guard->valid = false;
    return rb_funcall(tag, rb_intern("new_body"), 0);
}

static VALUE control_complete_segment(VALUE opaque);

static VALUE control_segment_body(VALUE opaque)
{
    control_segment_t *segment = (void *)opaque;
    block_body_t *body;
    BlockBody_Get_Struct(segment->body, body);
    ensure_intermediate_not_parsing(segment->body, body);
    vm_assembler_remove_leave(body->as.intermediate.code);
    segment->end = internal_block_body_parse(segment->body, body, segment->context);
    vm_assembler_add_leave(body->as.intermediate.code);
    return control_complete_segment(opaque);
}

static VALUE control_restore_depth(VALUE opaque)
{
    control_segment_t *segment = (void *)opaque;
    VALUE context = segment->args->parse_context;
    if (control_interval_current(segment->args)) {
        VALUE depth = rb_ivar_get(context, rb_intern("@depth"));
        if (RB_FIXNUM_P(depth)) {
            rb_ivar_set(context, rb_intern("@depth"), LONG2NUM(FIX2LONG(depth) - 1));
            return Qnil;
        }
    }
    segment->args->guard->valid = false;
    VALUE depth = rb_funcallv_public(context, rb_intern("depth"), 0, NULL);
    if (!RB_INTEGER_TYPE_P(depth)) segment->args->guard->valid = false;
    VALUE one = INT2FIX(1);
    VALUE restored = rb_funcall(depth, rb_intern("-"), 1, one);
    rb_funcallv_public(context, rb_intern("depth="), 1, &restored);
    return Qnil;
}

static bool control_parse_segment(VALUE tag, VALUE body_obj, variable_parse_args_t *args, parse_context_t *context)
{
    if (!control_interval_current(args) || CLASS_OF(body_obj) != native_block_body_class || !native_control_kind(CLASS_OF(tag))) {
        args->guard->valid = false;
        return RTEST(rb_funcall(tag, rb_intern("parse_body"), 2, body_obj, context->tokenizer_obj));
    }
    VALUE depth = rb_ivar_get(args->parse_context, rb_intern("@depth"));
    if (!RB_FIXNUM_P(depth)) {
        args->guard->valid = false;
        return RTEST(rb_funcall(tag, rb_intern("parse_body"), 2, body_obj, context->tokenizer_obj));
    }
    if (FIX2LONG(depth) >= 100) rb_raise(rb_const_get(mLiquid, rb_intern("StackLevelError")), "Nesting too deep");
    rb_ivar_set(args->parse_context, rb_intern("@depth"), LONG2NUM(FIX2LONG(depth) + 1));
    control_segment_t segment = { tag, body_obj, args, context, { Qnil, Qnil } };
    return RTEST(rb_ensure(control_segment_body, (VALUE)&segment, control_restore_depth, (VALUE)&segment));
}

static VALUE control_complete_segment(VALUE opaque)
{
    control_segment_t *segment = (void *)opaque;
    VALUE tag = segment->tag, body_obj = segment->body;
    variable_parse_args_t *args = segment->args;
    parse_context_t *context = segment->context;
    if (RTEST(rb_ivar_get(tag, rb_intern("@blank")))) {
        VALUE blank;
        if ((native_control_kind(CLASS_OF(tag)) && CLASS_OF(body_obj) == native_block_body_class && control_interval_current(args))) {
            block_body_t *body;
            BlockBody_Get_Struct(body_obj, body);
            blank = body->as.intermediate.blank ? Qtrue : Qfalse;
        } else {
            args->guard->valid = false;
            blank = rb_funcallv_public(body_obj, rb_intern("blank?"), 0, NULL);
        }
        rb_ivar_set(tag, rb_intern("@blank"), blank);
    }
    VALUE delimiter = rb_ivar_get(tag, rb_intern("@block_delimiter"));
    VALUE tag_name = rb_ivar_get(tag, rb_intern("@tag_name"));
    if ((native_control_kind(CLASS_OF(tag)) && CLASS_OF(body_obj) == native_block_body_class && control_interval_current(args)) && CLASS_OF(tag_name) == rb_cString &&
        (!RTEST(delimiter) || CLASS_OF(delimiter) == rb_cString)) {
        if (!RTEST(delimiter)) {
            delimiter = rb_str_new_cstr("end");
            rb_str_append(delimiter, tag_name);
            rb_ivar_set(tag, rb_intern("@block_delimiter"), delimiter);
        }
    } else {
        args->guard->valid = false;
        delimiter = rb_funcall(tag, rb_intern("block_delimiter"), 0);
    }
    if (RTEST(rb_funcall(segment->end.name, rb_intern("=="), 1, delimiter))) return Qfalse;
    if (NIL_P(segment->end.name)) {
        args->guard->valid = false;
        VALUE name = rb_funcall(tag, rb_intern("block_name"), 0);
        rb_funcall(tag, rb_intern("raise_tag_never_closed"), 1, name);
    }
    VALUE name = segment->end.name, markup = segment->end.markup;
    bool is_else = RB_TYPE_P(name, T_STRING) && RSTRING_LEN(name) == 4 && !memcmp(RSTRING_PTR(name), "else", 4);
    bool is_elsif = RB_TYPE_P(name, T_STRING) && RSTRING_LEN(name) == 5 && !memcmp(RSTRING_PTR(name), "elsif", 5);
    int kind = native_control_kind(CLASS_OF(tag));
    if (((kind == 1 && (is_else || is_elsif)) || (kind == 2 && is_else)) && (native_control_kind(CLASS_OF(tag)) && CLASS_OF(body_obj) == native_block_body_class && native_control_guard(args))) {
        if (kind == 2) {
            rb_ivar_set(tag, rb_intern("@else_block"), control_new_body(tag, args));
            return Qtrue;
        }
        VALUE condition;
        if (is_else) condition = native_control_else(args);
        else {
            VALUE header = native_control_header(args, markup, 1, true);
            if (NIL_P(header)) goto ruby_unknown;
            condition = RARRAY_AREF(header, 0);
        }
        VALUE body = control_new_body(tag, args);
        native_control_attach(args, condition, body);
        VALUE blocks = rb_ivar_get(tag, rb_intern("@blocks"));
        if (CLASS_OF(blocks) != rb_cArray || !(native_control_kind(CLASS_OF(tag)) && CLASS_OF(body_obj) == native_block_body_class && control_interval_current(args))) {
            args->guard->valid = false;
            rb_funcallv_public(blocks, rb_intern("push"), 1, &condition);
        } else rb_ary_push(blocks, condition);
        return Qtrue;
    }
ruby_unknown:
    args->guard->valid = false;
    rb_funcall(tag, rb_intern("unknown_tag"), 3, name, markup, context->tokenizer_obj);
    return Qtrue;
}

static VALUE control_try_parse(VALUE klass, VALUE name, VALUE markup, variable_parse_args_t *args, parse_context_t *context)
{
    if (native_assignment_class_p(klass)) return native_parse_assignment(args, klass, name, markup);
    if (native_include_class_p(klass)) return native_parse_include(args, klass, name, markup);
    int kind = native_control_kind(klass);
    if (!kind) return Qundef;
    VALUE line = rb_ivar_get(args->parse_context, id_ivar_line_number);
    if (kind == 3) {
        VALUE tag = native_parse_capture(args, klass, name, markup);
        if (tag == Qundef) return Qundef;
        VALUE body = control_new_body(tag, args);
        rb_ivar_set(tag, rb_intern("@body"), body);
        while (control_parse_segment(tag, body, args, context)) {
            body = rb_ivar_get(tag, rb_intern("@body"));
        }
        native_control_finish(args, tag, kind);
        if (args->guard->gc_count != rb_gc_count()) args->guard->valid = false;
        RB_GC_GUARD(body);
        return tag;
    }
    VALUE header = native_control_header(args, markup, kind, false);
    if (NIL_P(header)) return Qundef;
    size_t header_gc = rb_gc_count();
    VALUE tag = rb_obj_alloc(klass);
    if (header_gc != rb_gc_count()) {
        args->guard->valid = false;
        rb_funcall(tag, rb_intern("initialize"), 3, name, markup, args->parse_context);
        rb_funcallv_public(tag, intern_parse, 1, &context->tokenizer_obj);
        RB_GC_GUARD(header);
        return tag;
    }
    rb_ivar_set(tag, rb_intern("@tag_name"), name);
    rb_ivar_set(tag, rb_intern("@markup"), markup);
    rb_ivar_set(tag, rb_intern("@parse_context"), args->parse_context);
    rb_ivar_set(tag, id_ivar_line_number, line);
    rb_ivar_set(tag, rb_intern("@blank"), Qtrue);
    VALUE payload = RARRAY_AREF(header, 0);
    VALUE blocks = Qnil;
    if (kind == 1) {
        blocks = rb_ary_new_from_args(1, payload);
        rb_ivar_set(tag, rb_intern("@blocks"), blocks);
    } else {
        rb_ivar_set(tag, rb_intern("@from"), Qnil);
        rb_ivar_set(tag, rb_intern("@limit"), Qnil);
        native_control_for_fields(tag, payload);
    }
    if (header_gc != rb_gc_count()) {
        args->guard->valid = false;
        rb_funcall(tag, rb_intern("initialize"), 3, name, markup, args->parse_context);
        rb_funcallv_public(tag, intern_parse, 1, &context->tokenizer_obj);
        RB_GC_GUARD(header);
        return tag;
    }
    native_control_commit(args, header);
    VALUE body;
    if (kind == 1) {
        body = control_new_body(tag, args);
        native_control_attach(args, payload, body);
        while (control_parse_segment(tag, body, args, context)) {
            blocks = rb_ivar_get(tag, rb_intern("@blocks"));
            if (native_control_guard(args) && CLASS_OF(blocks) == rb_cArray && RARRAY_LEN(blocks) &&
                native_control_condition(RARRAY_AREF(blocks, RARRAY_LEN(blocks) - 1))) {
                body = rb_ivar_get(RARRAY_AREF(blocks, RARRAY_LEN(blocks) - 1), rb_intern("@attachment"));
            } else {
                args->guard->valid = false;
                VALUE last = rb_funcallv_public(blocks, rb_intern("last"), 0, NULL);
                body = rb_funcallv_public(last, rb_intern("attachment"), 0, NULL);
            }
        }
    } else {
        body = control_new_body(tag, args);
        rb_ivar_set(tag, rb_intern("@for_block"), body);
        rb_ivar_set(tag, rb_intern("@else_block"), Qnil);
        if (control_parse_segment(tag, body, args, context))
            control_parse_segment(tag, rb_ivar_get(tag, rb_intern("@else_block")), args, context);
    }
    // Verify the attachment graph before finishing the standard parse.
    bool ordinary = control_interval_current(args) && native_control_kind(CLASS_OF(tag)) == kind;
    if (ordinary && kind == 1) {
        VALUE blocks = rb_ivar_get(tag, rb_intern("@blocks"));
        ordinary = CLASS_OF(blocks) == rb_cArray;
        for (long i = 0; ordinary && i < RARRAY_LEN(blocks); i++) {
            VALUE condition = RARRAY_AREF(blocks, i);
            ordinary = native_control_condition(condition) &&
                CLASS_OF(rb_ivar_get(condition, rb_intern("@attachment"))) == native_block_body_class;
        }
    } else if (ordinary) {
        VALUE otherwise = rb_ivar_get(tag, rb_intern("@else_block"));
        ordinary = CLASS_OF(rb_ivar_get(tag, rb_intern("@for_block"))) == native_block_body_class &&
            (NIL_P(otherwise) || CLASS_OF(otherwise) == native_block_body_class);
    }
    if (!ordinary) args->guard->valid = false;
    native_control_finish(args, tag, kind);
    if (args->guard->gc_count != rb_gc_count()) args->guard->valid = false;
    RB_GC_GUARD(header);
    RB_GC_GUARD(body);
    return tag;
}

static VALUE block_body_render_to_output_buffer(VALUE self, VALUE context, VALUE output)
{
    Check_Type(output, T_STRING);

    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_body_compiled(body);
    document_body_entry_t *entry = &body->as.compiled.document_body_entry;
    document_body_ensure_compile_finished(entry->body);

    liquid_vm_render(document_body_get_block_body_header_ptr(entry), document_body_get_constants_ptr(entry), context, output, &body->as.compiled.nodelist);
    return output;
}

static VALUE block_body_blank_p(VALUE self)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    if (body->compiled) {
        block_body_header_t *body_header = document_body_get_block_body_header_ptr(&body->as.compiled.document_body_entry);
        return BLOCK_BODY_HEADER_BLANK_P(body_header) ? Qtrue : Qfalse;
    } else {
        return body->as.intermediate.blank ? Qtrue : Qfalse;
    }
}

static VALUE block_body_remove_blank_strings(VALUE self)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);

    ensure_intermediate_not_parsing(self, body);

    if (!body->as.intermediate.blank) {
        rb_raise(rb_eRuntimeError, "remove_blank_strings only support being called on a blank block body");
    }

    uint8_t *ip = body->as.intermediate.code->instructions.data;

    while (*ip != OP_LEAVE) {
        if (*ip == OP_WRITE_RAW) {
            if (ip[1]) { // if (size != 0)
                ip[0] = OP_JUMP_FWD; // effectively a no-op
                body->as.intermediate.render_score--;
            }
        } else if (*ip == OP_WRITE_RAW_W) {
            if (ip[1] || ip[2] || ip[3]) { // if (size != 0)
                ip[0] = OP_JUMP_FWD_W; // effectively a no-op
                body->as.intermediate.render_score--;
            }
        }
        liquid_vm_next_instruction((const uint8_t **)&ip);
    }

    return Qnil;
}

// Deprecated: avoid using this for the love of performance
static VALUE block_body_nodelist(VALUE self)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_body_compiled(body);
    document_body_entry_t *entry = &body->as.compiled.document_body_entry;
    block_body_header_t *body_header = document_body_get_block_body_header_ptr(entry);

    if (body->as.compiled.nodelist != Qundef)
        return body->as.compiled.nodelist;

    VALUE nodelist = rb_ary_new_capa(body_header->render_score);

    const VALUE *constants = &entry->body->constants;
    const uint8_t *ip = block_body_instructions_ptr(body_header);
    while (true) {
        switch (*ip) {
            case OP_LEAVE:
                goto loop_break;
            case OP_WRITE_RAW_W:
            case OP_WRITE_RAW:
            {
                const char *text;
                size_t size;
                if (*ip == OP_WRITE_RAW_W) {
                    size = bytes_to_uint24(&ip[1]);
                    text = (const char *)&ip[4];
                } else {
                    size = ip[1];
                    text = (const char *)&ip[2];
                }
                VALUE string = rb_enc_str_new(text, size, utf8_encoding);
                rb_ary_push(nodelist, string);
                break;
            }
            case OP_WRITE_NODE:
            {
                uint32_t constant_index = bytes_to_uint32(ip + 1);
                VALUE node = RARRAY_AREF(*constants, body_header->constants_offset + constant_index);
                rb_ary_push(nodelist, node);
                break;
            }

            case OP_RENDER_VARIABLE_RESCUE:
            case OP_RENDER_VARIABLE_RESCUE_W:
            {
                size_t line_size = *ip == OP_RENDER_VARIABLE_RESCUE_W ? 4 : VM_VARIABLE_LINE_NUMBER_SIZE;
                uint32_t variable_index = bytes_to_uint32(ip + 1 + line_size);
                VALUE variable = RARRAY_AREF(*constants, body_header->constants_offset + variable_index);
                rb_ary_push(nodelist, variable_materialize(variable));
                break;
            }
        }
        liquid_vm_next_instruction(&ip);
    }
loop_break:

    rb_ary_freeze(nodelist);
    body->as.compiled.nodelist = nodelist;
    return nodelist;
}

static VALUE block_body_disassemble(VALUE self)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_body_compiled(body);
    document_body_entry_t *entry = &body->as.compiled.document_body_entry;
    document_body_ensure_compile_finished(entry->body);
    block_body_header_t *header = document_body_get_block_body_header_ptr(entry);
    const uint8_t *start_ip = block_body_instructions_ptr(header);
    return vm_assembler_disassemble(
        start_ip,
        start_ip + header->instructions_bytes,
        &entry->body->constants,
        header->constants_offset
    );
}

static VALUE block_body_add_evaluate_expression(VALUE self, VALUE expression)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_intermediate(self, body);
    vm_assembler_add_evaluate_expression_from_ruby(body->as.intermediate.code, self, expression);
    return self;
}

static VALUE block_body_add_find_variable(VALUE self, VALUE expression)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_intermediate(self, body);
    vm_assembler_add_find_variable_from_ruby(body->as.intermediate.code, self, expression);
    return self;
}

static VALUE block_body_add_lookup_guard(VALUE self)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_intermediate(self, body);
    return SIZET2NUM(vm_assembler_add_lookup_guard(body->as.intermediate.code));
}

static VALUE block_body_patch_lookup_guard(VALUE self, VALUE offset)
{
    size_t guard_offset = NUM2SIZET(offset);
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_intermediate(self, body);
    vm_assembler_patch_lookup_guard(body->as.intermediate.code, guard_offset);
    return self;
}

static VALUE block_body_add_lookup_command(VALUE self, VALUE name)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_intermediate(self, body);
    vm_assembler_add_lookup_command_from_ruby(body->as.intermediate.code, name);
    return self;
}

static VALUE block_body_add_lookup_key(VALUE self, VALUE expression)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_intermediate(self, body);
    vm_assembler_add_lookup_key_from_ruby(body->as.intermediate.code, self, expression);
    return self;
}

static VALUE block_body_add_new_int_range(VALUE self)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_intermediate(self, body);
    vm_assembler_add_new_int_range_from_ruby(body->as.intermediate.code);
    return self;
}

static VALUE block_body_add_hash_new(VALUE self, VALUE hash_size)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_intermediate(self, body);
    vm_assembler_add_hash_new_from_ruby(body->as.intermediate.code, hash_size);
    return self;
}

static VALUE block_body_add_filter(VALUE self, VALUE filter_name, VALUE num_args)
{
    block_body_t *body;
    BlockBody_Get_Struct(self, body);
    ensure_intermediate(self, body);
    vm_assembler_add_filter_from_ruby(body->as.intermediate.code, filter_name, num_args);
    return self;
}

void liquid_define_block_body(void)
{
    intern_raise_missing_variable_terminator = rb_intern("raise_missing_variable_terminator");
    intern_raise_missing_tag_terminator = rb_intern("raise_missing_tag_terminator");
    intern_is_blank = rb_intern("blank?");
    intern_parse = rb_intern("parse");
    intern_unknown_tag_in_liquid_tag = rb_intern("unknown_tag_in_liquid_tag");

    VALUE cLiquidCBlockBody = rb_define_class_under(mLiquidC, "BlockBody", rb_cObject);
    native_block_body_class = cLiquidCBlockBody;
    rb_global_variable(&native_block_body_class);
    rb_define_alloc_func(cLiquidCBlockBody, block_body_allocate);

    rb_define_method(cLiquidCBlockBody, "initialize", block_body_initialize, 1);
    rb_define_private_method(cLiquidCBlockBody, "initialize_copy", block_body_initialize_copy, 1);
    rb_define_method(cLiquidCBlockBody, "parse", block_body_parse, 2);
    rb_define_method(cLiquidCBlockBody, "freeze", block_body_freeze, 0);
    rb_define_method(cLiquidCBlockBody, "render_to_output_buffer", block_body_render_to_output_buffer, 2);
    rb_define_method(cLiquidCBlockBody, "remove_blank_strings", block_body_remove_blank_strings, 0);
    rb_define_method(cLiquidCBlockBody, "blank?", block_body_blank_p, 0);
    rb_define_method(cLiquidCBlockBody, "nodelist", block_body_nodelist, 0);
    rb_define_method(cLiquidCBlockBody, "disassemble", block_body_disassemble, 0);

    rb_define_method(cLiquidCBlockBody, "add_evaluate_expression", block_body_add_evaluate_expression, 1);
    rb_define_method(cLiquidCBlockBody, "add_find_variable", block_body_add_find_variable, 1);
    rb_define_method(cLiquidCBlockBody, "add_lookup_guard", block_body_add_lookup_guard, 0);
    rb_define_method(cLiquidCBlockBody, "patch_lookup_guard", block_body_patch_lookup_guard, 1);
    rb_define_method(cLiquidCBlockBody, "add_lookup_command", block_body_add_lookup_command, 1);
    rb_define_method(cLiquidCBlockBody, "add_lookup_key", block_body_add_lookup_key, 1);
    rb_define_method(cLiquidCBlockBody, "add_new_int_range", block_body_add_new_int_range, 0);

    rb_define_method(cLiquidCBlockBody, "add_hash_new", block_body_add_hash_new, 1);
    rb_define_method(cLiquidCBlockBody, "add_filter", block_body_add_filter, 2);
}
