#include "liquid.h"
#include "context.h"
#include "variable_lookup.h"
#include "variable.h"
#include "liquid_vm.h"
#include "expression.h"
#include "document_body.h"

static VALUE cLiquidUndefinedVariable;
ID id_aset, id_set_context;
extern ID id_vm;
static ID id_has_key, id_aref, id_strainer, id_filter_methods_hash, id_strict_variables, id_global_filter;
static ID id_ivar_global_filter, id_ivar_strict_filters;
static ID id_ivar_scopes, id_ivar_environments, id_ivar_static_environments, id_ivar_strict_variables, id_ivar_interrupts, id_ivar_resource_limits, id_ivar_document_body;

void context_internal_init(VALUE context_obj, context_t *context)
{
    context->self = context_obj;

    context->environments = rb_ivar_get(context_obj, id_ivar_environments);
    Check_Type(context->environments, T_ARRAY);

    context->static_environments = rb_ivar_get(context_obj, id_ivar_static_environments);
    Check_Type(context->static_environments, T_ARRAY);

    context->scopes = rb_ivar_get(context_obj, id_ivar_scopes);
    Check_Type(context->scopes, T_ARRAY);

    context->interrupts = rb_ivar_get(context->self, id_ivar_interrupts);
    Check_Type(context->interrupts, T_ARRAY);

    context->resource_limits_obj = rb_ivar_get(context->self, id_ivar_resource_limits);

    context_refresh(context);
}

void context_refresh(context_t *context)
{
    VALUE strainer = rb_funcall(context->self, id_strainer, 0);
    Check_Type(strainer, T_OBJECT);
    VALUE filter_methods = rb_funcall(rb_obj_class(strainer), id_filter_methods_hash, 0);
    Check_Type(filter_methods, T_HASH);
    VALUE global_filter = rb_funcall(context->self, id_global_filter, 0);

    context->strainer = strainer;
    context->filter_methods = filter_methods;
    context->global_filter = global_filter;
}

void context_mark(context_t *context)
{
    rb_gc_mark(context->self);
    rb_gc_mark(context->environments);
    rb_gc_mark(context->static_environments);
    rb_gc_mark(context->scopes);
    rb_gc_mark(context->strainer);
    rb_gc_mark(context->filter_methods);
    rb_gc_mark(context->interrupts);
    rb_gc_mark(context->resource_limits_obj);
    rb_gc_mark(context->global_filter);
}

static context_t *context_from_obj(VALUE self)
{
    return &vm_from_context(self)->context;
}

static VALUE context_evaluate(VALUE self, VALUE expression)
{
    return rb_respond_to(expression, id_evaluate) ? rb_funcall(expression, id_evaluate, 1, self) : expression;
}

void context_raise_undefined_variable(VALUE key)
{
    rb_enc_raise(utf8_encoding, cLiquidUndefinedVariable, "undefined variable %"PRIsVALUE, key);
}

void context_maybe_raise_undefined_variable(VALUE self, VALUE key)
{
    if (RTEST(rb_funcall(self, id_strict_variables, 0)))
        context_raise_undefined_variable(key);
}

static bool uses_builtin_hash_lookup(VALUE hash)
{
    return RB_TYPE_P(hash, T_HASH) && RBASIC_CLASS(hash) == rb_cHash &&
        liquid_method_basic_definition_p(rb_cHash, id_aref) &&
        liquid_method_basic_definition_p(rb_cHash, id_has_key);
}

static bool environments_find_variable(context_t *context, VALUE environments, VALUE key,
    VALUE raise_on_not_found, VALUE *variable_out)
{
    Check_Type(environments, T_ARRAY);

    for (long i = 0; i < RARRAY_LEN(environments); i++) {
        bool strict = RTEST(rb_ivar_get(context->self, id_ivar_strict_variables)) && RTEST(raise_on_not_found);
        VALUE environment = RARRAY_AREF(environments, i);
        VALUE variable;
        if (uses_builtin_hash_lookup(environment)) {
            if (strict) {
                variable = rb_hash_lookup2(environment, key, Qundef);
                if (variable == Qundef) {
                    context_raise_undefined_variable(key);
                }
            } else {
                variable = rb_hash_aref(environment, key);
            }
        } else {
            if (strict && rb_respond_to(environment, id_has_key) &&
                !RTEST(rb_funcall(environment, id_has_key, 1, key))) {
                context_raise_undefined_variable(key);
            }
            variable = rb_funcall(environment, id_aref, 1, key);
        }

        variable = materialize_proc(context->self, environment, key, variable);
        if (!NIL_P(variable) || (RTEST(rb_ivar_get(context->self, id_ivar_strict_variables)) && RTEST(raise_on_not_found))) {
            *variable_out = variable;
            return true;
        }
    }
    return false;
}

static VALUE context_find_variable_with_ruby(VALUE self, VALUE key, VALUE raise_on_not_found)
{
    VALUE keyword_arguments = rb_hash_new();
    rb_hash_aset(keyword_arguments, ID2SYM(rb_intern("raise_on_not_found")), raise_on_not_found);

    VALUE arguments[] = { key, keyword_arguments };
    return rb_funcallv_kw(self, rb_intern("ruby_find_variable"), 2, arguments, RB_PASS_KEYWORDS);
}

VALUE context_find_variable(context_t *context, VALUE key, VALUE raise_on_not_found)
{
    VALUE self = context->self;
    bool is_self_lookup = RB_TYPE_P(key, T_STRING) &&
        RSTRING_LEN(key) == 4 && memcmp(RSTRING_PTR(key), "self", 4) == 0;

    if (is_self_lookup) {
        return context_find_variable_with_ruby(self, key, raise_on_not_found);
    }

    VALUE scope = Qnil, variable = Qnil;

    VALUE scopes = context->scopes;
    for (long i = 0; i < RARRAY_LEN(scopes); i++) {
        VALUE this_scope = RARRAY_AREF(scopes, i);
        if (RB_LIKELY(uses_builtin_hash_lookup(this_scope))) {
            // Does not invoke any default value proc, this is equivalent in
            // cost and semantics to #key? but loads the value as well
            variable = rb_hash_lookup2(this_scope, key, Qundef);
            if (variable != Qundef) {
                scope = this_scope;
                goto variable_found;
            }
        } else if (RTEST(rb_funcall(this_scope, id_has_key, 1, key))) {
            // Slow path: It is valid to pass a non-hash value to Liquid as a
            // scope if it supports #key? and #[]
            variable = rb_funcall(this_scope, id_aref, 1, key);
            scope = this_scope;
            goto variable_found;
        }
    }

    if (environments_find_variable(context, context->environments, key, raise_on_not_found, &variable))
        goto convert_variable;

    if (environments_find_variable(context, context->static_environments, key, raise_on_not_found, &variable))
        goto convert_variable;

    variable = Qnil;

variable_found:
    variable = materialize_proc(self, scope, key, variable);
convert_variable:
    variable = value_to_liquid_and_set_context(variable, self);

    return variable;
}

static VALUE context_find_variable_method(VALUE self, VALUE key, VALUE raise_on_not_found)
{
    return context_find_variable(context_from_obj(self), key, raise_on_not_found);
}

static VALUE context_set_strict_variables(VALUE self, VALUE strict_variables)
{
    rb_ivar_set(self, id_ivar_strict_variables, strict_variables);
    return strict_variables;
}

static VALUE context_set_global_filter(VALUE self, VALUE filter)
{
    rb_ivar_set(self, id_ivar_global_filter, filter);
    VALUE vm_obj = rb_attr_get(self, id_vm);
    if (!NIL_P(vm_obj)) {
        vm_t *vm = DATA_PTR(vm_obj);
        if (vm->context.self == self)
            vm->context.global_filter = filter;
    }
    return filter;
}

static VALUE context_set_strict_filters(VALUE self, VALUE strict_filters)
{
    rb_ivar_set(self, id_ivar_strict_filters, strict_filters);
    return strict_filters;
}

static VALUE context_add_filters(VALUE self, VALUE filters)
{
    VALUE result = rb_funcall(self, rb_intern("ruby_add_filters"), 1, filters);
    VALUE vm_obj = rb_attr_get(self, id_vm);
    if (!NIL_P(vm_obj)) {
        vm_t *vm = DATA_PTR(vm_obj);
        if (vm->context.self == self) {
            vm->context.strainer = Qnil;
            vm->context.filter_methods = Qnil;
            vm->context_generation = 0;
            vm->context_revision++;
        }
    }
    return result;
}

// Shopify requires checking if we are filtering, so provide a
// way to do that in liquid-c until we figure out how we want to
// support that longer term.
VALUE context_filtering_p(VALUE self)
{
    return liquid_vm_filtering(self) ? Qtrue : Qfalse;
}

void liquid_define_context(void)
{
    id_has_key = rb_intern("key?");
    id_aset = rb_intern("[]=");
    id_aref = rb_intern("[]");
    id_set_context = rb_intern("context=");
    id_strainer = rb_intern("strainer");
    id_filter_methods_hash = rb_intern("filter_methods_hash");
    id_global_filter = rb_intern("global_filter");
    id_strict_variables = rb_intern("strict_variables");

    id_ivar_global_filter = rb_intern("@global_filter");
    id_ivar_strict_filters = rb_intern("@strict_filters");
    id_ivar_scopes = rb_intern("@scopes");
    id_ivar_environments = rb_intern("@environments");
    id_ivar_static_environments = rb_intern("@static_environments");
    id_ivar_strict_variables = rb_intern("@strict_variables");
    id_ivar_interrupts = rb_intern("@interrupts");
    id_ivar_resource_limits = rb_intern("@resource_limits");
    id_ivar_document_body = rb_intern("@document_body");

    cLiquidVariableLookup = rb_const_get(mLiquid, rb_intern("VariableLookup"));
    rb_global_variable(&cLiquidVariableLookup);

    cLiquidUndefinedVariable = rb_const_get(mLiquid, rb_intern("UndefinedVariable"));
    rb_global_variable(&cLiquidUndefinedVariable);

    VALUE cLiquidContext = rb_const_get(mLiquid, rb_intern("Context"));
    rb_define_method(cLiquidContext, "c_evaluate", context_evaluate, 1);
    rb_define_method(cLiquidContext, "c_find_variable", context_find_variable_method, 2);
    rb_define_method(cLiquidContext, "c_strict_variables=", context_set_strict_variables, 1);
    rb_define_method(cLiquidContext, "c_global_filter=", context_set_global_filter, 1);
    rb_define_method(cLiquidContext, "c_strict_filters=", context_set_strict_filters, 1);
    rb_define_method(cLiquidContext, "c_add_filters", context_add_filters, 1);
    rb_define_private_method(cLiquidContext, "c_filtering?", context_filtering_p, 0);
}
