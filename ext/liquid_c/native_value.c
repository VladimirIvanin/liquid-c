#include "liquid.h"
#include "context.h"

#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY
extern const void *rb_callable_method_entry(VALUE klass, ID mid);
static VALUE identity_entries[8];
static bool identity_registered;
static VALUE register_identity_methods(VALUE self, VALUE enabled)
{
    Check_Type(enabled, T_ARRAY);
    if (RARRAY_LEN(enabled) != 8) rb_raise(rb_eArgError, "invalid identity method flags");
    if (identity_registered) rb_raise(rb_eRuntimeError, "identity methods already registered");
    VALUE owners[] = { rb_cString, rb_cArray, rb_cHash, rb_cNumeric, rb_cRange,
        rb_cTrueClass, rb_cFalseClass, rb_cNilClass };
    for (long i = 0; i < 8; i++) {
        identity_entries[i] = RTEST(RARRAY_AREF(enabled, i)) ?
            (VALUE)rb_callable_method_entry(owners[i], id_to_liquid) : 0;
        rb_gc_register_address(&identity_entries[i]);
    }
    identity_registered = true;
    return Qnil;
}

VALUE liquid_value_to_liquid(VALUE value)
{
    int index;
    switch (TYPE(value)) {
        case T_STRING: index = 0; break;
        case T_ARRAY: index = 1; break;
        case T_HASH: index = 2; break;
        case T_FIXNUM: case T_BIGNUM: case T_FLOAT: index = 3; break;
        case T_STRUCT: index = rb_obj_is_kind_of(value, rb_cRange) ? 4 : -1; break;
        case T_TRUE: index = 5; break;
        case T_FALSE: index = 6; break;
        case T_NIL: index = 7; break;
        default: index = -1; break;
    }
    if (index >= 0 && identity_entries[index] && identity_entries[index] ==
        (VALUE)rb_callable_method_entry(CLASS_OF(value), id_to_liquid)) return value;
    return rb_funcall(value, id_to_liquid, 0);
}
#endif

void liquid_define_native_values(void)
{
#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY
    rb_define_singleton_method(mLiquidC, "native_register_identity_methods", register_identity_methods, 1);
#endif
}
