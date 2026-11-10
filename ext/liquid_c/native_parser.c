#include "liquid.h"
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
static ID id_string_scanner, id_new_native, id_allocate_native, id_freeze_native;
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
    extern VALUE rb_hash_compare_by_id_p(VALUE hash);
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

static struct { VALUE owner, entry; ID method; bool public_call; } primitive_guards[96];
static size_t primitive_guard_count;

static void native_guard_primitive(VALUE owner, const char *method)
{
    assert(primitive_guard_count < sizeof(primitive_guards) / sizeof(primitive_guards[0]));
    primitive_guards[primitive_guard_count].owner = owner;
    rb_gc_register_address(&primitive_guards[primitive_guard_count].entry);
    primitive_guards[primitive_guard_count].public_call = strcmp(method, "initialize_copy") && strcmp(method, "initialize_dup");
    primitive_guards[primitive_guard_count++].method = rb_intern(method);
}

static VALUE native_public_method(VALUE self, VALUE receiver, VALUE name)
{
    return rb_method_boundp(CLASS_OF(receiver), SYM2ID(name), 3) == 1 ? Qtrue : Qfalse;
}

static VALUE native_constant_matches(VALUE self, VALUE owner, VALUE name, VALUE expected, VALUE snapshot)
{
    if (!RB_TYPE_P(owner, T_CLASS) && !RB_TYPE_P(owner, T_MODULE)) return Qfalse;
    Check_Type(name, T_SYMBOL);
    ID id = SYM2ID(name);
    if (!rb_const_defined_at(owner, id) || RTEST(native_autoload_p(owner, id)) || rb_const_get_at(owner, id) != expected) return Qfalse;
    if (!NIL_P(snapshot)) {
        if (!RB_TYPE_P(expected, T_ARRAY) || !RB_TYPE_P(snapshot, T_ARRAY) || RARRAY_LEN(expected) != RARRAY_LEN(snapshot)) return Qfalse;
        for (long i = 0; i < RARRAY_LEN(expected); i++)
            if (RARRAY_AREF(expected, i) != RARRAY_AREF(snapshot, i)) return Qfalse;
    }
    return Qtrue;
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

#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY
// Optional MRI capability. Only compare opaque entries; never depend on their
// layout. Other Ruby implementations use the public Ruby reflection fallback.
extern const void *rb_callable_method_entry(VALUE klass, ID mid);
typedef struct { VALUE owner, entry, snapshot; ID method; int receiver; bool constant, public_call, builtin; } native_method_guard_t;
static native_method_guard_t *method_guards;
static long method_guard_count;
static VALUE integer_to_i_entry;
static VALUE constant_watchers = Qnil, constant_vm = Qnil, constant_epoch = Qundef;
static ID id_stat, id_constant_invalidations;
static bool guard_roots_registered;

static VALUE native_watchers_supported(VALUE self, VALUE vm)
{
    return liquid_method_basic_definition_p(CLASS_OF(vm), rb_intern("stat")) &&
        liquid_method_basic_definition_p(rb_cModule, rb_intern("module_eval")) &&
        liquid_method_basic_definition_p(rb_cModule, rb_intern("instance_method")) &&
        (RB_TYPE_P(native_unbound_class, T_CLASS) && liquid_method_basic_definition_p(native_unbound_class, rb_intern("bind_call"))) &&
        liquid_method_basic_definition_p(rb_cProc, rb_intern("call")) ? Qtrue : Qfalse;
}

static VALUE native_constant_epoch(void)
{
    if (NIL_P(constant_vm) || !liquid_method_basic_definition_p(CLASS_OF(constant_vm), id_stat)) return Qundef;
    return rb_funcall(constant_vm, id_stat, 1, ID2SYM(id_constant_invalidations));
}

static VALUE native_register_guards(VALUE self, VALUE specifications, VALUE watchers, VALUE vm)
{
    Check_Type(specifications, T_ARRAY);
    long count = RARRAY_LEN(specifications);
    if (count < 0 || (size_t)count > SIZE_MAX / sizeof(*method_guards))
        rb_raise(rb_eArgError, "too many method guards");
    bool first = method_guards == NULL;
    if (!first && count != method_guard_count) rb_raise(rb_eArgError, "guard count changed");
    for (long i = 0; i < count; i++) {
        VALUE spec = RARRAY_AREF(specifications, i);
        Check_Type(spec, T_ARRAY);
        if (RARRAY_LEN(spec) != 7) rb_raise(rb_eArgError, "invalid method guard");
        VALUE owner = RARRAY_AREF(spec, 0);
        if (!RB_TYPE_P(owner, T_CLASS) && !RB_TYPE_P(owner, T_MODULE)) rb_raise(rb_eTypeError, "guard owner must be a module");
        Check_Type(RARRAY_AREF(spec, 1), T_SYMBOL);
        int receiver = NUM2INT(RARRAY_AREF(spec, 2));
        if (receiver < 0 || receiver > 3) rb_raise(rb_eArgError, "invalid method guard receiver");
        if (!NIL_P(RARRAY_AREF(spec, 4))) Check_Type(RARRAY_AREF(spec, 4), T_ARRAY);
    }
    if (!NIL_P(watchers)) Check_Type(watchers, T_ARRAY);
    if (first) method_guards = ruby_xcalloc((size_t)count, sizeof(*method_guards));
    if (!guard_roots_registered) {
        rb_gc_register_address(&constant_watchers);
        rb_gc_register_address(&constant_vm);
        rb_gc_register_address(&constant_epoch);
        guard_roots_registered = true;
    }
    constant_watchers = watchers;
    constant_vm = NIL_P(watchers) ? Qnil : vm;
    constant_epoch = Qundef;
    id_stat = rb_intern("stat");
    id_constant_invalidations = rb_intern("constant_cache_invalidations");
    if (first) {
        for (long i = 0; i < count; i++) {
            rb_gc_register_address(&method_guards[i].owner);
            rb_gc_register_address(&method_guards[i].entry);
            rb_gc_register_address(&method_guards[i].snapshot);
        }
    }
    for (long i = 0; i < count; i++) {
        VALUE spec = RARRAY_AREF(specifications, i);
        native_method_guard_t *guard = &method_guards[i];
        guard->owner = RARRAY_AREF(spec, 0);
        guard->method = SYM2ID(RARRAY_AREF(spec, 1));
        guard->receiver = NUM2INT(RARRAY_AREF(spec, 2));
        guard->constant = RTEST(RARRAY_AREF(spec, 3));
        guard->public_call = RTEST(RARRAY_AREF(spec, 6));
        guard->builtin = !guard->constant && liquid_method_basic_definition_p(guard->owner, guard->method);
        guard->snapshot = RARRAY_AREF(spec, 4);
        guard->entry = guard->constant ? RARRAY_AREF(spec, 5) :
            (VALUE)rb_callable_method_entry(guard->owner, guard->method);
        if (!guard->constant && guard->owner == rb_cInteger && guard->method == rb_intern("to_i"))
            integer_to_i_entry = guard->entry;
    }
    method_guard_count = count;
    return Qtrue;
}

static bool native_method_guard_current(native_method_guard_t *guard)
{
    VALUE current = (VALUE)rb_callable_method_entry(guard->owner, guard->method);
    if (!guard->entry) return false;
    if (guard->entry != current) {
        // MRI can recreate inherited entries for an unchanged core constructor.
        if (!guard->builtin || !liquid_method_basic_definition_p(guard->owner, guard->method)) return false;
        guard->entry = current;
        if (guard->owner == rb_cInteger && guard->method == rb_intern("to_i")) integer_to_i_entry = current;
    }
    return true;
}

static VALUE native_methods_compatible(VALUE self, VALUE context, VALUE variable)
{
    VALUE epoch = native_constant_epoch();
    VALUE scanner = rb_ivar_get(context, id_string_scanner);
    VALUE receiver_classes[] = { Qnil, CLASS_OF(context), CLASS_OF(scanner), NIL_P(variable) ? Qnil : CLASS_OF(variable) };
    bool cached_constants = epoch != Qundef && epoch == constant_epoch;
    for (long i = 0; i < method_guard_count; i++) {
        native_method_guard_t *guard = &method_guards[i];
        if (guard->constant) {
            if (cached_constants) {
                // Reader ISeqs are rooted in constant_watchers. MRI invalidates
                // their registered IC sites even before they are read again.
                // Mutable table slots must still be checked on every operation.
                if (!NIL_P(guard->snapshot)) {
                    if (RARRAY_LEN(guard->entry) != RARRAY_LEN(guard->snapshot)) return Qfalse;
                    for (long j = 0; j < RARRAY_LEN(guard->entry); j++)
                        if (RARRAY_AREF(guard->entry, j) != RARRAY_AREF(guard->snapshot, j)) return Qfalse;
                }
            } else if (!RTEST(native_constant_matches(Qnil, guard->owner, ID2SYM(guard->method), guard->entry, guard->snapshot))) return Qfalse;
            continue;
        }
        if (!native_method_guard_current(guard)) return Qfalse;
        if (guard->public_call && rb_method_boundp(guard->owner, guard->method, 3) != 1) return Qfalse;
        if (guard->receiver) {
            if (guard->receiver == 3 && NIL_P(variable)) continue;
            VALUE target_class = receiver_classes[guard->receiver];
            if (guard->receiver == 2 && RB_OBJ_FROZEN(scanner)) return Qfalse;
            // Standard receivers have the same class already checked above.
            // Singleton classes still require their own current method lookup.
            if (target_class != guard->owner &&
                guard->entry != (VALUE)rb_callable_method_entry(target_class, guard->method)) return Qfalse;
        }
    }
    if (epoch != Qundef && epoch != native_constant_epoch()) return Qfalse;
    constant_epoch = epoch;
    return Qtrue;
}
#endif

static bool native_conversion_is_standard(VALUE value)
{
    VALUE klass = CLASS_OF(value);
    if (!liquid_method_basic_definition_p(klass, rb_intern("respond_to?")) ||
        !liquid_method_basic_definition_p(klass, rb_intern("respond_to_missing?")) ||
        rb_method_boundp(klass, id_evaluate, 0)) return false;
    if (liquid_method_basic_definition_p(klass, rb_intern("to_i"))) return true;
#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY
    return RB_INTEGER_TYPE_P(value) && integer_to_i_entry && integer_to_i_entry ==
        (VALUE)rb_callable_method_entry(CLASS_OF(value), rb_intern("to_i"));
#else
    return false;
#endif
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
        if (native_gc_changed(p)) return Qundef;
        if (!NIL_P(previous_key)) {
            rb_hash_aset(p->pending, previous_key, p->pending_value);
            if (native_gc_changed(p)) return Qundef;
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

static VALUE native_variable_unpin(VALUE opaque)
{
    native_parser_t *p = (void *)opaque;
    rb_gc_unregister_address(&p->source);
    return Qnil;
}

static bool native_payload_methods_standard(int operation)
{
    for (size_t i = 0; i < primitive_guard_count; i++)
        if (!liquid_method_basic_definition_p(primitive_guards[i].owner, primitive_guards[i].method) ||
            (primitive_guards[i].public_call && rb_method_boundp(primitive_guards[i].owner, primitive_guards[i].method, 3) != 1)) return false;
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
    if (!liquid_method_basic_definition_p(cLiquidVariableLookup, id_freeze_native) ||
        !liquid_method_basic_definition_p(cLiquidRangeLookup, id_freeze_native) ||
        !liquid_method_basic_definition_p(rb_cRange, id_freeze_native)) return false;
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
    rb_gc_register_address(&parser.source);
    VALUE result = rb_ensure(native_variable_body, (VALUE)&parser, native_variable_unpin, (VALUE)&parser);
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

#ifdef HAVE_RUBY_VM_EVENT_FLAGS
extern rb_event_flag_t ruby_vm_event_flags;
#endif

static VALUE native_parser_tracing(VALUE self)
{
#ifdef HAVE_RUBY_VM_EVENT_FLAGS
    return ruby_vm_event_flags ? Qtrue : Qfalse;
#else
    // Portable frontend checks methods before and after construction; the
    // single-operation optimization above requires the optional tracing flag.
    return Qfalse;
#endif
}

#if defined(HAVE_RB_CALLABLE_METHOD_ENTRY) && defined(HAVE_RUBY_VM_EVENT_FLAGS)


// One guarded operation: default constructors, numeric conversions and hash
// keys cannot call Ruby here. Recheck after a GC (finalizers may redefine code).
// TracePoint callbacks use the original parser rather than speculative parsing.
static bool native_bare_identifier(VALUE markup)
{
    if (!RB_TYPE_P(markup, T_STRING)) return false;
    const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(markup);
    size_t i = 0, size = (size_t)RSTRING_LEN(markup);
    while (i < size && native_space(bytes[i])) i++;
    if (i == size || !native_alpha(bytes[i++])) return false;
    while (i < size && (native_alpha(bytes[i]) || native_digit(bytes[i]) || bytes[i] == '-')) i++;
    if (i < size && bytes[i] == '?') i++;
    while (i < size && native_space(bytes[i])) i++;
    return i == size;
}

static bool native_plain_lookup(VALUE markup)
{
    if (!RB_TYPE_P(markup, T_STRING) || RSTRING_LEN(markup) >= 128) return false;
    const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(markup);
    size_t i = 0, size = (size_t)RSTRING_LEN(markup);
    for (;;) {
        while (i < size && native_space(bytes[i])) i++;
        if (i == size || !native_alpha(bytes[i++])) return false;
        while (i < size && (native_alpha(bytes[i]) || native_digit(bytes[i]) || bytes[i] == '-')) i++;
        if (i < size && bytes[i] == '?') i++;
        while (i < size && native_space(bytes[i])) i++;
        if (i == size) return true;
        if (bytes[i++] != '.') return false;
    }
}

static VALUE native_try_variable_impl(VALUE self, VALUE markup, VALUE context, VALUE variable, bool retry);

static VALUE native_variable_guard_failure(VALUE self, VALUE markup, VALUE context, VALUE variable, bool retry)
{
    if (retry) {
        VALUE helper = rb_const_get(mLiquidC, rb_intern("NativeParser"));
        if (RTEST(rb_funcall(helper, rb_intern("compatible?"), 2, context, variable)))
            return native_try_variable_impl(self, markup, context, variable, false);
    }
    native_record_stats(self, context, ID2SYM(rb_intern("hooks")));
    return Qnil;
}

static VALUE native_try_variable_impl(VALUE self, VALUE markup, VALUE context, VALUE variable, bool retry)
{
    if (!method_guard_count) return Qnil;
    if (ruby_vm_event_flags) return Qnil;
    if (rb_obj_class(context) != native_context_class || rb_obj_class(variable) != cLiquidVariable) return Qnil;
    VALUE early_cache = rb_ivar_get(context, id_cache_native);
    // Reject costly short unique forms before environment/method checks.
    if (RB_TYPE_P(early_cache, T_HASH) && RHASH_SIZE(early_cache) > 32 &&
        RB_TYPE_P(markup, T_STRING) && RSTRING_LEN(markup) < 128) {
        native_record_stats(self, context, ID2SYM(rb_intern("guard_cost")));
        return Qnil;
    }
    if (native_bare_identifier(markup) && (!RB_TYPE_P(early_cache, T_HASH) || RHASH_SIZE(early_cache) != 1)) {
        native_record_stats(self, context, ID2SYM(rb_intern("guard_cost")));
        return Qnil;
    }
    if (RB_TYPE_P(early_cache, T_HASH) && native_plain_lookup(markup)) {
        VALUE document = rb_ivar_get(context, rb_intern("document_body"));
        if (!NIL_P(document) && !document_body_cache_stable(document, RHASH_SIZE(early_cache))) {
            native_record_stats(self, context, ID2SYM(rb_intern("guard_cost")));
            return Qnil;
        }
    }
    // Tokenizer setup initializes this flag. Standalone Variable.new retains
    // the original Ruby path rather than calling extra context callbacks.
    if (!rb_ivar_defined(context, id_disabled_native)) {
        native_record_stats(self, context, ID2SYM(rb_intern("context")));
        return Qnil;
    }
    const char *optout = getenv("LIQUID_C_NATIVE_PARSER");
    if (!RTEST(rb_ivar_get(mLiquidC, id_enabled_native)) || (optout && !strcmp(optout, "false"))) {
        native_record_stats(self, context, ID2SYM(rb_intern("disabled")));
        return Qnil;
    }
    size_t guard_gc = liquid_gc_count();
    if (!RTEST(native_methods_compatible(self, context, variable)))
        return native_variable_guard_failure(self, markup, context, variable, retry);
    if (liquid_gc_count() != guard_gc) {
        guard_gc = liquid_gc_count();
        if (!RTEST(native_methods_compatible(self, context, variable)) || liquid_gc_count() != guard_gc)
            return native_variable_guard_failure(self, markup, context, variable, retry);
    }
    if (ruby_vm_event_flags) return Qnil;
    if (RTEST(rb_ivar_get(context, id_disabled_native))) {
        native_record_stats(self, context, ID2SYM(rb_intern("disabled")));
        return Qnil;
    }
    VALUE mode = rb_ivar_get(context, id_mode_native);
    if (mode != ID2SYM(rb_intern("lax")) && mode != ID2SYM(rb_intern("warn")) && mode != ID2SYM(rb_intern("strict"))) {
        native_record_stats(self, context, ID2SYM(rb_intern("mode")));
        return Qnil;
    }
    VALUE cache = rb_ivar_get(context, id_cache_native);
    if (RTEST(cache)) {
        if (CLASS_OF(cache) != rb_cHash) return Qnil;
        if (!native_string_cache(cache)) {
            native_record_stats(self, context, ID2SYM(rb_intern("cache")));
            return Qnil;
        }
    } else cache = Qnil;
    if (rb_get_alloc_func(cLiquidVariableLookup) != rb_get_alloc_func(rb_cObject) ||
        rb_get_alloc_func(cLiquidRangeLookup) != rb_get_alloc_func(rb_cObject)) return Qnil;
    size_t gc_count = liquid_gc_count();
    VALUE result = native_parse_payload(markup, cache, 0, true, false, NULL);
    if (NIL_P(result)) {
        native_record_stats(self, context, ID2SYM(rb_intern("syntax")));
        return Qnil;
    }
    if (ruby_vm_event_flags) return Qnil;
    if (liquid_gc_count() != gc_count && !RTEST(native_methods_compatible(self, context, variable))) return Qnil;
    native_publish_cache(self, cache, RARRAY_AREF(result, 2));
    native_record_stats(self, context, ID2SYM(rb_intern("accepted")));
    return result;
}
static VALUE native_try_variable(VALUE self, VALUE markup, VALUE context, VALUE variable)
{
    return native_try_variable_impl(self, markup, context, variable, true);
}

#endif

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

#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY
static VALUE native_if_parse_entry, native_for_parse_entry;
static VALUE native_context_entries[3];
static VALUE native_switching_module;
static ID id_strict_context_native, id_strict_parse_native;

static VALUE native_fast_header(VALUE self, VALUE markup);

typedef struct { VALUE self, markup; bool second; } native_strict_args_t;

static VALUE native_strict_body(VALUE opaque)
{
    native_strict_args_t *args = (void *)opaque;
    VALUE fast = native_fast_header(args->self, args->markup);
    if (fast != Qundef) return fast;
    if (args->second) return rb_funcall(args->self, rb_intern("strict2_parse"), 1, args->markup);
    VALUE klass = rb_obj_class(args->self);
    int index = klass == native_if_class ? 0 : (klass == native_unless_class ? 1 : (klass == native_for_class ? 2 : -1));
    if (index >= 0 && !(index == 2 && RB_OBJ_FROZEN(args->self)) &&
        native_context_entries[index] == (VALUE)rb_callable_method_entry(CLASS_OF(args->self), id_strict_context_native) &&
        (index == 2 ? native_for_parse_entry : native_if_parse_entry) ==
            (VALUE)rb_callable_method_entry(CLASS_OF(args->self), id_strict_parse_native) &&
        RTEST(native_case_candidate(Qnil, args->markup, Qnil))) {
        VALUE helper = rb_const_get(mLiquidC, rb_intern("NativeTags"));
        VALUE kind = ID2SYM(rb_intern(index == 2 ? "for" : "condition"));
        VALUE result = rb_funcall(helper, rb_intern("try_tag_header"), 3, args->self, args->markup, kind);
        if (!NIL_P(result)) {
            VALUE payload = RARRAY_AREF(result, 0);
            if (index != 2) return payload;
            Check_Type(payload, T_ARRAY);
            if (RARRAY_LEN(payload) != 6) rb_raise(rb_eRuntimeError, "invalid native for header");
            for (size_t i = 0; i < 6; i++) rb_ivar_set(args->self, id_for_fields[i], RARRAY_AREF(payload, i));
            return Qnil;
        }
    }
    return rb_funcall(args->self, id_strict_parse_native, 1, args->markup);
}

static VALUE native_strict_rescue(VALUE opaque, VALUE exception)
{
    VALUE syntax_error = rb_const_get(mLiquid, rb_intern("SyntaxError"));
    if (!rb_obj_is_kind_of(exception, syntax_error)) rb_exc_raise(exception);
    native_strict_args_t *args = (void *)opaque;
    VALUE line = rb_funcall(args->self, rb_intern("line_number"), 0);
    rb_funcallv_public(exception, rb_intern("line_number="), 1, &line);
    VALUE markup = rb_funcall(args->self, rb_intern("markup_context"), 1, args->markup);
    rb_funcallv_public(exception, rb_intern("markup_context="), 1, &markup);
    rb_exc_raise(exception);
}

static VALUE native_strict_context(VALUE self, VALUE markup)
{
    native_strict_args_t args = { self, markup };
    return rb_rescue2(native_strict_body, (VALUE)&args, native_strict_rescue, (VALUE)&args, rb_eException, (VALUE)0);
}
static VALUE native_strict2_context(VALUE self, VALUE markup)
{
    native_strict_args_t args = { self, markup, true };
    return rb_rescue2(native_strict_body, (VALUE)&args, native_strict_rescue, (VALUE)&args, rb_eException, (VALUE)0);
}

static VALUE native_install_compiler_context(VALUE self)
{
    VALUE owner = rb_const_get(mLiquid, rb_intern("ParserSwitching"));
    rb_define_private_method(owner, "strict2_parse_with_error_context", native_strict2_context, 1);
    return Qnil;
}

#endif

static VALUE native_install_header_parser(VALUE self, VALUE original, VALUE for_tag)
{
#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY
    if (RTEST(for_tag)) {
        native_original_for = original;
        native_for_parse_entry = (VALUE)rb_callable_method_entry(native_for_class, rb_intern("strict_parse"));
    } else {
        native_original_if = original;
        native_if_parse_entry = (VALUE)rb_callable_method_entry(native_if_class, rb_intern("strict_parse"));
    }
#endif
    return Qnil;
}

static VALUE native_install_strict_context(VALUE self)
{
#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY
    id_strict_context_native = rb_intern("strict_parse_with_error_context");
    id_strict_parse_native = rb_intern("strict_parse");
    native_switching_module = rb_const_get(mLiquid, rb_intern("ParserSwitching"));
    rb_define_private_method(native_switching_module, "strict_parse_with_error_context", native_strict_context, 1);
    VALUE classes[] = { native_if_class, native_unless_class, native_for_class };
    for (size_t i = 0; i < 3; i++)
        native_context_entries[i] = (VALUE)rb_callable_method_entry(classes[i], id_strict_context_native);
#endif
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
#if defined(HAVE_RB_CALLABLE_METHOD_ENTRY) && defined(HAVE_RUBY_VM_EVENT_FLAGS)
    return native_try_variable(self, markup, context, variable);
#else
    if (!RTEST(native_variable_candidate(self, markup, context))) return Qnil;
    VALUE helper = rb_const_get(mLiquidC, rb_intern("NativeParser"));
    return rb_funcall(helper, rb_intern("parse"), 3, markup, context, variable);
#endif
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

#if defined(HAVE_RB_CALLABLE_METHOD_ENTRY) && defined(HAVE_RUBY_VM_EVENT_FLAGS)
static VALUE compiler_guard_specs = Qnil;
static struct { VALUE owner, entry; ID method; bool public_call, control, builtin; } compiler_methods[256];
static size_t compiler_method_count;
static VALUE renderer_guard_entries = Qnil;
static VALUE compiler_body_class = Qnil;
static rb_alloc_func_t compiler_body_allocator;
static VALUE compiler_constants = Qnil;
static VALUE compiler_constant_watchers = Qnil;
static VALUE compiler_ancestor_prefixes = Qnil;
static VALUE control_helpers[2], control_else_class, control_environment_class, native_assign_class, native_capture_class, native_include_class;
static VALUE control_tag_new_entry;
static bool native_control_binding(VALUE lexical_owner, ID name, VALUE expected);

static VALUE native_register_control(VALUE self, VALUE helpers, VALUE constants, VALUE prefixes, VALUE watchers)
{
    Check_Type(helpers, T_ARRAY);
    Check_Type(constants, T_ARRAY);
    Check_Type(prefixes, T_ARRAY);
    if (!NIL_P(watchers)) Check_Type(watchers, T_ARRAY);
    if (!NIL_P(compiler_constants)) rb_raise(rb_eRuntimeError, "control guards already registered");
    VALUE unbound = rb_const_get(rb_cObject, rb_intern("UnboundMethod"));
    for (long i = 0; i < RARRAY_LEN(helpers); i++)
        if (!rb_obj_is_kind_of(RARRAY_AREF(helpers, i), unbound)) rb_raise(rb_eTypeError, "expected UnboundMethod");
    for (long i = 0; i < RARRAY_LEN(prefixes); i++) {
        VALUE pair = RARRAY_AREF(prefixes, i);
        Check_Type(pair, T_ARRAY);
        if (RARRAY_LEN(pair) != 2 || !RB_TYPE_P(RARRAY_AREF(pair, 0), T_CLASS))
            rb_raise(rb_eTypeError, "expected class and ancestor prefix");
        Check_Type(RARRAY_AREF(pair, 1), T_ARRAY);
    }
    if (RARRAY_LEN(helpers) != 2) rb_raise(rb_eArgError, "invalid control helpers");
    for (long i = 0; i < RARRAY_LEN(constants); i++) {
        VALUE spec = RARRAY_AREF(constants, i);
        Check_Type(spec, T_ARRAY);
        if (RARRAY_LEN(spec) != 3) rb_raise(rb_eArgError, "invalid control constant");
        VALUE owner = RARRAY_AREF(spec, 0);
        if (!RB_TYPE_P(owner, T_CLASS) && !RB_TYPE_P(owner, T_MODULE)) rb_raise(rb_eTypeError, "expected module");
        Check_Type(RARRAY_AREF(spec, 1), T_SYMBOL);
    }
    compiler_constants = constants;
    compiler_constant_watchers = watchers;
    compiler_ancestor_prefixes = prefixes;
    control_else_class = rb_const_get(mLiquid, rb_intern("ElseCondition"));
    control_environment_class = rb_const_get(mLiquid, rb_intern("Environment"));
    native_assign_class = rb_const_get(mLiquid, rb_intern("Assign"));
    native_capture_class = rb_const_get(mLiquid, rb_intern("Capture"));
    native_include_class = rb_const_get(mLiquid, rb_intern("Include"));
    control_tag_new_entry = (VALUE)rb_callable_method_entry(CLASS_OF(native_if_class), rb_intern("new"));
    for (size_t i = 0; i < 2; i++) {
        VALUE helper = RARRAY_AREF(helpers, i);
        if (!rb_obj_is_kind_of(helper, rb_const_get(rb_cObject, rb_intern("UnboundMethod"))))
            rb_raise(rb_eTypeError, "expected UnboundMethod");
        control_helpers[i] = liquid_method_handle(rb_obj_method(helper, ID2SYM(rb_intern("bind_call"))));
    }
    return Qnil;
}
static VALUE compiler_stat = Qnil, compiler_epoch = Qundef;
static bool compiler_ready;
static bool compiler_registered;
static ID renderer_ids[3];

static VALUE native_register_compiler(VALUE self, VALUE specifications, VALUE enabled)
{
    Check_Type(specifications, T_ARRAY);
    if (compiler_registered) rb_raise(rb_eRuntimeError, "compiler guards already registered");
    if (RARRAY_LEN(specifications) > 256) rb_raise(rb_eArgError, "too many compiler guards");
    for (long i = 0; i < RARRAY_LEN(specifications); i++) {
        VALUE spec = RARRAY_AREF(specifications, i);
        Check_Type(spec, T_ARRAY);
        if (RARRAY_LEN(spec) != 3) rb_raise(rb_eArgError, "invalid compiler guard");
        VALUE owner = RARRAY_AREF(spec, 0);
        if (!RB_TYPE_P(owner, T_CLASS) && !RB_TYPE_P(owner, T_MODULE)) rb_raise(rb_eTypeError, "guard owner must be a module");
        Check_Type(RARRAY_AREF(spec, 1), T_SYMBOL);
    }
    compiler_registered = true;
    compiler_guard_specs = specifications;
    compiler_body_class = rb_const_get(mLiquidC, rb_intern("BlockBody"));
    compiler_body_allocator = rb_get_alloc_func(compiler_body_class);
    compiler_method_count = (size_t)RARRAY_LEN(specifications);
    for (long i = 0; i < RARRAY_LEN(specifications); i++) {
        VALUE spec = RARRAY_AREF(specifications, i);
        Check_Type(spec, T_ARRAY);
        if (RARRAY_LEN(spec) != 3) rb_raise(rb_eArgError, "invalid compiler guard");
        VALUE owner = RARRAY_AREF(spec, 0);
        Check_Type(RARRAY_AREF(spec, 1), T_SYMBOL);
        VALUE entry = (VALUE)rb_callable_method_entry(owner, SYM2ID(RARRAY_AREF(spec, 1)));
        compiler_methods[i].control = RTEST(RARRAY_AREF(spec, 2));
        compiler_methods[i].builtin = liquid_method_basic_definition_p(owner, SYM2ID(RARRAY_AREF(spec, 1)));
        compiler_methods[i].owner = owner;
        compiler_methods[i].entry = entry;
        ID method = SYM2ID(RARRAY_AREF(spec, 1));
        compiler_methods[i].method = method;
        compiler_methods[i].public_call =
            (owner == compiler_body_class && method != rb_intern("initialize")) || owner == native_context_class ||
            owner == CLASS_OF(compiler_body_class) || owner == CLASS_OF(control_else_class) ||
            owner == CLASS_OF(native_condition_class) || owner == control_environment_class ||
            owner == cLiquidVariableLookup || owner == cLiquidRangeLookup ||
            ((owner == native_condition_class || owner == control_else_class) && method != rb_intern("initialize"));
        rb_gc_register_address(&compiler_methods[i].owner);
        rb_gc_register_address(&compiler_methods[i].entry);
    }
    bool renderers_standard = liquid_vm_render_methods_standard();
    renderer_guard_entries = rb_ary_new_capa(3);
    const char *names[] = { "render", "render_to_output_buffer", "render_obj_to_output" };
    for (size_t i = 0; i < 3; i++) {
        renderer_ids[i] = rb_intern(names[i]);
        VALUE entry = renderers_standard ? (VALUE)rb_callable_method_entry(cLiquidVariable, renderer_ids[i]) : 0;
        rb_ary_push(renderer_guard_entries, entry);
    }
    compiler_ready = RTEST(enabled);
    if (!liquid_method_basic_definition_p(native_unbound_class, rb_intern("==")) ||
        !liquid_method_basic_definition_p(native_unbound_class, rb_intern("super_method")) ||
        !liquid_method_basic_definition_p(native_unbound_class, rb_intern("bind_call"))) compiler_ready = false;
    for (size_t i = 0; i < primitive_guard_count; i++) {
        VALUE owner = primitive_guards[i].owner;
        ID method = primitive_guards[i].method;
        if (!liquid_method_basic_definition_p(owner, method)) compiler_ready = false;
        primitive_guards[i].entry = (VALUE)rb_callable_method_entry(owner, method);
    }
    if (!NIL_P(constant_vm) && liquid_method_basic_definition_p(CLASS_OF(constant_vm), id_stat))
        compiler_stat = liquid_method_handle(rb_obj_method(constant_vm, ID2SYM(id_stat)));
    return compiler_ready ? Qtrue : Qfalse;
}

bool variable_render_methods_standard(void)
{
    if (!compiler_registered) return false;
    for (size_t i = 0; i < 3; i++) {
        VALUE current = (VALUE)rb_callable_method_entry(cLiquidVariable, renderer_ids[i]);
        if (RARRAY_AREF(renderer_guard_entries, i) == current) continue;
        // Re-aliasing a builtin creates a new method entry with the same body.
        size_t gc = liquid_gc_count();
        bool standard = liquid_vm_render_methods_standard();
        if (gc != liquid_gc_count()) return false;
        if (!standard) return false;
        for (size_t j = 0; j < 3; j++)
            rb_ary_store(renderer_guard_entries, (long)j, (VALUE)rb_callable_method_entry(cLiquidVariable, renderer_ids[j]));
        break;
    }
    return true;
}

bool variable_render_traced(void)
{
    return ruby_vm_event_flags != 0;
}

bool variable_output_method_standard(void)
{
    return compiler_ready && !ruby_vm_event_flags && RARRAY_AREF(renderer_guard_entries, 2) ==
        (VALUE)rb_callable_method_entry(cLiquidVariable, renderer_ids[2]);
}

static bool native_compiler_methods_standard(variable_parse_args_t *args)
{
    VALUE context = args->parse_context;
    if (rb_get_alloc_func(compiler_body_class) != compiler_body_allocator) return false;
    if (CLASS_OF(context) != native_context_class || (!NIL_P(args->code_obj) && CLASS_OF(args->code_obj) != compiler_body_class)) return false;
    size_t validation_gc = liquid_gc_count();
    VALUE scanner = rb_ivar_get(context, id_string_scanner);
    VALUE receiver_classes[] = { Qnil, CLASS_OF(context), CLASS_OF(scanner) };
    VALUE epoch = Qundef;
    if (!NIL_P(compiler_stat)) {
        VALUE key = ID2SYM(id_constant_invalidations);
        epoch = liquid_method_call(1, &key, compiler_stat);
    }
    bool unchanged_constants = epoch != Qundef && epoch == compiler_epoch;
    for (long i = 0; i < method_guard_count; i++) {
        native_method_guard_t *guard = &method_guards[i];
        if (guard->constant) {
            if (!unchanged_constants) {
                if (!RTEST(native_constant_matches(Qnil, guard->owner, ID2SYM(guard->method), guard->entry, guard->snapshot))) return false;
            } else if (!NIL_P(guard->snapshot)) {
                if (RARRAY_LEN(guard->entry) != RARRAY_LEN(guard->snapshot)) return false;
                for (long j = 0; j < RARRAY_LEN(guard->entry); j++)
                    if (RARRAY_AREF(guard->entry, j) != RARRAY_AREF(guard->snapshot, j)) return false;
            }
        } else {
            if (!native_method_guard_current(guard)) return false;
            if (guard->public_call && rb_method_boundp(guard->owner, guard->method, 3) != 1) return false;
            if (guard->receiver && guard->receiver != 3) {
                VALUE klass = receiver_classes[guard->receiver];
                if (guard->receiver == 2 && RB_OBJ_FROZEN(scanner)) return false;
                if (klass != guard->owner && guard->entry != (VALUE)rb_callable_method_entry(klass, guard->method)) return false;
            }
        }
    }
    for (size_t i = 0; i < compiler_method_count; i++) {
        if (compiler_methods[i].control) continue;
        VALUE owner = compiler_methods[i].owner;
        ID method = compiler_methods[i].method;
        VALUE current_entry = (VALUE)rb_callable_method_entry(owner, method);
        if (compiler_methods[i].entry != current_entry) {
            if (!compiler_methods[i].builtin || !liquid_method_basic_definition_p(owner, method)) return false;
            compiler_methods[i].entry = current_entry;
        }
        if (compiler_methods[i].public_call && rb_method_boundp(owner, method, 3) != 1) return false;
    }
    if (NIL_P(compiler_constants)) return false;
    if (!unchanged_constants || NIL_P(compiler_constant_watchers)) {
        for (long i = 0; i < RARRAY_LEN(compiler_constants); i++) {
            VALUE spec = RARRAY_AREF(compiler_constants, i);
            VALUE expected = RARRAY_AREF(spec, 2);
            if (expected != compiler_body_class && expected != control_environment_class) continue;
            if (!RTEST(native_constant_matches(Qnil, RARRAY_AREF(spec, 0), RARRAY_AREF(spec, 1), expected, Qnil))) return false;
        }
    }
    VALUE klass = CLASS_OF(cLiquidVariable);
    if (!liquid_method_basic_definition_p(klass, id_new_native) ||
        !liquid_method_basic_definition_p(klass, id_allocate_native) ||
        rb_get_alloc_func(cLiquidVariable) != rb_get_alloc_func(rb_cObject)) return false;
    for (size_t i = 0; i < primitive_guard_count; i++) {
        VALUE owner = primitive_guards[i].owner;
        ID method = primitive_guards[i].method;
        VALUE current_entry = (VALUE)rb_callable_method_entry(owner, method);
        if (primitive_guards[i].entry != current_entry) {
            if (!liquid_method_basic_definition_p(owner, method)) return false;
            primitive_guards[i].entry = current_entry;
        }
        if (primitive_guards[i].public_call && rb_method_boundp(owner, method, 3) != 1) return false;
    }
    if (rb_get_alloc_func(cLiquidVariableLookup) != rb_get_alloc_func(rb_cObject) ||
        rb_get_alloc_func(cLiquidRangeLookup) != rb_get_alloc_func(rb_cObject) ||
        rb_get_alloc_func(native_parser_class) != rb_get_alloc_func(rb_cObject)) return false;
    if (validation_gc != liquid_gc_count()) return false;
    compiler_epoch = epoch;
    VALUE options = rb_ivar_get(context, id_options_native);
    if (CLASS_OF(options) != rb_cHash ||
        RTEST(rb_hash_lookup2(options, ID2SYM(id_stats_native), Qnil)) ||
        RTEST(rb_hash_lookup2(options, ID2SYM(rb_intern("stats_callbacks")), Qnil))) return false;
    if (!RTEST(rb_ivar_get(mLiquidC, id_enabled_native)) || RTEST(rb_ivar_get(context, id_disabled_native))) return false;
    VALUE mode = rb_ivar_get(context, id_mode_native);
    if (mode != ID2SYM(rb_intern("lax")) && mode != ID2SYM(rb_intern("warn")) && mode != ID2SYM(rb_intern("strict"))) return false;
    VALUE cache = rb_ivar_get(context, id_cache_native);
    if (RTEST(cache) && (CLASS_OF(cache) != rb_cHash || RB_OBJ_FROZEN(cache) || !native_string_cache(cache))) return false;
    return true;
}

// Structural hooks are needed only when entering the native control parser.
// A variable-only interval need not validate unrelated tag implementations.
static bool native_control_methods_standard(void)
{
    for (size_t i = 0; i < compiler_method_count; i++) {
        if (!compiler_methods[i].control) continue;
        VALUE owner = compiler_methods[i].owner;
        ID method = compiler_methods[i].method;
        VALUE current_entry = (VALUE)rb_callable_method_entry(owner, method);
        if (compiler_methods[i].entry != current_entry) {
            if (!compiler_methods[i].builtin || !liquid_method_basic_definition_p(owner, method)) return false;
            compiler_methods[i].entry = current_entry;
        }
        if (compiler_methods[i].public_call && rb_method_boundp(owner, method, 3) != 1) return false;
    }
    if (NIL_P(compiler_constants)) return false;
    for (long i = 0; i < RARRAY_LEN(compiler_constants); i++) {
        VALUE spec = RARRAY_AREF(compiler_constants, i);
        if (!RTEST(native_constant_matches(Qnil, RARRAY_AREF(spec, 0), RARRAY_AREF(spec, 1), RARRAY_AREF(spec, 2), Qnil))) return false;
    }
    for (long i = 0; i < RARRAY_LEN(compiler_ancestor_prefixes); i++) {
        VALUE pair = RARRAY_AREF(compiler_ancestor_prefixes, i);
        VALUE prefix = RARRAY_AREF(pair, 1);
        VALUE ancestors = rb_mod_ancestors(RARRAY_AREF(pair, 0));
        if (RARRAY_LEN(ancestors) < RARRAY_LEN(prefix)) return false;
        for (long j = 0; j < RARRAY_LEN(prefix); j++)
            if (RARRAY_AREF(ancestors, j) != RARRAY_AREF(prefix, j)) return false;
    }
    return native_control_binding(native_if_class, rb_intern("Condition"), native_condition_class) &&
        native_control_binding(native_if_class, rb_intern("ElseCondition"), control_else_class);
}

static VALUE native_fast_header(VALUE self, VALUE markup)
{
    if (!compiler_ready || ruby_vm_event_flags) return Qundef;
    VALUE klass = CLASS_OF(self);
    bool condition = klass == native_if_class || klass == native_unless_class;
    if (!condition && klass != native_for_class) return Qundef;
    const char *optout = getenv("LIQUID_C_NATIVE_TAGS");
    const char *parser_optout = getenv("LIQUID_C_NATIVE_PARSER");
    if ((optout && !strcmp(optout, "false")) || (parser_optout && !strcmp(parser_optout, "false"))) return Qundef;
    VALUE context = rb_ivar_get(self, id_parse_context_native);
    VALUE mode = rb_ivar_get(context, id_mode_native);
    if (mode != ID2SYM(rb_intern("warn")) && mode != ID2SYM(rb_intern("strict"))) return Qundef;
    variable_parse_args_t args = { .parse_context = context, .code_obj = Qnil };
    size_t gc = liquid_gc_count();
    if (!native_compiler_methods_standard(&args) || !native_control_methods_standard() || gc != liquid_gc_count()) return Qundef;
    if (condition && (rb_get_alloc_func(native_condition_class) != rb_get_alloc_func(rb_cObject) ||
        !liquid_method_basic_definition_p(CLASS_OF(native_condition_class), id_new_native) ||
        !liquid_method_basic_definition_p(CLASS_OF(native_condition_class), id_allocate_native))) return Qundef;
    VALUE cache = rb_ivar_get(context, id_cache_native);
    VALUE result = native_parse_payload(markup, RTEST(cache) ? cache : Qnil, condition ? 1 : 2, true, true, NULL);
    if (NIL_P(result) || gc != liquid_gc_count() || ruby_vm_event_flags) return Qundef;
    VALUE payload = RARRAY_AREF(result, 0);
    native_publish_cache(Qnil, cache, RARRAY_AREF(result, 1));
    if (!condition) {
        for (size_t i = 0; i < 6; i++) rb_ivar_set(self, id_for_fields[i], RARRAY_AREF(payload, i));
        payload = Qnil;
    }
    RB_GC_GUARD(result);
    return payload;
}

static void native_restore_assembler(vm_assembler_t *code, const vm_assembler_t *saved,
    size_t instruction_size, size_t constant_size)
{
    for (size_t i = constant_size / sizeof(VALUE); i < c_buffer_size(&code->constants) / sizeof(VALUE); i++) {
        st_data_t key = ((VALUE *)code->constants.data)[i];
        st_delete(code->constants_table, &key, NULL);
    }
    code->instructions.data_end = code->instructions.data + instruction_size;
    code->constants.data_end = code->constants.data + constant_size;
    code->stack_size = saved->stack_size;
    code->max_stack_size = saved->max_stack_size;
    code->protected_stack_size = saved->protected_stack_size;
}

bool native_compiler_guard(variable_parse_args_t *args)
{
    variable_compile_guard_t *guard = args->guard;
    if (!compiler_ready || !guard || ruby_vm_event_flags || !method_guard_count) return false;
#ifdef LIQUID_C_TEST_ALLOC_FAILURES
    if (!NIL_P(native_parser_test_callback)) return false;
#endif
    size_t gc = liquid_gc_count();
    if (!guard->valid || gc != guard->gc_count) {
        guard->valid = false;
        guard->control_validated = false;
        VALUE mode = rb_ivar_get(args->parse_context, id_mode_native);
        if (mode != ID2SYM(rb_intern("lax")) && mode != ID2SYM(rb_intern("warn")) &&
            mode != ID2SYM(rb_intern("strict"))) return false;

        const char *optout = getenv("LIQUID_C_NATIVE_COMPILER");
        const char *parser_optout = getenv("LIQUID_C_NATIVE_PARSER");
        if ((optout && !strcmp(optout, "false")) || (parser_optout && !strcmp(parser_optout, "false"))) return false;

        if (!native_compiler_methods_standard(args) || gc != liquid_gc_count() || ruby_vm_event_flags) return false;
        guard->valid = true;
        guard->gc_count = gc;
        guard->cache = rb_ivar_get(args->parse_context, id_cache_native);
        guard->environment = Qnil;
        guard->tags = Qnil;
        guard->literals_checked = false;
        guard->control_checked = false;
    }
    return true;
}

bool native_control_guard(variable_parse_args_t *args)
{
    if (!native_compiler_guard(args)) return false;
    if (!args->guard->control_validated) {
        size_t gc = liquid_gc_count();
        bool standard = native_control_methods_standard();
        if (gc != liquid_gc_count() || ruby_vm_event_flags) {
            args->guard->valid = false;
            return false;
        }
        if (!standard) return false;
        args->guard->control_validated = true;
    }
    return true;
}

bool native_assignment_class_p(VALUE klass)
{
    return klass == native_assign_class;
}

static bool native_control_binding(VALUE lexical_owner, ID name, VALUE expected)
{
    VALUE lexical[] = { lexical_owner, mLiquid };
    for (size_t i = 0; i < sizeof(lexical) / sizeof(lexical[0]); i++) {
        VALUE owner = lexical[i];
        if (rb_const_defined_at(owner, name))
            return !RTEST(native_autoload_p(owner, name)) && rb_const_get_at(owner, name) == expected;
    }
    // The full ancestor prefix is verified by the control guard. Looking only
    // at defined constants cannot trigger autoload or const_missing callbacks.
    VALUE prefix = Qnil;
    for (long i = 0; i < RARRAY_LEN(compiler_ancestor_prefixes); i++) {
        VALUE pair = RARRAY_AREF(compiler_ancestor_prefixes, i);
        if (RARRAY_AREF(pair, 0) == lexical_owner) {
            prefix = RARRAY_AREF(pair, 1);
            break;
        }
    }
    if (NIL_P(prefix)) return false;
    for (long i = 1; i < RARRAY_LEN(prefix); i++) {
        VALUE owner = RARRAY_AREF(prefix, i);
        if (rb_const_defined_at(owner, name))
            return !RTEST(native_autoload_p(owner, name)) && rb_const_get_at(owner, name) == expected;
    }
    return false;
}

// Assign retains its ordinary Variable and Ruby renderer. Only supported,
// non-diagnostic construction stays inside the current native parse interval.
VALUE native_parse_assignment(variable_parse_args_t *args, VALUE klass, VALUE name, VALUE markup)
{
    if (!native_assignment_class_p(klass) || !native_control_guard(args)) return Qundef;
    ID last_match = rb_intern("last_match");
    if (!native_control_binding(native_assign_class, rb_intern("Variable"), cLiquidVariable) ||
        !native_control_binding(native_assign_class, rb_intern("Regexp"), rb_cRegexp) ||
        !liquid_method_basic_definition_p(CLASS_OF(rb_cRegexp), last_match) ||
        rb_method_boundp(CLASS_OF(rb_cRegexp), last_match, 3) != 1) return Qundef;
    const char *optout = getenv("LIQUID_C_NATIVE_TAGS");
    if (optout && !strcmp(optout, "false")) return Qundef;
    if (rb_get_alloc_func(klass) != rb_get_alloc_func(rb_cObject) ||
        (VALUE)rb_callable_method_entry(CLASS_OF(klass), id_new_native) != control_tag_new_entry ||
        !liquid_method_basic_definition_p(CLASS_OF(klass), id_allocate_native)) return Qundef;
    native_parser_t lhs = { .source = markup, .length = (size_t)RSTRING_LEN(markup) };
    native_next(&lhs);
    if (lhs.token != N_ID || native_word(&lhs, "contains") ||
        RSTRING_PTR(markup)[lhs.end - 1] == '?') return Qundef;
    size_t position = lhs.end;
    while (position < lhs.length && native_space((unsigned char)RSTRING_PTR(markup)[position])) position++;
    if (position == lhs.length || RSTRING_PTR(markup)[position++] != '=') return Qundef;
    while (position < lhs.length && native_space((unsigned char)RSTRING_PTR(markup)[position])) position++;
    size_t gc = liquid_gc_count();
    VALUE target = native_slice(&lhs, lhs.start, lhs.end);
    VALUE rhs = native_slice(&lhs, position, lhs.length);
    if (gc != liquid_gc_count()) { args->guard->valid = false; return Qundef; }
    VALUE cache = args->guard->cache;
    VALUE parsed = native_parse_payload(rhs, RTEST(cache) ? cache : Qnil, 0, true, true, NULL);
    if (NIL_P(parsed) || gc != liquid_gc_count() || ruby_vm_event_flags) {
        args->guard->valid = false;
        return Qundef;
    }
    VALUE line = rb_ivar_get(args->parse_context, rb_intern("@line_number"));
    VALUE variable = variable_from_parse(rhs, args->parse_context, line, RARRAY_AREF(parsed, 0), RARRAY_AREF(parsed, 1));
    if (gc != liquid_gc_count()) { args->guard->valid = false; return Qundef; }
    VALUE tag = rb_obj_alloc(klass);
    rb_ivar_set(tag, rb_intern("@tag_name"), name);
    rb_ivar_set(tag, rb_intern("@markup"), markup);
    rb_ivar_set(tag, id_parse_context_native, args->parse_context);
    rb_ivar_set(tag, rb_intern("@line_number"), line);
    rb_ivar_set(tag, rb_intern("@to"), target);
    rb_ivar_set(tag, rb_intern("@from"), variable);
    if (gc != liquid_gc_count() || ruby_vm_event_flags) {
        args->guard->valid = false;
        return Qundef;
    }
    native_publish_cache(Qnil, cache, RARRAY_AREF(parsed, 2));
    if (gc != liquid_gc_count()) args->guard->valid = false;
    RB_GC_GUARD(parsed);
    RB_GC_GUARD(variable);
    RB_GC_GUARD(rhs);
    RB_GC_GUARD(target);
    RB_GC_GUARD(markup);
    RB_GC_GUARD(tag);
    return tag;
}

bool native_include_class_p(VALUE klass)
{
    return klass == native_include_class;
}

VALUE native_parse_include(variable_parse_args_t *args, VALUE klass, VALUE name, VALUE markup)
{
    if (!native_include_class_p(klass) ||
        rb_ivar_get(args->parse_context, id_mode_native) != ID2SYM(rb_intern("warn")) ||
        !native_control_guard(args)) return Qundef;
    const char *optout = getenv("LIQUID_C_NATIVE_TAGS");
    if (optout && !strcmp(optout, "false")) return Qundef;
    if (rb_get_alloc_func(klass) != rb_get_alloc_func(rb_cObject) ||
        (VALUE)rb_callable_method_entry(CLASS_OF(klass), id_new_native) != control_tag_new_entry ||
        !liquid_method_basic_definition_p(CLASS_OF(klass), id_allocate_native)) return Qundef;
    size_t gc = liquid_gc_count();
    VALUE cache = args->guard->cache;
    VALUE parsed = native_parse_payload(markup, RTEST(cache) ? cache : Qnil, 4, true, true, args->guard);
    if (NIL_P(parsed) || gc != liquid_gc_count() || ruby_vm_event_flags) {
        args->guard->valid = false;
        return Qundef;
    }
    VALUE fields = RARRAY_AREF(parsed, 0);
    if (!RTEST(RARRAY_AREF(fields, 5)) &&
        (!liquid_method_basic_definition_p(rb_cFalseClass, rb_intern("==")) ||
        rb_method_boundp(rb_cFalseClass, rb_intern("=="), 3) != 1)) return Qundef;
    VALUE tag = rb_obj_alloc(klass);
    rb_ivar_set(tag, rb_intern("@tag_name"), name);
    rb_ivar_set(tag, rb_intern("@markup"), markup);
    rb_ivar_set(tag, id_parse_context_native, args->parse_context);
    rb_ivar_set(tag, rb_intern("@line_number"), rb_ivar_get(args->parse_context, rb_intern("@line_number")));
    const char *names[] = { "@template_name_expr", "@variable_name_expr", "@alias_name", "@is_for_loop", "@attributes" };
    for (size_t i = 0; i < 5; i++) {
        if ((i == 1 && !RTEST(RARRAY_AREF(fields, 5))) || (i == 2 && NIL_P(RARRAY_AREF(fields, i)))) continue;
        rb_ivar_set(tag, rb_intern(names[i]), RARRAY_AREF(fields, i));
    }
    if (gc != liquid_gc_count() || ruby_vm_event_flags) {
        args->guard->valid = false;
        return Qundef;
    }
    native_publish_cache(Qnil, cache, RARRAY_AREF(parsed, 1));
    if (gc != liquid_gc_count()) args->guard->valid = false;
    RB_GC_GUARD(parsed);
    return tag;
}

VALUE native_parse_capture(variable_parse_args_t *args, VALUE klass, VALUE name, VALUE markup)
{
    if (klass != native_capture_class ||
        rb_ivar_get(args->parse_context, id_mode_native) != ID2SYM(rb_intern("warn")) ||
        !native_control_guard(args)) return Qundef;
    const char *optout = getenv("LIQUID_C_NATIVE_TAGS");
    if (optout && !strcmp(optout, "false")) return Qundef;
    if (rb_get_alloc_func(klass) != rb_get_alloc_func(rb_cObject) ||
        (VALUE)rb_callable_method_entry(CLASS_OF(klass), id_new_native) != control_tag_new_entry ||
        !liquid_method_basic_definition_p(CLASS_OF(klass), id_allocate_native) ||
        rb_get_alloc_func(compiler_body_class) != compiler_body_allocator ||
        !liquid_method_basic_definition_p(CLASS_OF(compiler_body_class), id_new_native) ||
        !liquid_method_basic_definition_p(CLASS_OF(compiler_body_class), id_allocate_native)) return Qundef;
    native_parser_t parser = { .source = markup, .length = (size_t)RSTRING_LEN(markup) };
    native_next(&parser);
    if (parser.token != N_ID || native_word(&parser, "contains")) return Qundef;
    size_t start = parser.start, end = parser.end;
    native_next(&parser);
    if (parser.token != N_END) return Qundef;
    size_t gc = liquid_gc_count();
    VALUE target = native_slice(&parser, start, end);
    VALUE tag = rb_obj_alloc(klass);
    rb_ivar_set(tag, rb_intern("@tag_name"), name);
    rb_ivar_set(tag, rb_intern("@markup"), markup);
    rb_ivar_set(tag, id_parse_context_native, args->parse_context);
    rb_ivar_set(tag, rb_intern("@line_number"), rb_ivar_get(args->parse_context, rb_intern("@line_number")));
    rb_ivar_set(tag, rb_intern("@blank"), Qtrue);
    rb_ivar_set(tag, rb_intern("@to"), target);
    if (gc != liquid_gc_count() || ruby_vm_event_flags) {
        args->guard->valid = false;
        return Qundef;
    }
    RB_GC_GUARD(target);
    return tag;
}

int native_control_kind(VALUE klass)
{
    return klass == native_if_class || klass == native_unless_class ? 1 :
        (klass == native_for_class ? 2 : (klass == native_capture_class ? 3 : 0));
}

VALUE native_registered_tag(variable_parse_args_t *args, VALUE environment, VALUE name)
{
    if (!args->guard->valid || args->guard->gc_count != liquid_gc_count()) return Qundef;
    if (!native_compiler_guard(args) || CLASS_OF(environment) != control_environment_class) return Qundef;
    variable_compile_guard_t *guard = args->guard;
    VALUE tags = guard->tags;
    if (guard->environment != environment) {
        tags = rb_ivar_get(environment, rb_intern("@tags"));
        size_t gc = liquid_gc_count();
        if (CLASS_OF(tags) != rb_cHash || !native_string_cache(tags) ||
            !liquid_method_basic_definition_p(rb_cHash, rb_intern("default")) ||
            !NIL_P(native_hash_property(tags, HASH_DEFAULT_PROC_READER)) ||
            !NIL_P(native_hash_property(tags, HASH_DEFAULT_READER)) || gc != liquid_gc_count()) return Qundef;
        guard->environment = environment;
        guard->tags = tags;
    }
    return rb_hash_lookup2(tags, name, Qnil);
}

VALUE native_control_header(variable_parse_args_t *args, VALUE markup, int kind, bool commit)
{
    if (!native_control_guard(args)) return Qnil;
    if (!args->guard->control_checked) {
        args->guard->control_checked = true;
        args->guard->control_enabled = false;
        VALUE mode = rb_ivar_get(args->parse_context, id_mode_native);
        if (mode != ID2SYM(rb_intern("warn")) && mode != ID2SYM(rb_intern("strict"))) return Qnil;

        const char *optout = getenv("LIQUID_C_NATIVE_TAGS");
        if (optout && !strcmp(optout, "false")) return Qnil;
        VALUE classes[] = { native_condition_class, control_else_class, native_if_class, native_unless_class, native_for_class };
        for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
            VALUE klass = classes[i];
            bool original_new = i < 2 ? liquid_method_basic_definition_p(CLASS_OF(klass), id_new_native) :
                (VALUE)rb_callable_method_entry(CLASS_OF(klass), id_new_native) == control_tag_new_entry;
            if (rb_get_alloc_func(klass) != rb_get_alloc_func(rb_cObject) || !original_new ||
                !liquid_method_basic_definition_p(CLASS_OF(klass), id_allocate_native)) return Qnil;
        }
        if (rb_get_alloc_func(compiler_body_class) != compiler_body_allocator ||
            !liquid_method_basic_definition_p(CLASS_OF(compiler_body_class), id_new_native) ||
            !liquid_method_basic_definition_p(CLASS_OF(compiler_body_class), id_allocate_native)) return Qnil;
        args->guard->control_enabled = true;
    }
    if (!args->guard->control_enabled) return Qnil;
    size_t gc = liquid_gc_count();
    VALUE cache = args->guard->cache;
    VALUE result = native_parse_payload(markup, RTEST(cache) ? cache : Qnil, kind == 1 ? 1 : 2, true, true, args->guard);
    if (NIL_P(result) || gc != liquid_gc_count() || ruby_vm_event_flags) return Qnil;
    if (commit) native_publish_cache(Qnil, cache, RARRAY_AREF(result, 1));
    RB_GC_GUARD(result);
    return result;
}

void native_control_for_fields(VALUE tag, VALUE payload)
{
    for (size_t i = 0; i < 6; i++) rb_ivar_set(tag, id_for_fields[i], RARRAY_AREF(payload, i));
}

void native_control_commit(variable_parse_args_t *args, VALUE header)
{
    native_publish_cache(Qnil, args->guard->cache, RARRAY_AREF(header, 1));
}

void native_control_attach(variable_parse_args_t *args, VALUE condition, VALUE body)
{
    if (native_control_guard(args) && native_control_condition(condition))
        rb_ivar_set(condition, rb_intern("@attachment"), body);
    else {
        args->guard->valid = false;
        rb_funcallv_public(condition, rb_intern("attach"), 1, &body);
    }
}

VALUE native_control_else(variable_parse_args_t *args)
{
    if (!native_control_guard(args) || rb_get_alloc_func(control_else_class) != rb_get_alloc_func(rb_cObject)) {
        args->guard->valid = false;
        return rb_funcall(control_else_class, id_new_native, 0);
    }
    size_t gc = liquid_gc_count();
    VALUE node = rb_obj_alloc(control_else_class);
    if (gc != liquid_gc_count()) {
        args->guard->valid = false;
        rb_funcall(node, rb_intern("initialize"), 0);
    } else {
        rb_ivar_set(node, rb_intern("@left"), Qnil);
        rb_ivar_set(node, rb_intern("@operator"), Qnil);
        rb_ivar_set(node, rb_intern("@right"), Qnil);
        rb_ivar_set(node, rb_intern("@child_relation"), Qnil);
        rb_ivar_set(node, rb_intern("@child_condition"), Qnil);
    }
    RB_GC_GUARD(node);
    return node;
}

bool native_control_condition(VALUE node)
{
    return CLASS_OF(node) == native_condition_class || CLASS_OF(node) == control_else_class;
}

typedef struct { variable_parse_args_t *args; VALUE tag; } native_finish_t;

static void native_finish_body(variable_parse_args_t *args, VALUE body, const char *method)
{
    if (!native_control_guard(args) || CLASS_OF(body) != compiler_body_class) args->guard->valid = false;
    rb_funcallv_public(body, rb_intern(method), 0, NULL);
}

static VALUE native_finish_attachment(native_finish_t *finish, VALUE condition)
{
    if (native_control_guard(finish->args) && native_control_condition(condition))
        return rb_ivar_get(condition, rb_intern("@attachment"));
    finish->args->guard->valid = false;
    return rb_funcallv_public(condition, rb_intern("attachment"), 0, NULL);
}

static VALUE native_finish_condition(RB_BLOCK_CALL_FUNC_ARGLIST(condition, opaque))
{
    native_finish_t *finish = (void *)opaque;
    VALUE blank;
    if (native_control_guard(finish->args) && native_control_kind(CLASS_OF(finish->tag)))
        blank = rb_ivar_get(finish->tag, rb_intern("@blank"));
    else {
        finish->args->guard->valid = false;
        blank = rb_funcall(finish->tag, rb_intern("blank?"), 0);
    }
    if (RTEST(blank)) native_finish_body(finish->args, native_finish_attachment(finish, condition), "remove_blank_strings");
    native_finish_body(finish->args, native_finish_attachment(finish, condition), "freeze");
    return Qnil;
}

void native_control_finish(variable_parse_args_t *args, VALUE tag, int kind)
{
    if (kind == 3) {
        native_finish_body(args, rb_ivar_get(tag, rb_intern("@body")), "freeze");
        return;
    }
    if (!args->guard->valid || !args->guard->control_validated || !native_control_guard(args)) {
        args->guard->valid = false;
        liquid_method_call(1, &tag, control_helpers[kind - 1]);
        return;
    }
    if (kind == 1) {
        native_finish_t finish = { args, tag };
        rb_block_call(rb_ivar_get(tag, rb_intern("@blocks")), rb_intern("reverse_each"), 0, NULL,
            native_finish_condition, (VALUE)&finish);
    } else {
        if (RTEST(rb_ivar_get(tag, rb_intern("@blank")))) {
            VALUE otherwise = rb_ivar_get(tag, rb_intern("@else_block"));
            if (!NIL_P(otherwise)) native_finish_body(args, otherwise, "remove_blank_strings");
            native_finish_body(args, rb_ivar_get(tag, rb_intern("@for_block")), "remove_blank_strings");
        }
        VALUE otherwise = rb_ivar_get(tag, rb_intern("@else_block"));
        if (!NIL_P(otherwise)) native_finish_body(args, otherwise, "freeze");
        native_finish_body(args, rb_ivar_get(tag, rb_intern("@for_block")), "freeze");
    }
}

bool native_compile_variable(variable_parse_args_t *args, VALUE line_number)
{
    if (!compiler_ready || !args->guard || ruby_vm_event_flags) return false;
    // The tokenizer owns and pins the frozen source during parsing.
    VALUE source = args->source;
    size_t offset = (size_t)(args->markup - RSTRING_PTR(source));
    size_t length = (size_t)(args->markup_end - args->markup);
    int coderange = ENC_CODERANGE_UNKNOWN;
    rb_str_coderange_scan_restartable(args->markup, args->markup_end, utf8_encoding, &coderange);
    if (coderange == ENC_CODERANGE_BROKEN || coderange == ENC_CODERANGE_UNKNOWN) return false;
    native_parser_t parser = { .source = source, .cache = Qnil,
        .pending = Qnil, .position = offset, .length = offset + length, .code = args->code, .guarded = true, .compact_pending = true };
    native_parser_t probe = parser, validated_name;
    if (!native_validate_variable(&probe, &validated_name)) return false;
    if (!native_compiler_guard(args)) return false;
    variable_compile_guard_t *guard = args->guard;
    size_t gc = liquid_gc_count();
    parser.cache = RTEST(guard->cache) ? guard->cache : Qnil;
    parser.initial_gc_count = gc;
    // The descriptor owns its markup bytes independently of the tokenizer.
    // Temporary parsing uses offsets into the tokenizer's pinned source.
    VALUE node = variable_placeholder_new(source, offset, length, args->parse_context, line_number);
    if (gc != liquid_gc_count() || ruby_vm_event_flags) {
        guard->valid = false;
        return false;
    }
    vm_assembler_t saved = *args->code;
    size_t instruction_size = c_buffer_size(&saved.instructions);
    size_t constant_size = c_buffer_size(&saved.constants);
    vm_assembler_add_unique_variable(args->code, line_number, node);
    args->code->protected_stack_size = args->code->stack_size;
    // Reuse the lexical preflight without copying its earlier cache/GC state.
    native_parser_t name_probe = parser;
    name_probe.position = validated_name.position;
    name_probe.start = validated_name.start;
    name_probe.end = validated_name.end;
    name_probe.token = validated_name.token;
    VALUE result = native_variable_body_probed((VALUE)&parser, &name_probe);
    if (NIL_P(result) || gc != liquid_gc_count() || ruby_vm_event_flags) {
        guard->valid = false;
        native_restore_assembler(args->code, &saved, instruction_size, constant_size);
        return false;
    }
    variable_placeholder_set(node, parser.variable_name, parser.variable_filters);
    vm_assembler_add_pop_write(args->code);
    // Only builtin Hash operations on verified plain String keys execute here.
    if (RB_TYPE_P(parser.pending, T_STRING)) native_publish_entry(parser.pending, parser.pending_value, parser.cache);
    else native_publish_cache(Qnil, parser.cache, parser.pending);
    if (gc != liquid_gc_count()) guard->valid = false;
    RB_GC_GUARD(result);
    RB_GC_GUARD(node);
    RB_GC_GUARD(source);
    RB_GC_GUARD(parser.pending);
    RB_GC_GUARD(parser.pending_value);
    return true;
}
#else
#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY
static VALUE native_fast_header(VALUE self, VALUE markup) { return Qundef; }
#endif
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
#endif

void liquid_define_native_parser(void)
{
#if defined(HAVE_RB_CALLABLE_METHOD_ENTRY) && defined(HAVE_RUBY_VM_EVENT_FLAGS)
    rb_global_variable(&compiler_guard_specs);
    rb_global_variable(&renderer_guard_entries);
    rb_global_variable(&compiler_body_class);
    rb_global_variable(&compiler_constants);
    rb_global_variable(&native_assign_class);
    rb_global_variable(&native_capture_class);
    rb_global_variable(&native_include_class);
    rb_global_variable(&compiler_constant_watchers);
    rb_global_variable(&compiler_ancestor_prefixes);
    rb_global_variable(&control_else_class);
    rb_global_variable(&control_environment_class);
    rb_global_variable(&control_tag_new_entry);
    for (size_t i = 0; i < 2; i++) rb_global_variable(&control_helpers[i]);
    rb_define_singleton_method(mLiquidC, "native_register_control", native_register_control, 4);
    rb_global_variable(&compiler_stat);
    rb_global_variable(&compiler_epoch);
    rb_define_singleton_method(mLiquidC, "native_register_compiler", native_register_compiler, 2);
    rb_define_singleton_method(mLiquidC, "native_install_compiler_context", native_install_compiler_context, 0);
#endif
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
    id_freeze_native = rb_intern("freeze");
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
#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY
    rb_global_variable(&native_if_parse_entry);
    rb_global_variable(&native_for_parse_entry);
    rb_global_variable(&native_switching_module);
    for (size_t i = 0; i < 3; i++) rb_global_variable(&native_context_entries[i]);
#endif
    rb_global_variable(&native_context_class);
    rb_global_variable(&native_case_class);
    native_context_class = rb_const_get(mLiquid, rb_intern("ParseContext"));
    native_case_class = rb_const_get(mLiquid, rb_intern("Case"));
    native_if_class = rb_const_get(mLiquid, rb_intern("If"));
    native_unless_class = rb_const_get(mLiquid, rb_intern("Unless"));
    native_for_class = rb_const_get(mLiquid, rb_intern("For"));
#if defined(HAVE_RB_CALLABLE_METHOD_ENTRY) && defined(HAVE_RUBY_VM_EVENT_FLAGS)
    rb_define_singleton_method(mLiquidC, "native_try_parse_variable", native_try_variable, 3);
#endif
    rb_define_singleton_method(mLiquidC, "native_install_case_parser", native_install_case_parser, 0);
    rb_define_singleton_method(mLiquidC, "native_install_header_parser", native_install_header_parser, 2);
    rb_define_singleton_method(mLiquidC, "native_install_strict_context", native_install_strict_context, 0);
    rb_define_singleton_method(mLiquidC, "native_parser_tracing?", native_parser_tracing, 0);
    rb_define_singleton_method(mLiquidC, "native_variable_frontend", native_variable_frontend, 3);
    rb_define_private_method(rb_const_get(mLiquid, rb_intern("Variable")), "liquid_c_native_parse", native_variable_frontend_method, 1);
    rb_define_singleton_method(mLiquidC, "native_enable_variable_frontend", native_enable_variable_frontend, 0);
#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY
    rb_define_singleton_method(mLiquidC, "native_constant_watchers_supported?", native_watchers_supported, 1);
    rb_define_singleton_method(mLiquidC, "native_parser_register_guards", native_register_guards, 3);
    rb_define_singleton_method(mLiquidC, "native_parser_methods_compatible?", native_methods_compatible, 2);
#endif
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
