#include "liquid.h"
#include "variable.h"
#include "expression.h"
#include "liquid_vm.h"

VALUE cLiquidCVariableExpression;

static VALUE cVariablePlaceholder;
static ID id_markup, id_context, id_line, id_name, id_filters;
static rb_alloc_func_t variable_allocator;

typedef struct {
    VALUE markup, context, line, name, filters, variable;
    uint32_t length;
    bool object_render;
    char markup_bytes[];
} variable_placeholder_t;

static void placeholder_mark(void *opaque)
{
    variable_placeholder_t *node = opaque;
    rb_gc_mark_movable(node->markup);
    rb_gc_mark_movable(node->context);
    rb_gc_mark_movable(node->line);
    rb_gc_mark_movable(node->name);
    rb_gc_mark_movable(node->filters);
    rb_gc_mark_movable(node->variable);
}

static void placeholder_compact(void *opaque)
{
    variable_placeholder_t *node = opaque;
    node->markup = rb_gc_location(node->markup);
    node->context = rb_gc_location(node->context);
    node->line = rb_gc_location(node->line);
    node->name = rb_gc_location(node->name);
    node->filters = rb_gc_location(node->filters);
    node->variable = rb_gc_location(node->variable);
}

static size_t placeholder_size(const void *opaque)
{
    const variable_placeholder_t *node = opaque;
    return node ? sizeof(*node) + node->length : 0;
}

static const rb_data_type_t placeholder_type = {
    "liquid_variable_placeholder",
    { placeholder_mark, RUBY_DEFAULT_FREE, placeholder_size, placeholder_compact },
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED
};

bool variable_placeholder_p(VALUE node)
{
    return rb_typeddata_is_kind_of(node, &placeholder_type);
}

bool variable_placeholder_object_render_p(VALUE self)
{
    variable_placeholder_t *node = RTYPEDDATA_DATA(self);
    return node->object_render;
}

void variable_placeholder_use_object(VALUE self)
{
    variable_placeholder_t *node = RTYPEDDATA_DATA(self);
    node->object_render = true;
}

VALUE variable_placeholder_new(VALUE source, size_t offset, size_t length, VALUE context, VALUE line_number)
{
    // Tokenizer spans are bounded by its source byte limit.
    assert(length <= UINT32_MAX && length <= SIZE_MAX - sizeof(variable_placeholder_t));
    vm_assembler_allocation_checkpoint();
    VALUE self = rb_data_typed_object_zalloc(cVariablePlaceholder, sizeof(variable_placeholder_t) + length, &placeholder_type);
    variable_placeholder_t *node = RTYPEDDATA_DATA(self);
    node->markup = node->context = node->line = node->name = node->filters = node->variable = Qnil;
    node->length = (uint32_t)length;
    memcpy(node->markup_bytes, RSTRING_PTR(source) + offset, length);
    RB_OBJ_WRITE(self, &node->context, context);
    RB_OBJ_WRITE(self, &node->line, line_number);
    RB_GC_GUARD(source);
    return self;
}

void variable_placeholder_set(VALUE self, VALUE name, VALUE filters)
{
    variable_placeholder_t *node = RTYPEDDATA_DATA(self);
    RB_OBJ_WRITE(self, &node->name, name);
    RB_OBJ_WRITE(self, &node->filters, filters);
}

VALUE variable_from_parse(VALUE markup, VALUE context, VALUE line, VALUE name, VALUE filters)
{
    VALUE variable = variable_allocator(cLiquidVariable);
    rb_ivar_set(variable, id_markup, markup);
    rb_ivar_set(variable, id_context, context);
    rb_ivar_set(variable, id_line, line);
    rb_ivar_set(variable, id_name, name);
    rb_ivar_set(variable, id_filters, filters);
    RB_GC_GUARD(variable);
    return variable;
}

VALUE variable_materialize(VALUE self)
{
    if (!variable_placeholder_p(self)) return self;
    variable_placeholder_t *node = RTYPEDDATA_DATA(self);
    if (!NIL_P(node->variable)) return node->variable;
    if (NIL_P(node->markup)) {
        VALUE markup = rb_enc_str_new(node->markup_bytes, node->length, utf8_encoding);
        if (NIL_P(node->markup)) RB_OBJ_WRITE(self, &node->markup, markup);
    }
    // This is the state of the original parse, not a parse using today's hooks.
    VALUE variable = variable_allocator(cLiquidVariable);
    if (!NIL_P(node->variable)) return node->variable;
    rb_ivar_set(variable, id_markup, node->markup);
    rb_ivar_set(variable, id_context, node->context);
    rb_ivar_set(variable, id_line, node->line);
    rb_ivar_set(variable, id_name, node->name);
    // Compact records retain parse-time expression identities. Only their
    // mutable Array containers are delayed until the AST becomes observable.
    VALUE filters = rb_ary_new();
    if (!NIL_P(node->filters)) {
        for (long i = 0; i < RARRAY_LEN(node->filters);) {
            VALUE name = rb_str_dup(rb_sym2str(RARRAY_AREF(node->filters, i++)));
            rb_enc_associate(name, utf8_encoding);
            long count = NUM2LONG(RARRAY_AREF(node->filters, i++));
            VALUE kwargs = RARRAY_AREF(node->filters, i++);
            VALUE args = rb_ary_new_capa(count);
            for (long j = 0; j < count; j++) rb_ary_push(args, RARRAY_AREF(node->filters, i++));
            VALUE filter = rb_ary_new_from_args(2, name, args);
            if (!NIL_P(kwargs)) rb_ary_push(filter, kwargs);
            rb_ary_push(filters, filter);
        }
    }
    rb_ivar_set(variable, id_filters, filters);
    if (NIL_P(node->variable)) RB_OBJ_WRITE(self, &node->variable, variable);
    else variable = node->variable;
    RB_GC_GUARD(variable);
    RB_GC_GUARD(self);
    return variable;
}

void internal_variable_compile(variable_parse_args_t *parse_args, VALUE line_number)
{
    vm_assembler_t *code = parse_args->code;
    if (native_compile_variable(parse_args, line_number)) return;
    VALUE markup = rb_enc_str_new(parse_args->markup, parse_args->markup_end - parse_args->markup, utf8_encoding);
    if (parse_args->guard) parse_args->guard->valid = false;
    VALUE variable_class = rb_const_get(mLiquid, rb_intern("Variable"));
    if (variable_class != cLiquidVariable) {
        VALUE variable = rb_funcall(variable_class, rb_intern("new"), 2, markup, parse_args->parse_context);
        vm_assembler_add_write_node(code, variable);
        return;
    }
    VALUE variable = rb_funcall(cLiquidVariable, rb_intern("c_parse"), 2, markup, parse_args->parse_context);
    if (!RTEST(rb_funcall(variable, rb_intern("c_compilable?"), 0))) {
        vm_assembler_add_write_node(code, variable);
        return;
    }
    vm_assembler_add_render_variable_rescue(code, line_number, variable);

    code->protected_stack_size = code->stack_size;
    rb_funcall(variable, id_compile_evaluate, 1, parse_args->code_obj);
    if (code->stack_size != code->protected_stack_size + 1) {
        rb_raise(rb_eRuntimeError, "Liquid::Variable#compile_evaluate didn't leave exactly 1 new element on the stack");
    }
    vm_assembler_add_pop_write(code);
}

VALUE internal_variable_expression_evaluate(expression_t *expression, VALUE context)
{
    return liquid_vm_evaluate(context, &expression->code);
}

static VALUE variable_expression_evaluate_method(VALUE self, VALUE context)
{
    expression_t *expression;
    Expression_Get_Struct(self, expression);
    return internal_variable_expression_evaluate(expression, context);
}

void liquid_define_variable(void)
{
    id_markup = rb_intern("@markup");
    id_context = rb_intern("@parse_context");
    id_line = rb_intern("@line_number");
    id_name = rb_intern("@name");
    id_filters = rb_intern("@filters");
    variable_allocator = rb_get_alloc_func(rb_cObject);
    cVariablePlaceholder = rb_define_class_under(mLiquidC, "VariablePlaceholder", rb_cObject);
    rb_global_variable(&cVariablePlaceholder);
    rb_undef_alloc_func(cVariablePlaceholder);
    cLiquidCVariableExpression = rb_define_class_under(mLiquidC, "VariableExpression", cLiquidCExpression);
    rb_global_variable(&cLiquidCVariableExpression);
    rb_define_method(cLiquidCVariableExpression, "evaluate", variable_expression_evaluate_method, 1);
}
