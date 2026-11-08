#include "liquid.h"
#include "variable.h"
#include "expression.h"
#include "liquid_vm.h"

VALUE cLiquidCVariableExpression;

void internal_variable_compile(variable_parse_args_t *parse_args, unsigned int line_number)
{
    vm_assembler_t *code = parse_args->code;
    VALUE markup = rb_enc_str_new(parse_args->markup, parse_args->markup_end - parse_args->markup, utf8_encoding);
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

typedef struct {
    expression_t *expression;
    VALUE context;
} variable_expression_evaluate_args_t;

static VALUE try_variable_expression_evaluate(VALUE uncast_args)
{
    variable_expression_evaluate_args_t *args = (void *)uncast_args;
    return liquid_vm_evaluate(args->context, &args->expression->code);
}

static VALUE rescue_variable_expression_evaluate(VALUE uncast_args, VALUE exception)
{
    variable_expression_evaluate_args_t *args = (void *)uncast_args;
    vm_t *vm = vm_from_context(args->context);
    exception = vm_translate_if_filter_argument_error(vm, exception);
    rb_exc_raise(exception);
}

VALUE internal_variable_expression_evaluate(expression_t *expression, VALUE context)
{
    variable_expression_evaluate_args_t args = { expression, context };
    return rb_rescue(try_variable_expression_evaluate, (VALUE)&args, rescue_variable_expression_evaluate, (VALUE)&args);
}

static VALUE variable_expression_evaluate_method(VALUE self, VALUE context)
{
    expression_t *expression;
    Expression_Get_Struct(self, expression);
    return internal_variable_expression_evaluate(expression, context);
}

void liquid_define_variable(void)
{
    cLiquidCVariableExpression = rb_define_class_under(mLiquidC, "VariableExpression", cLiquidCExpression);
    rb_global_variable(&cLiquidCVariableExpression);
    rb_define_method(cLiquidCVariableExpression, "evaluate", variable_expression_evaluate_method, 1);
}
