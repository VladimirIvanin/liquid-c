#if !defined(LIQUID_H)
#define LIQUID_H

#include <ruby.h>
#include <ruby/encoding.h>
#include <stdbool.h>

#ifdef HAVE_RB_METHOD_BASIC_DEFINITION_P
static inline bool liquid_method_basic_definition_p(VALUE klass, ID method)
{
    return rb_method_basic_definition_p(klass, method);
}
#else
bool liquid_method_basic_definition_p(VALUE klass, ID method);
#endif

static inline VALUE liquid_method_handle(VALUE method)
{
#ifdef HAVE_RB_METHOD_CALL
    return method;
#else
    return rb_funcall(method, rb_intern("to_proc"), 0);
#endif
}

static inline VALUE liquid_method_call(int argc, const VALUE *argv, VALUE method)
{
#ifdef HAVE_RB_METHOD_CALL
    return rb_method_call(argc, argv, method);
#else
    return rb_proc_call(method, rb_ary_new_from_values(argc, argv));
#endif
}

#ifdef HAVE_RB_GC_COUNT
static inline size_t liquid_gc_count(void) { return rb_gc_count(); }
#else
size_t liquid_gc_count(void);
#endif

#ifdef HAVE_RUBY_STACK_CHECK
static inline bool liquid_stack_check(void) { return ruby_stack_check(); }
#else
bool liquid_stack_check(void);
#endif

static inline VALUE liquid_big_lshift(VALUE value, VALUE shift)
{
#ifdef HAVE_RB_BIG_LSHIFT
    return rb_big_lshift(value, shift);
#else
    return rb_funcall(value, rb_intern("<<"), 1, shift);
#endif
}

static inline VALUE liquid_big_or(VALUE value, VALUE mask)
{
#ifdef HAVE_RB_BIG_OR
    return rb_big_or(value, mask);
#else
    return rb_funcall(value, rb_intern("|"), 1, mask);
#endif
}

static inline double liquid_str_to_dbl(VALUE string, int strict)
{
#ifdef HAVE_RB_STR_TO_DBL
    return rb_str_to_dbl(string, strict);
#else
    return rb_cstr_to_dbl(StringValueCStr(string), strict);
#endif
}

static inline VALUE liquid_obj_init_copy(VALUE self, VALUE other)
{
#ifdef HAVE_RB_OBJ_INIT_COPY
    return rb_obj_init_copy(self, other);
#else
    rb_check_frozen(self);
    if (TYPE(self) != TYPE(other) || rb_obj_class(self) != rb_obj_class(other))
        rb_raise(rb_eTypeError, "initialize_copy should take same class object");
    return self;
#endif
}

extern ID id_evaluate;
extern ID id_to_liquid;
extern ID id_to_s;
extern ID id_call;
extern ID id_compile_evaluate;
extern ID id_ivar_line_number;

extern VALUE mLiquid, mLiquidC, cLiquidVariable, cLiquidTemplate, cLiquidBlockBody;
extern VALUE cLiquidVariableLookup, cLiquidRangeLookup;
extern VALUE cLiquidArgumentError, cLiquidSyntaxError, cMemoryError;
extern rb_encoding *utf8_encoding;
extern int utf8_encoding_index;

__attribute__((noreturn)) void raise_non_utf8_encoding_error(VALUE string, const char *string_name);

static inline void check_utf8_encoding(VALUE string, const char *string_name)
{
    if (RB_UNLIKELY(RB_ENCODING_GET_INLINED(string) != utf8_encoding_index))
        raise_non_utf8_encoding_error(string, string_name);
}

#ifndef RB_LIKELY
// RB_LIKELY added in Ruby 2.4
#define RB_LIKELY(x) (__builtin_expect(!!(x), 1))
#endif

#endif
