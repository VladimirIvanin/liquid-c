#if !defined(LIQUID_VARIABLE_H)
#define LIQUID_VARIABLE_H

#include "vm_assembler.h"
#include "block.h"
#include "expression.h"

extern VALUE cLiquidCVariableExpression;

// Valid only inside a C parsing loop, until Ruby code or GC can run.
typedef struct {
    bool valid, control_validated, control_checked, control_enabled, literals_checked;
    size_t gc_count;
    VALUE cache;
    VALUE environment, tags, condition_literals;
} variable_compile_guard_t;

typedef struct variable_parse_args {
    VALUE source;
    const char *markup;
    const char *markup_end;
    vm_assembler_t *code;
    VALUE code_obj;
    VALUE parse_context;
    variable_compile_guard_t *guard;
} variable_parse_args_t;

void liquid_define_variable(void);
void internal_variable_compile(variable_parse_args_t *parse_args, VALUE line_number);
VALUE internal_variable_expression_evaluate(expression_t *expression, VALUE context);
bool native_compile_variable(variable_parse_args_t *args, VALUE line_number);
VALUE variable_placeholder_new(VALUE source, size_t offset, size_t length, VALUE context, VALUE line_number);
void variable_placeholder_set(VALUE self, VALUE name, VALUE filters);
VALUE variable_materialize(VALUE node);
VALUE variable_from_parse(VALUE markup, VALUE context, VALUE line, VALUE name, VALUE filters);
bool native_assignment_class_p(VALUE klass);
VALUE native_parse_assignment(variable_parse_args_t *args, VALUE klass, VALUE name, VALUE markup);
bool variable_placeholder_p(VALUE node);
bool variable_placeholder_object_render_p(VALUE node);
void variable_placeholder_use_object(VALUE node);
bool variable_render_methods_standard(void);
bool liquid_vm_render_methods_standard(void);
bool variable_render_traced(void);
bool variable_output_method_standard(void);
bool native_compiler_guard(variable_parse_args_t *args);
bool native_control_guard(variable_parse_args_t *args);
VALUE native_control_header(variable_parse_args_t *args, VALUE markup, int kind, bool commit);
void native_control_commit(variable_parse_args_t *args, VALUE header);
void native_control_for_fields(VALUE tag, VALUE payload);
void native_control_attach(variable_parse_args_t *args, VALUE condition, VALUE body);
VALUE native_registered_tag(variable_parse_args_t *args, VALUE environment, VALUE name);
int native_control_kind(VALUE klass);
VALUE native_control_else(variable_parse_args_t *args);
void native_control_finish(variable_parse_args_t *args, VALUE tag, int kind);
bool native_control_condition(VALUE node);

#endif

