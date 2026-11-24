#include "liquid.h"
#include "mri_compat.h"
#include "parser.h"
#include "document_body.h"
#include "variable.h"
#include <stdlib.h>

// This frontend is deliberately non-diagnostic. Unsupported syntax is returned
// to Liquid's parser, which owns mode-specific errors and warnings. All offsets
// refer to an owned, pinned string; no pointer survives an allocation.
typedef struct {
    VALUE source, cache, pending;
    // Conditions and fused outputs use disjoint parsing operations.
    union { VALUE condition_literals; VALUE pending_value; };
    VALUE variable_name, variable_filters;
    bool literals_checked, guarded, compact_pending;
    size_t initial_gc_count;
    size_t position, length, start, end;
    int token, operation;
    vm_assembler_t *code;
} native_parser_t;

enum { N_END = 256, N_ID, N_NUMBER, N_STRING, N_DOTDOT, N_COMPARE, N_UNSUPPORTED };

static ID id_name, id_lookups, id_commands, id_start, id_end;
static ID id_string_scanner, id_new_native, id_allocate_native;
static ID id_disabled_native, id_mode_native, id_cache_native;
static ID id_options_native, id_stats_native, id_enabled_native, id_parse_context_native, id_for_fields[6];
static VALUE native_context_class, native_case_class, native_if_class, native_unless_class, native_for_class;
static VALUE native_original_if, native_original_for;
static bool native_variable_ready;
static VALUE native_expression_class, native_parser_class, native_condition_class, native_literals, native_unbound_class;
static VALUE native_hash_readers[3];
enum { HASH_IDENTITY_READER, HASH_DEFAULT_PROC_READER, HASH_DEFAULT_READER };

#ifndef HAVE_RB_AUTOLOAD_P
static VALUE native_autoload_reader = Qnil;
#endif

static VALUE native_autoload_p(VALUE owner, ID name)
{
#ifdef HAVE_RB_AUTOLOAD_P
    return rb_autoload_p(owner, name);
#else
    if (NIL_P(native_autoload_reader)) return Qtrue;
    VALUE args[] = { owner, ID2SYM(name), Qfalse };
    return liquid_method_call(3, args, native_autoload_reader);
#endif
}

// Stored builtin bodies read Hash metadata without invoking application
// overrides. Public Method APIs avoid depending on MRI's Hash layout.
static VALUE native_hash_property(VALUE hash, size_t reader)
{
    if (CLASS_OF(hash) != rb_cHash) return Qundef;
#ifdef HAVE_RB_HASH_COMPARE_BY_ID_P
    if (reader == HASH_IDENTITY_READER) return rb_hash_compare_by_id_p(hash);
#endif
    if (NIL_P(native_hash_readers[reader])) return Qundef;
    return liquid_method_call(1, &hash, native_hash_readers[reader]);
}

static bool native_normal_hash(VALUE hash)
{
    size_t before = liquid_gc_count();
    VALUE identity = native_hash_property(hash, HASH_IDENTITY_READER);
    return identity == Qfalse && liquid_gc_count() == before;
}

static VALUE native_capture_constant(VALUE owner, const char *name)
{
    ID id = rb_intern(name);
    if (!RB_TYPE_P(owner, T_CLASS) && !RB_TYPE_P(owner, T_MODULE)) return Qnil;
    if (!rb_const_defined_at(owner, id) || RTEST(native_autoload_p(owner, id))) return Qnil;
    return rb_const_get_at(owner, id);
}

typedef struct { VALUE owner; ID method; bool public_call; } primitive_guard_t;
static primitive_guard_t primitive_guards[96];
static size_t primitive_guard_count;

static void native_guard_primitive(VALUE owner, const char *method)
{
    if (primitive_guard_count >= sizeof(primitive_guards) / sizeof(primitive_guards[0]))
        rb_raise(rb_eRuntimeError, "too many native primitive guards");
    primitive_guard_t *guard = &primitive_guards[primitive_guard_count++];
    guard->owner = owner;
    guard->method = rb_intern(method);
    guard->public_call = strcmp(method, "initialize_copy") && strcmp(method, "initialize_dup");
}

static bool native_primitives_standard(bool check_visibility)
{
    for (size_t i = 0; i < primitive_guard_count; i++) {
        const primitive_guard_t *guard = &primitive_guards[i];
        if (!liquid_method_basic_definition_p(guard->owner, guard->method)) return false;
        if (check_visibility && guard->public_call && rb_method_boundp(guard->owner, guard->method, 3) != 1) return false;
    }
    return true;
}

static VALUE native_public_method(VALUE self, VALUE receiver, VALUE name)
{
    return rb_method_boundp(CLASS_OF(receiver), SYM2ID(name), 3) == 1 ? Qtrue : Qfalse;
}

static bool native_snapshot_matches(VALUE value, VALUE snapshot)
{
    if (NIL_P(snapshot)) return true;
    if (!RB_TYPE_P(value, T_ARRAY) || !RB_TYPE_P(snapshot, T_ARRAY) || RARRAY_LEN(value) != RARRAY_LEN(snapshot)) return false;
    for (long i = 0; i < RARRAY_LEN(snapshot); i++)
        if (RARRAY_AREF(value, i) != RARRAY_AREF(snapshot, i)) return false;
    return true;
}

static VALUE native_constant_matches(VALUE self, VALUE owner, VALUE name, VALUE expected, VALUE snapshot)
{
    if (!RB_TYPE_P(owner, T_CLASS) && !RB_TYPE_P(owner, T_MODULE)) return Qfalse;
    Check_Type(name, T_SYMBOL);
    ID id = SYM2ID(name);
    if (!rb_const_defined_at(owner, id) || RTEST(native_autoload_p(owner, id)) || rb_const_get_at(owner, id) != expected) return Qfalse;
    return native_snapshot_matches(expected, snapshot) ? Qtrue : Qfalse;
}

// Public reflection is portable but expensive. Amortize it only over complex
// expressions on Rubies which do not export the optional opaque method API.
static VALUE native_frontend_candidate(VALUE self, VALUE markup)
{
    if (!RB_TYPE_P(markup, T_STRING) || RSTRING_LEN(markup) < 1024) return Qfalse;
    const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(markup);
    size_t count = 0;
    unsigned char quote = 0;
    for (long i = 0; i < RSTRING_LEN(markup); i++) {
        unsigned char c = bytes[i];
        if (quote) { if (c == quote) quote = 0; continue; }
        if (c == '\'' || c == '"') { quote = c; continue; }
        if (c == '.' || c == '[' || c == '|' || c == ',') {
            if (++count >= 128) return Qtrue;
        }
    }
    return Qfalse;
}


static bool native_conversion_is_standard(VALUE value)
{
    VALUE klass = CLASS_OF(value);
    if (!liquid_method_basic_definition_p(klass, rb_intern("respond_to?")) ||
        !liquid_method_basic_definition_p(klass, rb_intern("respond_to_missing?")) ||
        rb_method_boundp(klass, id_evaluate, 0)) return false;
    if (liquid_method_basic_definition_p(klass, rb_intern("to_i"))) return true;
    return false;
}

static bool native_space(unsigned char c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
}

static bool native_alpha(unsigned char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

static bool native_digit(unsigned char c) { return c >= '0' && c <= '9'; }

static void native_next(native_parser_t *p)
{
    const unsigned char *s = (const unsigned char *)RSTRING_PTR(p->source);
    size_t i = p->position, n = p->length;
    while (i < n && native_space(s[i])) i++;
    p->start = i;
    if (i == n) { p->token = N_END; p->end = i; return; }
    unsigned char c = s[i++];
    p->token = c;
    if (native_alpha(c)) {
        while (i < n && (native_alpha(s[i]) || native_digit(s[i]) || s[i] == '-')) i++;
        if (i < n && s[i] == '?') i++;
        p->token = N_ID;
    } else if (native_digit(c) || (c == '-' && i < n && native_digit(s[i]))) {
        while (i < n && native_digit(s[i])) i++;
        if (i + 1 < n && s[i] == '.' && native_digit(s[i + 1])) {
            i++;
            while (i < n && native_digit(s[i])) i++;
        }
        p->token = N_NUMBER;
    } else if (c == '\'' || c == '"') {
        while (i < n && s[i] != c) i++;
        if (i == n) p->token = N_UNSUPPORTED;
        else { i++; p->token = N_STRING; }
    } else if (c == '.' && i < n && s[i] == '.') {
        i++;
        p->token = N_DOTDOT;
    } else if (c == '<' || c == '>' || c == '=' || c == '!') {
        if (i < n && (s[i] == '=' || (c == '<' && s[i] == '>'))) {
            i++;
            p->token = N_COMPARE;
        } else p->token = c == '<' || c == '>' ? N_COMPARE : N_UNSUPPORTED;
    } else if (c != '.' && c != '[' && c != ']' && c != '(' && c != ')' &&
               c != '|' && c != ':' && c != ',') p->token = N_UNSUPPORTED;
    p->end = p->position = i;
}

static VALUE native_slice(native_parser_t *p, size_t start, size_t end)
{
    return rb_enc_str_new(RSTRING_PTR(p->source) + start, (long)(end - start), utf8_encoding);
}

static bool native_word_bytes(native_parser_t *p, const char *word, size_t length)
{
    return p->end - p->start == length && !memcmp(RSTRING_PTR(p->source) + p->start, word, length);
}

// Every keyword at these call sites is a string literal. Keep its length at
// the call site even when the compiler chooses not to inline the comparison.
#define native_word(parser, literal) native_word_bytes((parser), (literal), sizeof(literal) - 1)

static VALUE native_key(native_parser_t *p, size_t start, size_t end)
{
    VALUE key = rb_str_new(NULL, (long)(end - start));
    // Reserve once, then copy without allocating while a pointer is in use.
    char *out = RSTRING_PTR(key);
    const char *source = RSTRING_PTR(p->source);
    size_t written = 0;
    char quote = 0;
    for (size_t i = start; i < end; i++) {
        char c = source[i];
        if (quote || !native_space((unsigned char)c)) out[written++] = c;
        if (quote == c) quote = 0;
        else if (!quote && (c == '\'' || c == '"')) quote = c;
    }
    rb_str_set_len(key, (long)written);
    rb_enc_associate(key, utf8_encoding);
    return key;
}

// A finalizer can redefine a guarded method during allocation. Drop the pending
// parse before publishing cache entries or bytecode based on the old definition.
static bool native_gc_changed(const native_parser_t *p)
{
    return p->guarded && p->initial_gc_count != liquid_gc_count();
}

static VALUE native_pending_lookup(const native_parser_t *p, VALUE key)
{
    if (NIL_P(p->pending)) return Qundef;
    if (p->compact_pending && RB_TYPE_P(p->pending, T_STRING)) {
        if (RSTRING_LEN(key) == RSTRING_LEN(p->pending) &&
            !memcmp(RSTRING_PTR(key), RSTRING_PTR(p->pending), (size_t)RSTRING_LEN(key))) return p->pending_value;
        return Qundef;
    }
    return rb_hash_lookup2(p->pending, key, Qundef);
}

static VALUE native_cached(native_parser_t *p, size_t start, size_t end, VALUE value, VALUE cache_key)
{
    if (native_gc_changed(p)) return Qundef;
    rb_obj_freeze(value);
    if (NIL_P(p->cache)) return value;
    VALUE key = NIL_P(cache_key) ? native_key(p, start, end) : cache_key;
    if (native_gc_changed(p)) return Qundef;
    VALUE previous = rb_hash_lookup2(p->cache, key, Qundef);
    if (previous != Qundef) return previous;
    previous = native_pending_lookup(p, key);
    if (previous != Qundef) return previous;
    rb_obj_freeze(key);
    // Most fused outputs introduce one cache entry. Keep its key and value
    // on the parser stack; promote to a Hash for multiple distinct entries.
    if (p->compact_pending && NIL_P(p->pending)) {
        p->pending = key;
        p->pending_value = value;
        return value;
    }
    if (NIL_P(p->pending) || (p->compact_pending && RB_TYPE_P(p->pending, T_STRING))) {
        VALUE previous_key = p->pending;
        p->pending = rb_hash_new();
        if (!NIL_P(previous_key)) {
            if (native_gc_changed(p)) return Qundef;
            rb_hash_aset(p->pending, previous_key, p->pending_value);
        }
        RB_GC_GUARD(previous_key);
    }
    if (native_gc_changed(p)) return Qundef;
    rb_hash_aset(p->pending, key, value);
    return value;
}

static VALUE native_object_alloc(VALUE klass)
{
    if (rb_get_alloc_func(klass) != rb_get_alloc_func(rb_cObject)) return Qundef;
    return rb_obj_alloc(klass);
}

// Cached expressions retain their identity and may have been edited by a tag.
// Only the ordinary, currently guarded expression classes can be inlined.
static bool native_compile_cached(vm_assembler_t *code, VALUE value, size_t gc)
{
    if (gc != liquid_gc_count()) return false;
    if (liquid_stack_check()) rb_raise(rb_eSysStackError, "stack level too deep");
    if (CLASS_OF(value) == cLiquidVariableLookup) {
        VALUE name = rb_ivar_get(value, id_name);
        VALUE lookups = rb_ivar_get(value, id_lookups);
        VALUE commands = rb_ivar_get(value, id_commands);
        if (CLASS_OF(lookups) != rb_cArray || !RB_FIXNUM_P(commands) || RARRAY_LEN(lookups) > 60 || RARRAY_LEN(lookups) > (long)(sizeof(unsigned long) * CHAR_BIT)) return false;
        if (CLASS_OF(name) == rb_cString) vm_assembler_add_find_static_variable(code, name);
        else {
            if (!native_compile_cached(code, name, gc)) return false;
            vm_assembler_add_find_variable(code);
        }
        size_t guards[60];
        long count = RARRAY_LEN(lookups);
        for (long i = 0; i < count; i++) {
            if (gc != liquid_gc_count()) return false;
            VALUE key = RARRAY_AREF(lookups, i);
            if (((unsigned long)FIX2LONG(commands) >> i) & 1) {
                if (CLASS_OF(key) != rb_cString) return false;
                vm_assembler_add_lookup_command(code, key);
            } else if (CLASS_OF(key) == rb_cString) vm_assembler_add_lookup_const_key(code, key);
            else {
                if (!native_compile_cached(code, key, gc)) return false;
                vm_assembler_add_lookup_key(code);
            }
            if (i + 1 < count) guards[i] = vm_assembler_add_lookup_guard(code);
        }
        for (long i = 0; i + 1 < count; i++) vm_assembler_patch_lookup_guard(code, guards[i]);
        return true;
    }
    if (CLASS_OF(value) == cLiquidRangeLookup) {
        if (!native_compile_cached(code, rb_ivar_get(value, id_start), gc) ||
            !native_compile_cached(code, rb_ivar_get(value, id_end), gc)) return false;
        vm_assembler_add_new_int_range(code);
        return true;
    }
    if (NIL_P(value) || value == Qtrue || value == Qfalse || RB_INTEGER_TYPE_P(value) ||
        CLASS_OF(value) == rb_cString || CLASS_OF(value) == rb_cFloat || CLASS_OF(value) == rb_cRange) {
        // A cached literal with an evaluate/compile hook is observable too.
        if (rb_method_boundp(CLASS_OF(value), id_compile_evaluate, 0) ||
            rb_method_boundp(CLASS_OF(value), id_evaluate, 0)) return false;
        vm_assembler_add_push_literal(code, value);
        return true;
    }
    return false;
}

static VALUE native_expression(native_parser_t *p);

static bool native_validate_expression(native_parser_t *p)
{
    if (liquid_stack_check()) {
        if (p->code) return false;
        rb_raise(rb_eSysStackError, "stack level too deep");
    }
    if (p->token == N_NUMBER || p->token == N_STRING) { native_next(p); return true; }
    if (p->token == '(') {
        native_next(p);
        if (!native_validate_expression(p) || p->token != N_DOTDOT) return false;
        native_next(p);
        if (!native_validate_expression(p) || p->token != ')') return false;
        native_next(p);
        return true;
    }
    if (p->token == N_ID) {
        if (native_word(p, "contains")) return false;
        native_next(p);
    } else if (p->token == '[') {
        native_next(p);
        if (!native_validate_expression(p) || p->token != ']') return false;
        native_next(p);
    } else return false;
    size_t lookups = 0;
    while (p->token == '.' || p->token == '[') {
        if (p->code && ++lookups > 60) return false;
        bool dot = p->token == '.';
        native_next(p);
        if (dot) {
            if (p->token != N_ID) return false;
        } else if (!native_validate_expression(p) || p->token != ']') return false;
        native_next(p);
    }
    return true;
}

static bool native_validate_variable(native_parser_t *p, native_parser_t *name)
{
    native_next(p);
    if (p->token != N_END && !native_validate_expression(p)) return false;
    if (name) *name = *p;
    while (p->token == '|') {
        native_next(p);
        if (p->token != N_ID || native_word(p, "contains")) return false;
        native_next(p);
        if (p->token == ':') {
            native_next(p);
            while (true) {
                if (p->token == N_ID) {
                    native_parser_t saved = *p;
                    native_next(p);
                    if (p->token == ':') native_next(p);
                    else *p = saved;
                }
                if (!native_validate_expression(p)) return false;
                if (p->token != ',') break;
                native_next(p);
            }
        }
    }
    return p->token == N_END;
}

static VALUE native_expression_probed(native_parser_t *p, const native_parser_t *validated, VALUE cache_key);

static VALUE native_expression(native_parser_t *p)
{
    return native_expression_probed(p, NULL, Qnil);
}

static VALUE native_expression_probed(native_parser_t *p, const native_parser_t *validated, VALUE cache_key)
{
    if (liquid_stack_check()) rb_raise(rb_eSysStackError, "stack level too deep");
    size_t start = p->start;
    if (!NIL_P(p->cache) && (p->token == N_ID || p->token == N_NUMBER || p->token == '(' || p->token == '[')) {
        bool literal = p->token == N_ID && (native_word(p, "nil") || native_word(p, "null") ||
            native_word(p, "true") || native_word(p, "false") || native_word(p, "blank") || native_word(p, "empty"));
        if (!literal) {
            native_parser_t probe = validated ? *validated : *p;
            if (validated || native_validate_expression(&probe)) {
                VALUE key = NIL_P(cache_key) ? native_key(p, start, probe.start) : cache_key;
                cache_key = key;
                if (native_gc_changed(p)) return Qundef;
                VALUE found = rb_hash_lookup2(p->cache, key, Qundef);
                if (found == Qundef) found = native_pending_lookup(p, key);
                if (found != Qundef) {
                    if (p->code && !native_compile_cached(p->code, found, p->initial_gc_count)) return Qundef;
                    *p = probe;
                    return found;
                }
            }
        }
    }
    if (p->token == N_STRING) {
        VALUE value = native_slice(p, start + 1, p->end - 1);
        native_next(p);
        if (p->code) vm_assembler_add_push_literal(p->code, value);
        return value;
    }
    if (p->token == N_NUMBER) {
        VALUE text = native_slice(p, start, p->end);
        bool floating = memchr(RSTRING_PTR(text), '.', RSTRING_LEN(text)) != NULL;
        if (floating && RSTRING_LEN(text) > 64) return Qundef;
        if (!floating && !liquid_method_basic_definition_p(
            CLASS_OF(native_expression_class), rb_intern("Integer"))) return Qundef;
        VALUE value = floating ?
            DBL2NUM(liquid_str_to_dbl(text, 1)) : rb_str_to_inum(text, 10, 1);
        size_t end = p->end;
        native_next(p);
        value = native_cached(p, start, end, value, cache_key);
        if (value == Qundef) return Qundef;
        if (p->code && !native_compile_cached(p->code, value, p->initial_gc_count)) return Qundef;
        return value;
    }
    if (p->token == '(') {
        vm_assembler_t *code = p->code;
        p->code = NULL;
        native_next(p);
        VALUE first = native_expression(p);
        if (first == Qundef || p->token != N_DOTDOT) return Qundef;
        native_next(p);
        VALUE last = native_expression(p);
        if (last == Qundef || p->token != ')') return Qundef;
        size_t end = p->end;
        native_next(p);
        VALUE range;
        if (rb_obj_is_kind_of(first, cLiquidVariableLookup) || rb_obj_is_kind_of(first, cLiquidRangeLookup) ||
            rb_obj_is_kind_of(last, cLiquidVariableLookup) || rb_obj_is_kind_of(last, cLiquidRangeLookup)) {
            if (!liquid_method_basic_definition_p(CLASS_OF(first), rb_intern("respond_to?")) ||
                !liquid_method_basic_definition_p(CLASS_OF(last), rb_intern("respond_to?"))) return Qundef;
            bool first_evaluates = rb_method_boundp(CLASS_OF(first), id_evaluate, 1);
            bool last_evaluates = rb_method_boundp(CLASS_OF(last), id_evaluate, 1);
            if (!first_evaluates && !last_evaluates) return Qundef;
            if (!first_evaluates && !liquid_method_basic_definition_p(CLASS_OF(first), rb_intern("respond_to_missing?"))) return Qundef;
            range = rb_obj_alloc(cLiquidRangeLookup);
            rb_ivar_set(range, id_start, first);
            rb_ivar_set(range, id_end, last);
        } else if ((RB_INTEGER_TYPE_P(first) || RB_TYPE_P(first, T_FLOAT) || RB_TYPE_P(first, T_STRING)) &&
                   (RB_INTEGER_TYPE_P(last) || RB_TYPE_P(last, T_FLOAT) || RB_TYPE_P(last, T_STRING))) {
            if (!native_conversion_is_standard(first) || !native_conversion_is_standard(last)) return Qundef;
            VALUE begin = RB_INTEGER_TYPE_P(first) ? first : (RB_TYPE_P(first, T_STRING) ?
                rb_str_to_inum(first, 10, 0) : rb_dbl2big(RFLOAT_VALUE(first)));
            VALUE end_value = RB_INTEGER_TYPE_P(last) ? last : (RB_TYPE_P(last, T_STRING) ?
                rb_str_to_inum(last, 10, 0) : rb_dbl2big(RFLOAT_VALUE(last)));
            range = rb_range_new(begin, end_value, false);
        } else return Qundef;
        range = native_cached(p, start, end, range, cache_key);
        p->code = code;
        if (range == Qundef) return Qundef;
        if (code && !native_compile_cached(code, range, p->initial_gc_count)) return Qundef;
        return range;
    }
    VALUE name;
    bool literal = false;
    VALUE literal_value = Qnil;
    if (p->token == N_ID) {
        if (native_word(p, "contains")) return Qundef;
        if (native_word(p, "nil") || native_word(p, "null")) literal = true;
        else if (native_word(p, "true")) { literal = true; literal_value = Qtrue; }
        else if (native_word(p, "false")) { literal = true; literal_value = Qfalse; }
        else if (native_word(p, "blank") || native_word(p, "empty")) {
            literal = true;
            VALUE literals = native_literals;
            if (!RB_TYPE_P(literals, T_HASH)) return Qundef;
            literal_value = rb_hash_lookup2(literals, native_slice(p, start, p->end), Qundef);
            if (literal_value == Qundef) return Qundef;
        }
        name = native_slice(p, start, p->end);
        native_next(p);
        if (literal && p->token != '.' && p->token != '[') {
            if (p->code && !native_compile_cached(p->code, literal_value, p->initial_gc_count)) return Qundef;
            return literal_value;
        }
        if (p->code) vm_assembler_add_find_static_variable(p->code, name);
    } else if (p->token == '[') {
        native_next(p);
        name = native_expression(p);
        if (name == Qundef || p->token != ']') return Qundef;
        native_next(p);
        if (p->code) vm_assembler_add_find_variable(p->code);
    } else return Qundef;

    VALUE lookups = rb_ary_new();
    VALUE commands = INT2FIX(0);
    size_t guards[60], guard_count = 0;
    while (p->token == '.' || p->token == '[') {
        bool command = p->token == '.';
        bool command_key = false;
        native_next(p);
        VALUE key;
        if (command) {
            if (p->token != N_ID) return Qundef;
            if (native_word(p, "size") || native_word(p, "first") || native_word(p, "last")) {
                command_key = true;
                size_t index = (size_t)RARRAY_LEN(lookups);
                VALUE bit = index < sizeof(unsigned long) * CHAR_BIT - 2 ? ULONG2NUM(1UL << index) :
                    liquid_big_lshift(rb_uint2big(1), SIZET2NUM(index));
                if (RB_FIXNUM_P(commands) && RB_FIXNUM_P(bit)) commands = LONG2FIX(FIX2LONG(commands) | FIX2LONG(bit));
                else commands = liquid_big_or(RB_FIXNUM_P(commands) ? rb_int2big(FIX2LONG(commands)) : commands, bit);
            }
            key = native_slice(p, p->start, p->end);
            native_next(p);
            if (p->code) {
                if (command_key) vm_assembler_add_lookup_command(p->code, key);
                else vm_assembler_add_lookup_const_key(p->code, key);
            }
        } else {
            key = native_expression(p);
            if (key == Qundef || p->token != ']') return Qundef;
            native_next(p);
            if (p->code) vm_assembler_add_lookup_key(p->code);
        }
        rb_ary_push(lookups, key);
        if (p->code && (p->token == '.' || p->token == '[')) {
            if (guard_count == 60) return Qundef;
            guards[guard_count++] = vm_assembler_add_lookup_guard(p->code);
        }
    }
    if (p->code)
        for (size_t i = 0; i < guard_count; i++) vm_assembler_patch_lookup_guard(p->code, guards[i]);
    VALUE value = rb_obj_alloc(cLiquidVariableLookup);
    rb_ivar_set(value, id_name, name);
    rb_ivar_set(value, id_lookups, lookups);
    rb_ivar_set(value, id_commands, commands);
    return native_cached(p, start, p->start, value, cache_key);
}

static bool native_comparison(native_parser_t *p)
{
    return p->token == N_COMPARE || (p->token == N_ID && native_word(p, "contains"));
}

static bool native_validate_comparison(native_parser_t *p)
{
    if (!native_validate_expression(p)) return false;
    if (native_comparison(p)) {
        native_next(p);
        if (!native_validate_expression(p)) return false;
    }
    return true;
}

static int native_cache_key(VALUE key, VALUE value, VALUE opaque)
{
    if (!RB_TYPE_P(key, T_STRING) || CLASS_OF(key) != rb_cString) {
        *(bool *)opaque = false;
        return ST_STOP;
    }
    return ST_CONTINUE;
}

static bool native_string_cache(VALUE cache)
{
    if (!native_normal_hash(cache)) return false;
    bool safe = true;
    rb_hash_foreach(cache, native_cache_key, (VALUE)&safe);
    return safe;
}

static VALUE native_condition_expression(native_parser_t *p)
{
    native_parser_t probe = *p;
    if (!native_validate_expression(&probe)) return Qundef;
    VALUE literals = p->condition_literals;
    if (!p->literals_checked) {
        VALUE condition = native_condition_class;
        if (!rb_cvar_defined(condition, rb_intern("@@method_literals"))) return Qundef;
        literals = rb_cvar_get(condition, rb_intern("@@method_literals"));
        if (!native_string_cache(literals) || !liquid_method_basic_definition_p(rb_cHash, rb_intern("[]"))) return Qundef;
        VALUE default_proc = native_hash_property(literals, HASH_DEFAULT_PROC_READER);
        VALUE default_value = native_hash_property(literals, HASH_DEFAULT_READER);
        if (!NIL_P(default_proc) || !NIL_P(default_value)) return Qundef;
        p->condition_literals = literals;
        p->literals_checked = true;
    }
    probe.condition_literals = p->condition_literals;
    probe.literals_checked = p->literals_checked;
    VALUE key = native_key(p, p->start, probe.start);
    if (liquid_gc_count() != p->initial_gc_count) return Qundef;
    VALUE literal = rb_hash_lookup2(literals, key, Qnil);
    if (RTEST(literal)) { *p = probe; return literal; }
    return native_expression_probed(p, &probe, key);
}

static VALUE native_condition_node(native_parser_t *p)
{
    VALUE left = native_condition_expression(p), right = Qnil, op = Qnil;
    if (left == Qundef) return Qundef;
    if (native_comparison(p)) {
        op = rb_str_to_interned_str(native_slice(p, p->start, p->end));
        native_next(p);
        right = native_condition_expression(p);
        if (right == Qundef) return Qundef;
    }
    VALUE node = native_object_alloc(native_condition_class);
    if (node == Qundef) return Qundef;
    rb_ivar_set(node, rb_intern("@left"), left);
    rb_ivar_set(node, rb_intern("@operator"), op);
    rb_ivar_set(node, rb_intern("@right"), right);
    rb_ivar_set(node, rb_intern("@child_relation"), Qnil);
    rb_ivar_set(node, rb_intern("@child_condition"), Qnil);
    return node;
}

static VALUE native_condition_body(native_parser_t *p)
{
    native_parser_t probe = *p;
    native_next(&probe);
    if (!native_validate_comparison(&probe)) return Qnil;
    while (probe.token == N_ID && (native_word(&probe, "and") || native_word(&probe, "or"))) {
        native_next(&probe);
        if (!native_validate_comparison(&probe)) return Qnil;
    }
    if (probe.token != N_END) return Qnil;
    if (!p->guarded) p->pending = rb_hash_new();
    native_next(p);
    VALUE root = native_condition_node(p), current = root;
    if (root == Qundef) return Qnil;
    while (p->token == N_ID && (native_word(p, "and") || native_word(p, "or"))) {
        VALUE relation = ID2SYM(rb_intern(native_word(p, "and") ? "and" : "or"));
        native_next(p);
        VALUE child = native_condition_node(p);
        if (child == Qundef) return Qnil;
        rb_ivar_set(current, rb_intern("@child_relation"), relation);
        rb_ivar_set(current, rb_intern("@child_condition"), child);
        current = child;
    }
    return rb_ary_new_from_args(2, root, p->pending);
}

static bool native_validate_for(native_parser_t *p)
{
    native_next(p);
    if (p->token != N_ID || native_word(p, "contains")) return false;
    native_next(p);
    if (p->token != N_ID || !native_word(p, "in")) return false;
    native_next(p);
    if (!native_validate_expression(p)) return false;
    if (p->token == N_ID && native_word(p, "reversed")) native_next(p);
    while (p->token == ',' || p->token == N_ID) {
        if (p->token == ',') native_next(p);
        if (p->token != N_ID || (!native_word(p, "offset") && !native_word(p, "limit"))) return false;
        native_next(p);
        if (p->token != ':') return false;
        native_next(p);
        if (!native_validate_expression(p)) return false;
    }
    return p->token == N_END;
}

static VALUE native_for_body(native_parser_t *p)
{
    native_parser_t probe = *p;
    if (!native_validate_for(&probe)) return Qnil;
    if (!p->guarded) p->pending = rb_hash_new();
    native_next(p);
    VALUE variable = native_slice(p, p->start, p->end);
    native_next(p); // in
    native_next(p);
    size_t start = p->start;
    VALUE collection = native_expression(p);
    if (collection == Qundef) return Qnil;
    VALUE markup = native_key(p, start, p->start);
    VALUE name = rb_str_dup(variable);
    rb_str_cat_cstr(name, "-");
    rb_str_append(name, markup);
    VALUE reversed = Qfalse, from = Qnil, limit = Qnil;
    if (p->token == N_ID && native_word(p, "reversed")) {
        reversed = native_slice(p, p->start, p->end);
        native_next(p);
    }
    while (p->token != N_END) {
        if (p->token == ',') native_next(p);
        bool offset = native_word(p, "offset");
        native_next(p); // colon
        native_next(p);
        VALUE value;
        probe = *p;
        bool continuation = offset && p->token == N_ID && native_word(p, "continue");
        native_next(&probe);
        if (continuation && probe.token != '.' && probe.token != '[') {
            value = ID2SYM(rb_intern("continue"));
            *p = probe;
        } else value = native_expression(p);
        if (value == Qundef) return Qnil;
        if (offset) from = value;
        else limit = value;
    }
    VALUE fields = rb_ary_new_from_args(6, variable, collection, name, reversed, from, limit);
    return rb_ary_new_from_args(2, fields, p->pending);
}

static VALUE native_single_expression_body(native_parser_t *p)
{
    native_parser_t probe = *p;
    native_next(&probe);
    if (!native_validate_expression(&probe) || probe.token != N_END) return Qnil;
    if (!p->guarded) p->pending = rb_hash_new();
    native_next(p);
    VALUE expression = native_expression(p);
    if (expression == Qundef) return Qnil;
    return rb_ary_new_from_args(2, expression, p->pending);
}

static bool native_validate_include(native_parser_t *p)
{
    native_next(p);
    if (!native_validate_expression(p)) return false;
    if (p->token == N_ID && (native_word(p, "with") || native_word(p, "for"))) {
        native_next(p);
        if (!native_validate_expression(p)) return false;
    }
    if (p->token == N_ID && native_word(p, "as")) {
        native_next(p);
        if (p->token != N_ID || native_word(p, "contains")) return false;
        native_next(p);
    }
    if (p->token == ',') native_next(p);
    while (p->token == N_ID && !native_word(p, "contains")) {
        native_next(p);
        if (p->token != ':') return false;
        native_next(p);
        if (!native_validate_expression(p)) return false;
        if (p->token == ',') native_next(p);
    }
    return p->token == N_END;
}

static VALUE native_include_body(native_parser_t *p)
{
    native_parser_t probe = *p;
    if (!native_validate_include(&probe)) return Qnil;
    native_next(p);
    VALUE template = native_expression(p);
    if (template == Qundef) return Qnil;
    VALUE variable = Qnil, alias = Qnil, is_for = Qfalse;
    bool has_variable = false;
    if (p->token == N_ID && (native_word(p, "with") || native_word(p, "for"))) {
        is_for = native_word(p, "for") ? Qtrue : Qfalse;
        has_variable = true;
        native_next(p);
        variable = native_expression(p);
        if (variable == Qundef) return Qnil;
    }
    if (p->token == N_ID && native_word(p, "as")) {
        native_next(p);
        alias = native_slice(p, p->start, p->end);
        native_next(p);
    }
    if (p->token == ',') native_next(p);
    VALUE attributes = rb_hash_new();
    while (p->token != N_END) {
        VALUE key = native_slice(p, p->start, p->end);
        native_next(p); // colon
        native_next(p);
        VALUE value = native_expression(p);
        if (value == Qundef || native_gc_changed(p)) return Qnil;
        rb_hash_aset(attributes, key, value);
        if (p->token == ',') native_next(p);
    }
    VALUE fields = rb_ary_new_from_args(6, template, variable, alias, is_for, attributes, has_variable ? Qtrue : Qfalse);
    return rb_ary_new_from_args(2, fields, p->pending);
}

#ifdef LIQUID_C_TEST_ALLOC_FAILURES
static VALUE native_parser_test_callback = Qnil;
static VALUE native_set_parser_test_callback(VALUE self, VALUE callback)
{
    if (!NIL_P(callback) && !rb_obj_is_proc(callback)) rb_raise(rb_eTypeError, "expected Proc or nil");
    native_parser_test_callback = callback;
    return callback;
}
#endif

typedef struct { vm_assembler_t *code; bool valid; size_t gc; } native_keyword_compile_t;

static int native_compile_keyword(VALUE key, VALUE value, VALUE opaque)
{
    native_keyword_compile_t *compile = (void *)opaque;
    compile->valid = native_compile_cached(compile->code, key, compile->gc) && native_compile_cached(compile->code, value, compile->gc);
    return compile->valid ? ST_CONTINUE : ST_STOP;
}

static VALUE native_variable_body_probed(VALUE opaque, const native_parser_t *validated_name)
{
#ifdef LIQUID_C_TEST_ALLOC_FAILURES
    if (!NIL_P(native_parser_test_callback)) {
        VALUE callback = native_parser_test_callback;
        native_parser_test_callback = Qnil;
        rb_proc_call(callback, rb_ary_new());
        RB_GC_GUARD(callback);
    }
#endif
    native_parser_t *p = (void *)opaque;
    if (p->operation == 1) return native_condition_body(p);
    if (p->operation == 2) return native_for_body(p);
    if (p->operation == 3) return native_single_expression_body(p);
    if (p->operation == 4) return native_include_body(p);
    native_parser_t probe = *p;
    if (!p->code && !native_validate_variable(&probe, NULL)) return Qnil;
    if (!p->code) p->pending = rb_hash_new();
    native_next(p);
    bool empty = p->token == N_END;
    VALUE name = empty ? Qnil : native_expression_probed(p, validated_name, Qnil);
    if (name == Qundef) return Qnil;
    if (p->code && empty) vm_assembler_add_push_nil(p->code);
    VALUE filters = p->code ? Qnil : rb_ary_new();
    while (p->token == '|') {
        native_next(p);
        if (p->token != N_ID || native_word(p, "contains")) return Qnil;
        VALUE filter_name;
        if (p->code) {
            // Preserve collectable symbols for names absent from the method table.
            filter_name = rb_check_symbol_cstr(RSTRING_PTR(p->source) + p->start,
                (long)(p->end - p->start), utf8_encoding);
            if (NIL_P(filter_name)) filter_name = rb_str_intern(native_slice(p, p->start, p->end));
        } else filter_name = native_slice(p, p->start, p->end);
        native_next(p);
        VALUE args = p->code ? Qnil : rb_ary_new(), kwargs = Qnil;
        long count = 0, filter_offset = 0;
        if (p->code) {
            if (NIL_P(filters)) filters = rb_ary_new();
            filter_offset = RARRAY_LEN(filters);
            rb_ary_push(filters, filter_name);
            rb_ary_push(filters, Qnil);
            rb_ary_push(filters, Qnil);
        }
        if (p->token == ':') {
            native_next(p);
            while (true) {
                VALUE keyword = Qnil;
                if (p->token == N_ID) {
                    native_parser_t saved = *p;
                    native_next(p);
                    if (p->token == ':') {
                        keyword = native_slice(p, saved.start, saved.end);
                        native_next(p);
                    }
                    else { *p = saved; keyword = Qnil; }
                }
                vm_assembler_t *code = p->code;
                if (!NIL_P(keyword)) p->code = NULL;
                VALUE arg = native_expression(p);
                p->code = code;
                if (arg == Qundef) return Qnil;
                if (NIL_P(keyword)) {
                    rb_ary_push(p->code ? filters : args, arg);
                    count++;
                }
                else {
                    if (NIL_P(kwargs)) kwargs = rb_hash_new();
                    if (native_gc_changed(p)) return Qnil;
                    rb_hash_aset(kwargs, keyword, arg);
                }
                if (p->token != ',') break;
                native_next(p);
            }
        }
        if (p->code) {
            long argc = count;
            if (argc + (NIL_P(kwargs) ? 0 : 1) > 254 || (!NIL_P(kwargs) && RHASH_SIZE(kwargs) > 255)) return Qnil;
            if (!NIL_P(kwargs)) {
                native_keyword_compile_t compile = { p->code, true, p->initial_gc_count };
                rb_hash_foreach(kwargs, native_compile_keyword, (VALUE)&compile);
                if (!compile.valid) return Qnil;
                vm_assembler_add_hash_new(p->code, RHASH_SIZE(kwargs));
                argc++;
            }
            vm_assembler_add_filter(p->code, filter_name, (size_t)argc);
        }
        if (p->code) {
            rb_ary_store(filters, filter_offset + 1, LONG2NUM(count));
            rb_ary_store(filters, filter_offset + 2, kwargs);
        } else {
            VALUE filter = rb_ary_new_from_args(2, filter_name, args);
            if (!NIL_P(kwargs)) rb_ary_push(filter, kwargs);
            rb_ary_push(filters, filter);
        }
    }
    if (p->token != N_END) return Qnil;
    if (p->code) {
        p->variable_name = name;
        p->variable_filters = filters;
        return Qtrue;
    }
    return rb_ary_new_from_args(3, name, filters, p->pending);
}

static VALUE native_variable_body(VALUE opaque)
{
    return native_variable_body_probed(opaque, NULL);
}

static bool native_payload_methods_standard(int operation)
{
    if (!native_primitives_standard(true)) return false;
    VALUE constructors[] = { cLiquidVariableLookup, cLiquidRangeLookup, native_parser_class };
    for (size_t i = 0; i < sizeof(constructors) / sizeof(constructors[0]); i++) {
        VALUE owner = CLASS_OF(constructors[i]);
        if (!RB_TYPE_P(constructors[i], T_CLASS) ||
            rb_get_alloc_func(constructors[i]) != rb_get_alloc_func(rb_cObject) ||
            !liquid_method_basic_definition_p(owner, id_new_native) ||
            !liquid_method_basic_definition_p(owner, id_allocate_native)) return false;
    }
    if (operation == 1) {
        if (!RB_TYPE_P(native_condition_class, T_CLASS) ||
            rb_get_alloc_func(native_condition_class) != rb_get_alloc_func(rb_cObject)) return false;
        VALUE owner = CLASS_OF(native_condition_class);
        if (!liquid_method_basic_definition_p(owner, id_new_native) ||
            !liquid_method_basic_definition_p(owner, id_allocate_native)) return false;
    }
    return true;
}

static VALUE native_parse_payload(VALUE markup, VALUE cache, int operation, bool checked_cache, bool checked_methods, variable_compile_guard_t *guard)
{
    if (!RB_TYPE_P(markup, T_STRING) || CLASS_OF(markup) != rb_cString ||
        rb_enc_get_index(markup) != utf8_encoding_index) return Qnil;
    size_t before_gc = liquid_gc_count();
    if (!checked_methods && !native_payload_methods_standard(operation)) return Qnil;
    if (rb_enc_str_coderange(markup) == ENC_CODERANGE_BROKEN) return Qnil;
    if (!checked_methods && !NIL_P(cache) && (!RB_TYPE_P(cache, T_HASH) ||
        !liquid_method_basic_definition_p(CLASS_OF(cache), rb_intern("[]")) ||
        !liquid_method_basic_definition_p(CLASS_OF(cache), rb_intern("[]=")) ||
        !liquid_method_basic_definition_p(CLASS_OF(cache), rb_intern("key?")))) return Qnil;
    if (!NIL_P(cache) && !checked_cache && !native_string_cache(cache)) return Qnil;
    native_parser_t parser = { .cache = cache, .pending = Qnil, .operation = operation,
        .initial_gc_count = before_gc, .guarded = checked_methods };
    if (guard && guard->literals_checked) {
        parser.condition_literals = guard->condition_literals;
        parser.literals_checked = true;
    }
    parser.source = rb_str_dup_frozen(markup);
    if (rb_enc_get_index(parser.source) != utf8_encoding_index ||
        rb_enc_str_coderange(parser.source) == ENC_CODERANGE_BROKEN) return Qnil;
    parser.length = (size_t)RSTRING_LEN(parser.source);
    // The parser lives on the machine stack, so the conservative scan keeps its
    // VALUEs alive and pinned without a global root that could outlive an
    // abandoned fiber.
    VALUE result = native_variable_body((VALUE)&parser);
    if (!NIL_P(result) && !NIL_P(cache) && !native_normal_hash(cache)) result = Qnil;
    if ((!checked_cache || liquid_gc_count() != before_gc) && !native_payload_methods_standard(operation)) result = Qnil;
    RB_GC_GUARD(parser.source);
    if (guard && parser.literals_checked && liquid_gc_count() == before_gc) {
        guard->condition_literals = parser.condition_literals;
        guard->literals_checked = true;
    }
    RB_GC_GUARD(parser.pending);
    RB_GC_GUARD(cache);
    RB_GC_GUARD(result);
    return result;
}

static VALUE native_parse_variable(VALUE self, VALUE markup, VALUE cache) { return native_parse_payload(markup, cache, 0, false, false, NULL); }
static VALUE native_parse_condition(VALUE self, VALUE markup, VALUE cache) { return native_parse_payload(markup, cache, 1, false, false, NULL); }
static VALUE native_parse_for(VALUE self, VALUE markup, VALUE cache) { return native_parse_payload(markup, cache, 2, false, false, NULL); }
static VALUE native_parse_expression(VALUE self, VALUE markup, VALUE cache) { return native_parse_payload(markup, cache, 3, false, false, NULL); }

static int native_publish_entry(VALUE key, VALUE value, VALUE cache)
{
    if (liquid_method_basic_definition_p(CLASS_OF(cache), rb_intern("[]="))) rb_hash_aset(cache, key, value);
    else rb_funcall(cache, rb_intern("[]="), 2, key, value);
    return ST_CONTINUE;
}

static VALUE native_publish_cache(VALUE self, VALUE cache, VALUE pending)
{
    if (!RTEST(cache)) return Qnil;
    Check_Type(cache, T_HASH);
    if (NIL_P(pending)) return Qnil;
    Check_Type(pending, T_HASH);
    rb_hash_foreach(pending, native_publish_entry, cache);
    return Qnil;
}

static VALUE native_record_stats(VALUE self, VALUE context, VALUE reason)
{
    VALUE options = rb_ivar_get(context, id_options_native);
    if (!RB_TYPE_P(options, T_HASH)) return Qnil;
    VALUE stats = rb_hash_lookup2(options, ID2SYM(id_stats_native), Qnil);
    if (NIL_P(stats)) return Qnil;
    Check_Type(stats, T_HASH);
    VALUE count = rb_funcall(stats, rb_intern("fetch"), 2, reason, INT2FIX(0));
    count = rb_funcall(count, rb_intern("+"), 1, INT2FIX(1));
    rb_funcall(stats, rb_intern("[]="), 2, reason, count);
    return Qnil;
}

static VALUE native_parser_tracing(VALUE self)
{
    // Portable frontend checks methods before and after construction; the
    // single-operation optimization above requires the optional tracing flag.
    return Qfalse;
}


static VALUE native_variable_candidate(VALUE self, VALUE markup, VALUE context)
{
    VALUE candidate = native_frontend_candidate(self, markup);
    if (!RTEST(candidate)) native_record_stats(self, context, ID2SYM(rb_intern("guard_cost")));
    return candidate;
}

static VALUE native_case_candidate(VALUE self, VALUE markup, VALUE cache)
{
    if (!RB_TYPE_P(markup, T_STRING) || CLASS_OF(markup) != rb_cString ||
        rb_enc_get_index(markup) != utf8_encoding_index) return Qfalse;
    long length = RSTRING_LEN(markup);
    if (length < 64) return Qfalse;
    const unsigned char *source = (const unsigned char *)RSTRING_PTR(markup);
    if (!native_alpha(source[0])) return Qfalse;
    int selectors = 0;
    unsigned char quote = 0;
    for (long i = 0; i < length; i++) {
        unsigned char c = source[i];
        if (quote == c) quote = 0;
        else if (!quote && (c == '\'' || c == '"')) quote = c;
        else if (!quote && (c == '.' || c == '[')) selectors++;
    }
    if (selectors < 16) return Qfalse;
    if (RTEST(cache)) {
        if (CLASS_OF(cache) != rb_cHash || !liquid_method_basic_definition_p(rb_cHash, rb_intern("key?")) ||
            !liquid_method_basic_definition_p(rb_cHash, rb_intern("[]"))) return Qfalse;
        if (rb_hash_lookup2(cache, markup, Qundef) != Qundef) return Qfalse;
    }
    return Qtrue;
}

static VALUE native_case_expression(int argc, VALUE *argv, VALUE self)
{
    if (argc == 1 && !rb_keyword_given_p() && rb_obj_class(self) == native_case_class) {
        VALUE context = rb_ivar_get(self, rb_intern("@parse_context"));
        VALUE cache = rb_ivar_get(context, id_cache_native);
        if (RTEST(native_case_candidate(Qnil, argv[0], cache))) {
            VALUE helpers = rb_const_get(mLiquidC, rb_intern("NativeTags"));
            VALUE result = rb_funcall(helpers, rb_intern("try_case_expression"), 2, self, argv[0]);
            if (!NIL_P(result)) return RARRAY_AREF(result, 0);
        }
    }
    return rb_call_super_kw(argc, argv, RB_PASS_CALLED_KEYWORDS);
}


static VALUE native_install_header_parser(VALUE self, VALUE original, VALUE for_tag)
{
    return Qnil;
}

static VALUE native_install_strict_context(VALUE self)
{
    return Qnil;
}

static VALUE native_install_case_parser(VALUE self)
{
    rb_define_private_method(native_case_class, "parse_expression", native_case_expression, -1);
    return Qnil;
}

static VALUE native_variable_frontend(VALUE self, VALUE markup, VALUE context, VALUE variable)
{
    if (!native_variable_ready) return Qnil;
    if (!RTEST(native_variable_candidate(self, markup, context))) return Qnil;
    VALUE helper = rb_const_get(mLiquidC, rb_intern("NativeParser"));
    return rb_funcall(helper, rb_intern("parse"), 3, markup, context, variable);
}

static VALUE native_variable_frontend_method(VALUE self, VALUE markup)
{
    VALUE context = rb_ivar_get(self, id_parse_context_native);
    return native_variable_frontend(mLiquidC, markup, context, self);
}

static VALUE native_enable_variable_frontend(VALUE self)
{
    native_variable_ready = true;
    return Qnil;
}

bool native_compiler_guard(variable_parse_args_t *args) { return false; }
bool native_include_class_p(VALUE klass) { return false; }
VALUE native_parse_include(variable_parse_args_t *args, VALUE klass, VALUE name, VALUE markup) { return Qundef; }
VALUE native_parse_capture(variable_parse_args_t *args, VALUE klass, VALUE name, VALUE markup) { return Qundef; }
bool native_assignment_class_p(VALUE klass) { return false; }
VALUE native_parse_assignment(variable_parse_args_t *args, VALUE klass, VALUE name, VALUE markup) { return Qundef; }
bool native_control_guard(variable_parse_args_t *args) { return false; }
VALUE native_registered_tag(variable_parse_args_t *args, VALUE environment, VALUE name) { return Qundef; }
VALUE native_control_header(variable_parse_args_t *args, VALUE markup, int kind, bool commit) { return Qnil; }
void native_control_commit(variable_parse_args_t *args, VALUE header) {}
void native_control_for_fields(VALUE tag, VALUE payload) {}
void native_control_attach(variable_parse_args_t *args, VALUE condition, VALUE body) {}
int native_control_kind(VALUE klass) { return 0; }
VALUE native_control_else(variable_parse_args_t *args) { return Qnil; }
void native_control_finish(variable_parse_args_t *args, VALUE tag, int kind) {}
bool native_control_condition(VALUE node) { return false; }
bool native_compile_variable(variable_parse_args_t *args, VALUE line_number) { return false; }
bool variable_render_methods_standard(void) { return liquid_vm_render_methods_standard(); }
bool variable_render_traced(void) { return true; }
bool variable_output_method_standard(void) { return false; }

void liquid_define_native_parser(void)
{
#ifdef LIQUID_C_TEST_ALLOC_FAILURES
    rb_global_variable(&native_parser_test_callback);
    rb_define_singleton_method(mLiquidC, "native_parser_test_callback=", native_set_parser_test_callback, 1);
#endif
    VALUE *roots[] = { &native_expression_class, &native_parser_class, &native_condition_class, &native_literals, &native_unbound_class };
    for (size_t i = 0; i < sizeof(roots) / sizeof(roots[0]); i++) rb_global_variable(roots[i]);
    native_unbound_class = Qnil;
#ifndef HAVE_RB_AUTOLOAD_P
    rb_global_variable(&native_autoload_reader);
    ID autoload_query = rb_intern("autoload?"), module_instance_method = rb_intern("instance_method");
    if (liquid_method_basic_definition_p(CLASS_OF(rb_cModule), module_instance_method) &&
        liquid_method_basic_definition_p(rb_cModule, autoload_query)) {
        VALUE unbound = rb_funcall(rb_cModule, module_instance_method, 1, ID2SYM(autoload_query));
        ID reader_bind_call = rb_intern("bind_call");
        if (liquid_method_basic_definition_p(CLASS_OF(unbound), reader_bind_call))
            native_autoload_reader = liquid_method_handle(rb_obj_method(unbound, ID2SYM(reader_bind_call)));
        RB_GC_GUARD(unbound);
    }
#endif
    native_expression_class = native_capture_constant(mLiquid, "Expression");
    native_parser_class = native_capture_constant(mLiquid, "Parser");
    native_condition_class = native_capture_constant(mLiquid, "Condition");
    native_literals = native_capture_constant(native_expression_class, "LITERALS");
    const char *properties[] = { "compare_by_identity?", "default_proc", "default" };
    ID instance_method = rb_intern("instance_method"), bind_call = rb_intern("bind_call");
    for (size_t i = 0; i < sizeof(properties) / sizeof(properties[0]); i++) {
        rb_global_variable(&native_hash_readers[i]);
        native_hash_readers[i] = Qnil;
        ID property = rb_intern(properties[i]);
        if (!liquid_method_basic_definition_p(CLASS_OF(rb_cHash), instance_method) ||
            !liquid_method_basic_definition_p(rb_cHash, property)) continue;
        VALUE unbound = rb_funcall(rb_cHash, instance_method, 1, ID2SYM(property));
        native_unbound_class = CLASS_OF(unbound);
        if (!liquid_method_basic_definition_p(native_unbound_class, bind_call)) continue;
        VALUE reader = liquid_method_handle(rb_obj_method(unbound, ID2SYM(bind_call)));
        if (liquid_method_basic_definition_p(CLASS_OF(unbound), bind_call) &&
            liquid_method_basic_definition_p(rb_cHash, property)) native_hash_readers[i] = reader;
        RB_GC_GUARD(unbound);
    }
    const char *strings[] = { "strip", "start_with?", "end_with?", "scan", "match", "to_f", "[]", "freeze", "=~", "<<", "==", "byteslice", "length", "dup", "initialize_copy", "initialize_dup", "hash", "eql?" };
    for (size_t i = 0; i < sizeof(strings) / sizeof(strings[0]); i++) native_guard_primitive(rb_cString, strings[i]);
    const char *arrays[] = { "all?", "each_with_index", "push", "reverse_each", "shift", "each_index", "[]", "[]=", "<<", "include?", "each", "size", "==" };
    for (size_t i = 0; i < sizeof(arrays) / sizeof(arrays[0]); i++) native_guard_primitive(rb_cArray, arrays[i]);
    native_guard_primitive(cLiquidVariableLookup, "freeze");
    native_guard_primitive(cLiquidRangeLookup, "freeze");
    native_guard_primitive(rb_cRange, "freeze");
    native_guard_primitive(rb_cHash, "[]");
    native_guard_primitive(rb_cHash, "[]=");
    native_guard_primitive(rb_cHash, "key?");
    native_guard_primitive(rb_cHash, "each");
    native_guard_primitive(rb_cHash, "size");
    native_guard_primitive(rb_cInteger, "<<");
    native_guard_primitive(rb_cInteger, "|");
    native_guard_primitive(rb_cInteger, "&");
    native_guard_primitive(rb_cInteger, "<=>");
    native_guard_primitive(rb_cInteger, "freeze");
    native_guard_primitive(rb_cFloat, "freeze");
    native_guard_primitive(rb_cNilClass, "==");
    native_guard_primitive(rb_cRegexp, "===");
    native_guard_primitive(rb_cRegexp, "match?");
    native_guard_primitive(native_condition_class, "send");
    native_guard_primitive(rb_cMatch, "[]");
    native_guard_primitive(rb_cObject, "is_a?");
    native_guard_primitive(rb_cObject, "freeze");
    const char *integers[] = { "+", "-", "==", "!=", "<", ">", ">=" };
    for (size_t i = 0; i < sizeof(integers) / sizeof(integers[0]); i++) native_guard_primitive(rb_cInteger, integers[i]);
    const char *symbols[] = { "==", "!=", "===" };
    for (size_t i = 0; i < sizeof(symbols) / sizeof(symbols[0]); i++) native_guard_primitive(rb_cSymbol, symbols[i]);
    id_string_scanner = rb_intern("@string_scanner");
    id_new_native = rb_intern("new");
    id_allocate_native = rb_intern("allocate");
    id_disabled_native = rb_intern("@liquid_c_nodes_disabled");
    id_mode_native = rb_intern("@error_mode");
    id_cache_native = rb_intern("@expression_cache");
    id_options_native = rb_intern("@options");
    id_parse_context_native = rb_intern("@parse_context");
    id_stats_native = rb_intern("native_parser_stats");
    id_enabled_native = rb_intern("@enabled");
    const char *for_fields[] = { "@variable_name", "@collection_name", "@name", "@reversed", "@from", "@limit" };
    for (size_t i = 0; i < 6; i++) id_for_fields[i] = rb_intern(for_fields[i]);
    rb_global_variable(&native_if_class);
    rb_global_variable(&native_unless_class);
    rb_global_variable(&native_for_class);
    rb_global_variable(&native_original_if);
    rb_global_variable(&native_original_for);
    rb_global_variable(&native_context_class);
    rb_global_variable(&native_case_class);
    native_context_class = rb_const_get(mLiquid, rb_intern("ParseContext"));
    native_case_class = rb_const_get(mLiquid, rb_intern("Case"));
    native_if_class = rb_const_get(mLiquid, rb_intern("If"));
    native_unless_class = rb_const_get(mLiquid, rb_intern("Unless"));
    native_for_class = rb_const_get(mLiquid, rb_intern("For"));
    rb_define_singleton_method(mLiquidC, "native_install_case_parser", native_install_case_parser, 0);
    rb_define_singleton_method(mLiquidC, "native_install_header_parser", native_install_header_parser, 2);
    rb_define_singleton_method(mLiquidC, "native_install_strict_context", native_install_strict_context, 0);
    rb_define_singleton_method(mLiquidC, "native_parser_tracing?", native_parser_tracing, 0);
    rb_define_singleton_method(mLiquidC, "native_variable_frontend", native_variable_frontend, 3);
    rb_define_private_method(rb_const_get(mLiquid, rb_intern("Variable")), "liquid_c_native_parse", native_variable_frontend_method, 1);
    rb_define_singleton_method(mLiquidC, "native_enable_variable_frontend", native_enable_variable_frontend, 0);
    rb_define_singleton_method(mLiquidC, "native_constant_matches?", native_constant_matches, 4);
    rb_define_singleton_method(mLiquidC, "native_public_method?", native_public_method, 2);
    rb_define_singleton_method(mLiquidC, "native_frontend_candidate?", native_frontend_candidate, 1);
    rb_define_singleton_method(mLiquidC, "native_variable_candidate?", native_variable_candidate, 2);
    id_name = rb_intern("@name");
    id_lookups = rb_intern("@lookups");
    id_commands = rb_intern("@command_flags");
    id_start = rb_intern("@start_obj");
    id_end = rb_intern("@end_obj");
    rb_define_singleton_method(mLiquidC, "native_parse_variable", native_parse_variable, 2);
    rb_define_singleton_method(mLiquidC, "native_parse_condition", native_parse_condition, 2);
    rb_define_singleton_method(mLiquidC, "native_parse_for", native_parse_for, 2);
    rb_define_singleton_method(mLiquidC, "native_parse_expression", native_parse_expression, 2);
    rb_define_singleton_method(mLiquidC, "native_case_candidate?", native_case_candidate, 2);
    rb_define_singleton_method(mLiquidC, "native_publish_cache", native_publish_cache, 2);
    rb_define_singleton_method(mLiquidC, "native_record_stats", native_record_stats, 2);
}
