#include <stdint.h>
#include <assert.h>

#include "liquid.h"
#include "liquid_vm.h"
#include "variable_lookup.h"
#include "intutil.h"
#include "document_body.h"

ID id_render_node;
ID id_vm;

static VALUE cLiquidCVM;
static VALUE mLiquidUtils;
static unsigned long context_generation = 1;
static bool native_enabled;
static ID id_render, id_render_to_output_buffer, id_render_obj_to_output, id_ruby_render;
static ID id_each;

static void vm_mark(void *ptr)
{
    vm_t *vm = ptr;

    c_buffer_rb_gc_mark(&vm->stack);
    context_mark(&vm->context);
    for (vm_variable_frame_t *frame = vm->variable_frame; frame; frame = frame->previous) {
        rb_gc_mark(frame->variable);
    }
}

static void vm_free(void *ptr)
{
    vm_t *vm = ptr;
    c_buffer_free(&vm->stack);
    xfree(vm);
}

static size_t vm_memsize(const void *ptr)
{
    const vm_t *vm = ptr;
    return sizeof(vm_t) + c_buffer_capacity(&vm->stack);
}

const rb_data_type_t vm_data_type = {
    "liquid_vm",
    { vm_mark, vm_free, vm_memsize, },
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};

static VALUE vm_internal_new(VALUE context)
{
    vm_t *vm;
    VALUE obj = TypedData_Make_Struct(cLiquidCVM, vm_t, &vm_data_type, vm);
    vm->stack = c_buffer_init();

    vm->invoking_filter = false;

    vm->context_generation = context_generation;
    context_internal_init(context, &vm->context);

    return obj;
}

static void vm_refresh_context(vm_t *vm)
{
    if (vm->context_generation != context_generation || !native_enabled) {
        unsigned long generation = context_generation;
        unsigned long revision = vm->context_revision;
        context_refresh(&vm->context);
        vm->context_generation = revision == vm->context_revision ? generation : 0;
    }
}

vm_t *vm_from_context(VALUE context)
{
    VALUE vm_obj = rb_attr_get(context, id_vm);
    if (vm_obj == Qnil || ((vm_t *)DATA_PTR(vm_obj))->context.self != context) {
        vm_obj = vm_internal_new(context);
        rb_ivar_set(context, id_vm, vm_obj);
    }
    // instance variable is hidden from ruby so should be safe to unwrap it without type checking
    vm_t *vm = DATA_PTR(vm_obj);
    vm_refresh_context(vm);
    return vm;
}

bool liquid_vm_filtering(VALUE context)
{
    VALUE vm_obj = rb_attr_get(context, id_vm);
    if (vm_obj == Qnil)
        return false;
    vm_t *vm = DATA_PTR(vm_obj);
    return vm->context.self == context && vm->invoking_filter;
}

static void write_fixnum(VALUE output, VALUE fixnum)
{
    char buffer[32];
    int length = snprintf(buffer, sizeof(buffer), "%lld", RB_NUM2LL(fixnum));
    rb_enc_str_buf_cat(output, buffer, length, utf8_encoding);
}

static VALUE obj_to_s(VALUE obj)
{
    VALUE str = rb_funcall(obj, id_to_s, 0);

    if (RB_LIKELY(RB_TYPE_P(str, T_STRING)))
        return str;

    rb_raise(rb_eTypeError, "%"PRIsVALUE"#to_s returned a non-String convertible value of type %"PRIsVALUE,
            rb_obj_class(obj), rb_obj_class(str));
}

static void write_obj(VALUE output, VALUE obj);

typedef struct {
    VALUE variable;
    VALUE output;
} array_writer_args_t;

static VALUE write_array_element(RB_BLOCK_CALL_FUNC_ARGLIST(value, uncast_args))
{
    array_writer_args_t *args = (void *)uncast_args;
    if (NIL_P(args->variable)) {
        write_obj(args->output, value);
        return args->output;
    }
    return rb_funcall(args->variable, id_render_obj_to_output, 2, value, args->output);
}

static VALUE write_array(VALUE array, VALUE uncast_args, int recursive)
{
    if (recursive || ruby_stack_check()) {
        rb_raise(rb_eSysStackError, "stack level too deep");
    }
    return rb_block_call(array, id_each, 0, NULL, write_array_element, uncast_args);
}

static void write_obj(VALUE output, VALUE obj)
{
    switch (TYPE(obj)) {
        case T_STRING:
        {
            rb_str_buf_append(output, obj_to_s(obj));
            break;
        }
        case T_FIXNUM:
            write_fixnum(output, obj);
            break;
        case T_ARRAY:
        {
            array_writer_args_t args = { Qnil, output };
            rb_exec_recursive(write_array, obj, (VALUE)&args);
            break;
        }
        case T_NIL:
            break;
        default:
        {
            VALUE string = rb_funcall(mLiquidUtils, id_to_s, 1, obj);
            if (!RB_TYPE_P(string, T_STRING)) {
                string = obj_to_s(obj);
            }

            rb_str_buf_append(output, string);
            break;
        }
    }
}

static inline void vm_stack_push(vm_t *vm, VALUE value)
{
    VALUE *stack_ptr = (VALUE *)vm->stack.data_end;
    assert(stack_ptr < (VALUE *)vm->stack.capacity_end);
    *stack_ptr++ = value;
    vm->stack.data_end = (uint8_t *)stack_ptr;
}

static inline VALUE *vm_stack_peek_n(vm_t *vm, size_t n)
{
    VALUE *stack_ptr = (VALUE *)vm->stack.data_end;
    stack_ptr -= n;
    assert((VALUE *)vm->stack.data <= stack_ptr);
    return stack_ptr;
}

static inline VALUE *vm_stack_pop_n(vm_t *vm, size_t n)
{
    VALUE *stack_ptr = vm_stack_peek_n(vm, n);
    vm->stack.data_end = (uint8_t *)stack_ptr;
    return stack_ptr;
}

static inline VALUE vm_stack_pop(vm_t *vm)
{
    return *vm_stack_pop_n(vm, 1);
}

static inline void vm_stack_reserve_for_write(vm_t *vm, size_t num_values)
{
    if (num_values > SIZE_MAX / sizeof(VALUE)) rb_raise(rb_eNoMemError, "Liquid stack size overflow");
    c_buffer_reserve_for_write(&vm->stack, num_values * sizeof(VALUE));
}

typedef struct {
    vm_t *vm;
    VALUE name;
    VALUE *args;
    int count;
    bool previous;
} vm_filter_args_t;

static VALUE vm_call_filter(VALUE opaque)
{
    vm_filter_args_t *args = (void *)opaque;
    return rb_funcallv(args->vm->context.strainer, RB_SYM2ID(args->name), args->count, args->args);
}

__attribute__((noreturn)) static VALUE vm_filter_argument_error(VALUE unused, VALUE exception)
{
    VALUE klass = rb_const_get(mLiquid, rb_intern("StrainerTemplate"));
    rb_exc_raise(rb_funcall(klass, rb_intern("arg_exc_to_liquid_exc"), 1, exception));
}

static VALUE vm_try_filter(VALUE opaque)
{
    return rb_rescue2(vm_call_filter, opaque, vm_filter_argument_error, Qnil, rb_eArgError, (VALUE)0);
}

static VALUE vm_restore_filter(VALUE opaque)
{
    vm_filter_args_t *args = (void *)opaque;
    args->vm->invoking_filter = args->previous;
    return Qnil;
}

static void vm_increment_write_score(vm_t *vm, VALUE output)
{
    rb_funcall(vm->context.resource_limits_obj, rb_intern("increment_write_score"), 1, output);
}

static VALUE vm_reset_context(VALUE klass, VALUE context)
{
    rb_ivar_set(context, id_vm, Qnil);
    return Qnil;
}

static VALUE vm_invoke_filter(vm_t *vm, VALUE filter_name, size_t num_args)
{
    vm_refresh_context(vm);
    VALUE *popped_args = vm_stack_pop_n(vm, num_args);
    /* We have to copy popped_args_ptr to the stack because the VM
     * no longer holds onto these objects, so they have to exist on
     * the stack to ensure they don't get garbage collected. */
    VALUE *args = alloca(sizeof(VALUE *) * num_args);
    memcpy(args, popped_args, sizeof(VALUE *) * num_args);

    bool not_invokable = rb_hash_lookup(vm->context.filter_methods, filter_name) != Qtrue;
    if (RB_UNLIKELY(not_invokable)) {
        if (RTEST(rb_funcall(vm->context.self, rb_intern("strict_filters"), 0))) {
            VALUE error_class = rb_const_get(mLiquid, rb_intern("UndefinedFilter"));
            rb_raise(error_class, "undefined filter %"PRIsVALUE, rb_sym2str(filter_name));
        }
        return args[0];
    }

    vm_filter_args_t call = { vm, filter_name, args, (int)num_args, vm->invoking_filter };
    vm->invoking_filter = true;
    VALUE result = rb_ensure(vm_try_filter, (VALUE)&call, vm_restore_filter, (VALUE)&call);
    return liquid_value_to_liquid(result);
}

typedef struct vm_render_until_error_args {
    vm_t *vm;
    const uint8_t *ip; // use for initial address and to save an address for rescuing
    const VALUE *const_ptr;

    /* rendering fields */
    VALUE output;
    const uint8_t *node_line_number;
    const VALUE *nodelist;
    bool evaluate_variable;
    size_t max_variable_stack_size;
} vm_render_until_error_args_t;

static VALUE raise_invalid_integer(VALUE unused_arg, VALUE exc)
{
    rb_raise(cLiquidArgumentError, "invalid integer");
}

// Equivalent to Integer(string) if string is an instance of String
static VALUE try_string_to_integer(VALUE string)
{
    return rb_str_to_inum(string, 0, true);
}

static VALUE range_value_to_integer(VALUE value)
{
    if (RB_INTEGER_TYPE_P(value)) {
        return value;
    } else if (value == Qnil) {
        return INT2FIX(0);
    } else if (RB_TYPE_P(value, T_STRING)) {
        return rb_funcall(value, rb_intern("to_i"), 0);
    } else {
        value = obj_to_s(value);
        return rb_rescue2(try_string_to_integer, value, raise_invalid_integer, Qnil, rb_eArgError, (VALUE)0);
    }
}

#ifdef HAVE_RB_HASH_BULK_INSERT
#define hash_bulk_insert rb_hash_bulk_insert
#else
static void hash_bulk_insert(long argc, const VALUE *argv, VALUE hash)
{
    for (long i = 0; i < argc; i += 2) {
        rb_hash_aset(hash, argv[i], argv[i + 1]);
    }
}
#endif

static const uint8_t *vm_skip_variable_instructions(const uint8_t *ip)
{
    enum opcode opcode;
    do {
        opcode = *ip;
        liquid_vm_next_instruction(&ip);
    } while (opcode != OP_POP_WRITE);

    return ip;
}

typedef struct {
    vm_t *vm;
    vm_variable_frame_t frame;
    VALUE output;
} variable_render_args_t;

static VALUE vm_call_variable_render(VALUE uncast_args)
{
    variable_render_args_t *args = (void *)uncast_args;
    return rb_funcall(args->frame.variable, id_render_to_output_buffer, 2, args->vm->context.self, args->output);
}

static VALUE vm_restore_variable_frame(VALUE uncast_args)
{
    variable_render_args_t *args = (void *)uncast_args;
    args->vm->variable_frame = args->frame.previous;
    return Qnil;
}

// Actually returns a bool resume_rendering value
static VALUE vm_render_until_error(VALUE uncast_args)
{
    vm_render_until_error_args_t *args = (void *)uncast_args;
    const VALUE *constants = args->const_ptr;
    const uint8_t *ip = args->ip;
    vm_t *vm = args->vm;
    VALUE output = args->output;
    uint32_t constant_index;
    VALUE constant = Qnil;
    bool lookup_missing = false;
    args->ip = NULL; // used by vm_render_rescue, NULL to indicate that it isn't in a rescue block

    while (true) {
        uint8_t opcode = *ip++;
        switch (opcode) {
            case OP_LEAVE:
                return false;
            case OP_PUSH_NIL:
                vm_stack_push(vm, Qnil);
                break;
            case OP_PUSH_TRUE:
                vm_stack_push(vm, Qtrue);
                break;
            case OP_PUSH_FALSE:
                vm_stack_push(vm, Qfalse);
                break;
            case OP_PUSH_INT8:
            {
                int num = *(int8_t *)ip++; // signed
                vm_stack_push(vm, RB_INT2FIX(num));
                break;
            }
            case OP_PUSH_INT16:
            {
                unsigned int bits = ((unsigned int)ip[0] << 8) | ip[1];
                int num = bits >= 0x8000 ? (int)bits - 0x10000 : (int)bits;
                ip += 2;
                vm_stack_push(vm, RB_INT2FIX(num));
                break;
            }
            case OP_FIND_STATIC_VAR:
            {
                vm_refresh_context(vm);
                constant_index = bytes_to_uint32(ip);
                constant = constants[constant_index];
                ip += 4;
                VALUE value = context_find_variable(&vm->context, constant, Qtrue);
                vm_stack_push(vm, value);
                break;
            }
            case OP_FIND_VAR:
            {
                vm_refresh_context(vm);
                VALUE key = vm_stack_pop(vm);
                VALUE value = context_find_variable(&vm->context, key, Qtrue);
                vm_stack_push(vm, value);
                break;
            }
            case OP_LOOKUP_CONST_KEY:
            case OP_LOOKUP_COMMAND:
            {
                constant_index = bytes_to_uint32(ip);
                constant = constants[constant_index];
                ip += 4;
                vm_stack_push(vm, constant);
            }
            /* fallthrough */
            case OP_LOOKUP_KEY:
            {
                vm_refresh_context(vm);
                bool is_command = opcode == OP_LOOKUP_COMMAND;
                VALUE key = vm_stack_pop(vm);
                VALUE object = vm_stack_pop(vm);
                VALUE result = variable_lookup_key(vm->context.self, object, key, is_command);
                lookup_missing = result == Qundef;
                vm_stack_push(vm, lookup_missing ? Qnil : result);
                break;
            }

            case OP_LOOKUP_GUARD:
            {
                size_t distance = bytes_to_uint32(ip);
                ip += 4;
                if (lookup_missing)
                    ip += distance;
                break;
            }

            case OP_NEW_INT_RANGE:
            {
                VALUE end = range_value_to_integer(vm_stack_pop(vm));
                VALUE begin = range_value_to_integer(vm_stack_pop(vm));
                bool exclude_end = false;
                vm_stack_push(vm, rb_range_new(begin, end, exclude_end));
                break;
            }
            case OP_HASH_NEW:
            {
                size_t hash_size = *ip++;
                size_t num_keys_and_values = hash_size * 2;
                VALUE hash = rb_hash_new();

                VALUE *args_ptr = ALLOCA_N(VALUE, num_keys_and_values);
                memcpy(args_ptr, vm_stack_peek_n(vm, num_keys_and_values), num_keys_and_values * sizeof(VALUE));
                hash_bulk_insert(num_keys_and_values, args_ptr, hash);
                vm_stack_pop_n(vm, num_keys_and_values);

                vm_stack_push(vm, hash);
                break;
            }
            case OP_FILTER:
            case OP_BUILTIN_FILTER:
            {
                VALUE filter_name;
                unsigned long num_args;

                if (ip[-1] == OP_FILTER) {
                    constant_index = bytes_to_uint32(ip);
                    constant = constants[constant_index];
                    filter_name = RARRAY_AREF(constant, 0);
                    num_args = FIX2ULONG(RARRAY_AREF(constant, 1));
                    ip += 4;
                } else {
                    assert(ip[-1] == OP_BUILTIN_FILTER);
                    filter_name = builtin_filters[*ip++].sym;
                    num_args = *ip++; // includes input argument
                }

                VALUE result = vm_invoke_filter(vm, filter_name, num_args);
                vm_stack_push(vm, result);
                break;
            }

            // Rendering instructions

            case OP_WRITE_RAW_W:
            case OP_WRITE_RAW:
            {
                const char *text;
                size_t size;
                if (ip[-1] == OP_WRITE_RAW_W) {
                    size = bytes_to_uint24(ip);
                    text = (const char *)&ip[3];
                    ip += 3 + size;
                } else {
                    size = *ip;
                    text = (const char *)&ip[1];
                    ip += 1 + size;
                }
                rb_enc_str_buf_cat(output, text, size, utf8_encoding);
                vm_increment_write_score(vm, output);
                break;
            }
            case OP_JUMP_FWD_W:
            {
                size_t size = bytes_to_uint24(ip);
                ip += 3 + size;
                break;
            }

            case OP_JUMP_FWD:
            {
                uint8_t size = *ip;
                ip += 1 + size;
                break;
            }

            case OP_EVALUATE:
            {
                constant_index = bytes_to_uint32(ip);
                ip += 4;
                VALUE value = rb_funcall(vm->context.self, id_evaluate, 1, constants[constant_index]);
                vm_stack_push(vm, value);
                break;
            }

            case OP_PUSH_CONST:
            {
                constant_index = bytes_to_uint32(ip);
                constant = constants[constant_index];
                ip += 4;
                vm_stack_push(vm, constant);
                break;
            }

            case OP_WRITE_NODE:
            {
                constant_index = bytes_to_uint32(ip);
                constant = constants[constant_index];
                ip += 4;
                rb_funcall(cLiquidBlockBody, id_render_node, 3, vm->context.self, output, constant);

                if (RARRAY_LEN(vm->context.interrupts)) {
                    return false;
                }

                vm_increment_write_score(vm, output);
                break;
            }
            case OP_RENDER_VARIABLE_RESCUE:
            case OP_RENDER_VARIABLE_RESCUE_W:
            {
                // Save state used by vm_render_rescue to rescue from a variable rendering exception
                args->node_line_number = ip;
                bool wide = ip[-1] == OP_RENDER_VARIABLE_RESCUE_W;
                // vm_render_rescue will iterate from this instruction to the instruction
                // following OP_POP_WRITE_VARIABLE to resume rendering from
                size_t line_size = wide ? 4 : VM_VARIABLE_LINE_NUMBER_SIZE;
                uint32_t variable_index = bytes_to_uint32(ip + line_size);
                ip += line_size + 4;

                args->ip = ip;
                variable_render_args_t render_args = {
                    .vm = vm,
                    .frame = {
                        .previous = vm->variable_frame,
                        .variable = constants[variable_index],
                        .instructions = ip,
                        .constants = constants,
                        .nodelist = args->nodelist,
                        .max_stack_size = args->max_variable_stack_size,
                    },
                    .output = output,
                };
                vm->variable_frame = &render_args.frame;
                rb_ensure(vm_call_variable_render, (VALUE)&render_args, vm_restore_variable_frame, (VALUE)&render_args);
                ip = vm_skip_variable_instructions(ip);
                args->ip = NULL;
                if (RARRAY_LEN(vm->context.interrupts))
                    return false;
                vm_increment_write_score(vm, output);
                break;
            }
            case OP_POP_WRITE:
            {
                if (args->evaluate_variable) {
                    return false;
                }
                VALUE var_result = vm_stack_pop(vm);
                vm_refresh_context(vm);
                if (vm->context.global_filter != Qnil)
                    var_result = rb_funcall(vm->context.global_filter, id_call, 1, var_result);
                write_obj(output, var_result);
                args->ip = NULL; // mark the end of a rescue block, used by vm_render_rescue
                vm_increment_write_score(vm, output);
                break;
            }

            default:
                rb_bug("invalid opcode: %u", ip[-1]);
        }
    }
}

typedef struct vm_execution_args {
    vm_render_until_error_args_t *render_args;
    size_t old_stack_byte_size;
} vm_execution_args_t;

static VALUE vm_restore_stack(VALUE uncast_args)
{
    vm_execution_args_t *args = (void *)uncast_args;
    vm_render_until_error_args_t *render_args = args->render_args;
    vm_t *vm = render_args->vm;

    vm->stack.data_end = vm->stack.data ? vm->stack.data + args->old_stack_byte_size : NULL;

    return Qnil;
}

static VALUE vm_evaluate_body(VALUE opaque)
{
    vm_execution_args_t *args = (void *)opaque;
    vm_render_until_error((VALUE)args->render_args);
    VALUE result = vm_stack_pop(args->render_args->vm);
    assert(args->old_stack_byte_size == c_buffer_size(&args->render_args->vm->stack));
    return result;
}

// Evaluate instructions that avoid using rendering instructions and leave with the result on
// the top of the stack
VALUE liquid_vm_evaluate(VALUE context, vm_assembler_t *code)
{
    vm_t *vm = vm_from_context(context);
    vm_stack_reserve_for_write(vm, code->max_stack_size);

    vm_render_until_error_args_t args = {
        .vm = vm,
        .const_ptr = (const VALUE *)code->constants.data,
        .ip = code->instructions.data
    };
    vm_execution_args_t execution_args = {
        .render_args = &args,
        .old_stack_byte_size = c_buffer_size(&vm->stack),
    };
    return rb_ensure(vm_evaluate_body, (VALUE)&execution_args, vm_restore_stack, (VALUE)&execution_args);
}

void liquid_vm_next_instruction(const uint8_t **ip_ptr)
{
    const uint8_t *ip = *ip_ptr;

    switch (*ip++) {
        case OP_LEAVE:
        case OP_POP_WRITE:
        case OP_PUSH_NIL:
        case OP_PUSH_TRUE:
        case OP_PUSH_FALSE:
        case OP_FIND_VAR:
        case OP_LOOKUP_KEY:
        case OP_NEW_INT_RANGE:
            break;

        case OP_HASH_NEW:
        case OP_PUSH_INT8:
            ip++;
            break;

        case OP_BUILTIN_FILTER:
        case OP_PUSH_INT16:
            ip += 2;
            break;

        case OP_EVALUATE:
        case OP_PUSH_CONST:
        case OP_WRITE_NODE:
        case OP_FIND_STATIC_VAR:
        case OP_LOOKUP_CONST_KEY:
        case OP_LOOKUP_COMMAND:
        case OP_FILTER:
        case OP_LOOKUP_GUARD:
            ip += 4;
            break;

        case OP_RENDER_VARIABLE_RESCUE:
            ip += VM_VARIABLE_METADATA_SIZE;
            break;
        case OP_RENDER_VARIABLE_RESCUE_W:
            ip += 8;
            break;

        case OP_WRITE_RAW_W:
        case OP_JUMP_FWD_W:
        {
            size_t size = bytes_to_uint24(ip);
            ip += 3 + size;
            break;
        }

        case OP_WRITE_RAW:
        case OP_JUMP_FWD:
        {
            uint8_t size = *ip;
            ip += 1 + size;
            break;
        }

        default:
            rb_bug("invalid opcode: %u", ip[-1]);
    }
    *ip_ptr = ip;
}

// Actually returns a bool resume_rendering value
static VALUE vm_render_rescue(VALUE uncast_args, VALUE exception)
{
    vm_execution_args_t *args = (void *)uncast_args;
    VALUE blank_tag = Qfalse; // tags are still rendered using Liquid::BlockBody.render_node
    vm_render_until_error_args_t *render_args = args->render_args;
    vm_t *vm = render_args->vm;

    const uint8_t *ip = render_args->ip;
    if (!ip)
        rb_exc_raise(exception);

    // rescue for variable render, where ip is at the start of the render and we need to
    // skip to the end of the variable render to resume rendering if the error is handled
    render_args->ip = vm_skip_variable_instructions(ip);
    // remove temporary stack values from variable evaluation
    vm->stack.data_end = vm->stack.data ? vm->stack.data + args->old_stack_byte_size : NULL;

    const uint8_t *line_metadata = render_args->node_line_number;
    assert(line_metadata);
    VALUE line_number;
    if (line_metadata[-1] == OP_RENDER_VARIABLE_RESCUE_W) {
        line_number = render_args->const_ptr[bytes_to_uint32(line_metadata)];
    } else {
        unsigned int line = bytes_to_uint24(line_metadata);
        line_number = line ? UINT2NUM(line) : Qnil;
    }

    rb_funcall(cLiquidBlockBody, rb_intern("c_rescue_render_node"), 5,
        vm->context.self, render_args->output, line_number, exception, blank_tag);
    if (RARRAY_LEN(vm->context.interrupts))
        return false;
    vm_increment_write_score(vm, render_args->output);
    return true;
}

static VALUE vm_render_loop(VALUE opaque)
{
    vm_execution_args_t *args = (void *)opaque;
    while (rb_rescue(vm_render_until_error, (VALUE)args->render_args, vm_render_rescue, opaque)) {
    }
    assert(args->old_stack_byte_size == c_buffer_size(&args->render_args->vm->stack));
    return Qnil;
}

void liquid_vm_render(block_body_header_t *body, const VALUE *const_ptr, VALUE context, VALUE output, const VALUE *nodelist)
{
    vm_t *vm = vm_from_context(context);

    vm_stack_reserve_for_write(vm, body->max_stack_size);
    rb_funcall(vm->context.resource_limits_obj, rb_intern("increment_render_score"), 1, UINT2NUM(body->render_score));

    vm_render_until_error_args_t render_args = {
        .vm = vm,
        .const_ptr = const_ptr,
        .ip = block_body_instructions_ptr(body),
        .output = output,
        .nodelist = nodelist,
        .max_variable_stack_size = body->max_stack_size,
    };
    vm_execution_args_t execution_args = {
        .render_args = &render_args,
        .old_stack_byte_size = c_buffer_size(&vm->stack),
    };

    rb_ensure(vm_render_loop, (VALUE)&execution_args, vm_restore_stack, (VALUE)&execution_args);
}


static VALUE variable_render(VALUE self, VALUE context)
{
    if (!native_enabled) {
        return rb_funcall(self, id_ruby_render, 1, context);
    }
    vm_t *vm = vm_from_context(context);
    vm_variable_frame_t *frame = vm->variable_frame;
    if (!frame || frame->variable != self || *frame->nodelist != Qundef) {
        return rb_funcall(self, id_ruby_render, 1, context);
    }

    vm_stack_reserve_for_write(vm, frame->max_stack_size);
    vm_render_until_error_args_t render_args = {
        .vm = vm,
        .const_ptr = frame->constants,
        .ip = frame->instructions,
        .evaluate_variable = true,
    };
    vm_execution_args_t execution_args = {
        .render_args = &render_args,
        .old_stack_byte_size = c_buffer_size(&vm->stack),
    };
    VALUE result = rb_ensure(vm_evaluate_body, (VALUE)&execution_args, vm_restore_stack, (VALUE)&execution_args);
    vm_refresh_context(vm);
    if (!NIL_P(vm->context.global_filter)) {
        result = rb_funcall(vm->context.global_filter, id_call, 1, result);
    }
    return result;
}

static VALUE variable_render_to_output_buffer(VALUE self, VALUE context, VALUE output)
{
    if (!native_enabled) {
        return rb_funcall(self, rb_intern("ruby_render_to_output_buffer"), 2, context, output);
    }
    VALUE result = rb_funcall(self, id_render, 1, context);
    rb_funcall(self, id_render_obj_to_output, 2, result, output);
    return output;
}

static VALUE variable_render_obj_to_output(VALUE self, VALUE object, VALUE output)
{
    if (!native_enabled || !RB_TYPE_P(output, T_STRING) ||
        !rb_method_basic_definition_p(CLASS_OF(output), rb_intern("<<"))) {
        return rb_funcall(self, rb_intern("ruby_render_obj_to_output"), 2, object, output);
    }
    if (RB_TYPE_P(object, T_ARRAY)) {
        array_writer_args_t args = { self, output };
        return rb_exec_recursive(write_array, object, (VALUE)&args);
    }
    if (NIL_P(object)) {
        return Qnil;
    }
    write_obj(output, object);
    return output;
}

static VALUE vm_invalidate_contexts(VALUE self)
{
    context_generation++;
    native_enabled = RTEST(rb_ivar_get(mLiquidC, rb_intern("@enabled")));
    return Qnil;
}

void liquid_define_vm(void)
{
    mLiquidUtils = rb_const_get(mLiquid, rb_intern("Utils"));
    rb_global_variable(&mLiquidUtils);

    id_render = rb_intern("render");
    id_render_to_output_buffer = rb_intern("render_to_output_buffer");
    id_render_obj_to_output = rb_intern("render_obj_to_output");
    id_ruby_render = rb_intern("ruby_render");
    id_each = rb_intern("each");
    rb_define_method(cLiquidVariable, "c_render", variable_render, 1);
    rb_define_method(cLiquidVariable, "c_render_to_output_buffer", variable_render_to_output_buffer, 2);
    rb_define_method(cLiquidVariable, "c_render_obj_to_output", variable_render_obj_to_output, 2);

    id_render_node = rb_intern("render_node");
    id_vm = rb_intern("vm");

    cLiquidCVM = rb_define_class_under(mLiquidC, "VM", rb_cObject);
    rb_undef_alloc_func(cLiquidCVM);
    rb_define_singleton_method(cLiquidCVM, "invalidate_contexts", vm_invalidate_contexts, 0);
    rb_define_singleton_method(cLiquidCVM, "reset_context", vm_reset_context, 1);
    rb_global_variable(&cLiquidCVM);
}
