#include "liquid.h"
#include "context.h"

static ID id_has_key, id_aref, id_fetch, id_to_liquid_value;
static ID id_first, id_last, id_ivar_strict_variables;

static VALUE string_lookup_first_or_last(VALUE string, VALUE key, ID command)
{
    VALUE index;
    if (command == id_first && RSTRING_LEN(key) == 5) {
        index = INT2FIX(0);
    } else if (command == id_last && RSTRING_LEN(key) == 4) {
        index = INT2FIX(-1);
    } else {
        return Qundef;
    }

    VALUE character = rb_funcall(string, id_aref, 1, index);
    if (!RTEST(character)) {
        return rb_utf8_str_new_cstr("");
    }

    return character;
}

VALUE variable_lookup_key(VALUE context, VALUE object, VALUE key, bool is_command)
{
    if (rb_respond_to(key, id_to_liquid_value))
        key = rb_funcall(key, id_to_liquid_value, 0);

    if (rb_respond_to(object, id_aref) && (
        (rb_respond_to(object, id_has_key) && RTEST(rb_funcall(object, id_has_key, 1, key))) ||
        (rb_obj_is_kind_of(key, rb_cInteger) && rb_respond_to(object, id_fetch))
    )) {
        if (RTEST(rb_ivar_get(context, id_ivar_strict_variables)) &&
            rb_respond_to(object, id_has_key) && !RTEST(rb_funcall(object, id_has_key, 1, key)))
            context_raise_undefined_variable(key);
        VALUE next_object = rb_funcall(object, id_aref, 1, key);
        next_object = materialize_proc(context, object, key, next_object);
        return nested_value_to_liquid_and_set_context(next_object, context);
    }

    if (is_command) {
        ID intern_key = rb_to_id(key);
        if (rb_respond_to(object, intern_key)) {
            VALUE next_object = rb_funcall(object, intern_key, 0);
            return nested_value_to_liquid_and_set_context(next_object, context);
        }

        if (RB_TYPE_P(object, T_STRING) && RB_TYPE_P(key, T_STRING)) {
            VALUE character = string_lookup_first_or_last(object, key, intern_key);
            if (character != Qundef) {
                if (rb_respond_to(character, id_set_context))
                    rb_funcall(character, id_set_context, 1, context);
                return character;
            }
        }
    }

    context_maybe_raise_undefined_variable(context, key);
    return Qundef;
}

void liquid_define_variable_lookup(void)
{
    id_has_key = rb_intern("key?");
    id_aref = rb_intern("[]");
    id_fetch = rb_intern("fetch");
    id_to_liquid_value = rb_intern("to_liquid_value");
    id_first = rb_intern("first");
    id_last = rb_intern("last");
    id_ivar_strict_variables = rb_intern("@strict_variables");
}
