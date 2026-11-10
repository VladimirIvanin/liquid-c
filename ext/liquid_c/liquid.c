#include "liquid.h"
#include "tokenizer.h"
#include "variable.h"
#include "lexer.h"
#include "parser.h"
#include "raw.h"
#include "resource_limits.h"
#include "expression.h"
#include "document_body.h"
#include "block.h"
#include "context.h"
#include "parse_context.h"
#include "variable_lookup.h"
#include "vm_assembler_pool.h"
#include "liquid_vm.h"
#include "usage.h"

ID id_evaluate;
ID id_to_liquid;
ID id_to_s;
ID id_call;
ID id_compile_evaluate;
ID id_ivar_line_number;

VALUE mLiquid, mLiquidC, cLiquidVariable, cLiquidTemplate, cLiquidBlockBody;
VALUE cLiquidVariableLookup, cLiquidRangeLookup;
VALUE cLiquidArgumentError, cLiquidSyntaxError, cMemoryError;

rb_encoding *utf8_encoding;
int utf8_encoding_index;

#ifndef HAVE_RB_METHOD_BASIC_DEFINITION_P
static VALUE portable_instance_method, portable_source_location, portable_original_name;

static VALUE portable_method_reader(VALUE owner, const char *name)
{
    VALUE method = rb_funcall(owner, rb_intern("instance_method"), 1, ID2SYM(rb_intern(name)));
    VALUE reader = liquid_method_handle(rb_obj_method(method, ID2SYM(rb_intern("bind_call"))));
    RB_GC_GUARD(method);
    return reader;
}

static void portable_method_readers_init(void)
{
    rb_global_variable(&portable_instance_method);
    rb_global_variable(&portable_source_location);
    rb_global_variable(&portable_original_name);
    portable_instance_method = portable_method_reader(rb_cModule, "instance_method");
    VALUE unbound_class = rb_obj_class(rb_funcall(rb_cModule, rb_intern("instance_method"), 1, ID2SYM(rb_intern("autoload?"))));
    portable_source_location = portable_method_reader(unbound_class, "source_location");
    portable_original_name = portable_method_reader(unbound_class, "original_name");
}

bool liquid_method_basic_definition_p(VALUE klass, ID method)
{
    if (!rb_method_boundp(klass, method, 0)) return false;
    VALUE args[] = { klass, ID2SYM(method) };
    VALUE definition = liquid_method_call(2, args, portable_instance_method);
    VALUE location = liquid_method_call(1, &definition, portable_source_location);
    VALUE name = liquid_method_call(1, &definition, portable_original_name);
    bool builtin = NIL_P(location);
    if (RB_TYPE_P(location, T_ARRAY) && RARRAY_LEN(location)) {
        VALUE source = RARRAY_AREF(location, 0);
        const char prefix[] = "<internal:core> ";
        builtin = RB_TYPE_P(source, T_STRING) && RSTRING_LEN(source) >= (long)(sizeof(prefix) - 1) &&
            !memcmp(RSTRING_PTR(source), prefix, sizeof(prefix) - 1);
    }
    RB_GC_GUARD(definition);
    RB_GC_GUARD(location);
    bool original_name_matches = name == ID2SYM(method) ||
        (method == rb_intern("send") && name == ID2SYM(rb_intern("__send__")));
    return builtin && original_name_matches;
}
#endif

#ifndef HAVE_RB_GC_COUNT
static VALUE portable_gc_count;

size_t liquid_gc_count(void)
{
    return NUM2SIZET(liquid_method_call(0, NULL, portable_gc_count));
}
#endif

#ifndef HAVE_RUBY_STACK_CHECK
#include <pthread.h>
static _Thread_local uintptr_t portable_stack_bottom;

bool liquid_stack_check(void)
{
    char marker;
    if (!portable_stack_bottom) {
#ifdef HAVE_PTHREAD_GETATTR_NP
        pthread_attr_t attributes;
        void *base;
        size_t size;
        if (pthread_getattr_np(pthread_self(), &attributes))
            rb_raise(rb_eRuntimeError, "cannot read native stack bounds");
        int error = pthread_attr_getstack(&attributes, &base, &size);
        pthread_attr_destroy(&attributes);
        if (error) rb_raise(rb_eRuntimeError, "cannot read native stack bounds");
        portable_stack_bottom = (uintptr_t)base;
#else
        portable_stack_bottom = (uintptr_t)pthread_get_stackaddr_np(pthread_self()) - pthread_get_stacksize_np(pthread_self());
#endif
    }
    return (uintptr_t)&marker < portable_stack_bottom + 128 * 1024;
}
#endif

__attribute__((noreturn)) void raise_non_utf8_encoding_error(VALUE string, const char *value_name)
{
    rb_raise(rb_eEncCompatError, "non-UTF8 encoded %s (%"PRIsVALUE") not supported", value_name, rb_obj_encoding(string));
}

RUBY_FUNC_EXPORTED void Init_liquid_c(void)
{
#ifndef HAVE_RB_GC_COUNT
    rb_global_variable(&portable_gc_count);
    portable_gc_count = liquid_method_handle(rb_obj_method(rb_mGC, ID2SYM(rb_intern("count"))));
#endif
#ifndef HAVE_RB_METHOD_BASIC_DEFINITION_P
    portable_method_readers_init();
#endif
    id_evaluate = rb_intern("evaluate");
    id_to_liquid = rb_intern("to_liquid");
    id_to_s = rb_intern("to_s");
    id_call = rb_intern("call");
    id_compile_evaluate = rb_intern("compile_evaluate");
    id_ivar_line_number = rb_intern("@line_number");

    utf8_encoding = rb_utf8_encoding();
    utf8_encoding_index = rb_enc_to_index(utf8_encoding);

    mLiquid = rb_define_module("Liquid");
    rb_global_variable(&mLiquid);

    mLiquidC = rb_define_module_under(mLiquid, "C");
    rb_global_variable(&mLiquidC);

    cLiquidArgumentError = rb_const_get(mLiquid, rb_intern("ArgumentError"));
    rb_global_variable(&cLiquidArgumentError);

    cLiquidSyntaxError = rb_const_get(mLiquid, rb_intern("SyntaxError"));
    rb_global_variable(&cLiquidSyntaxError);

    cMemoryError = rb_const_get(mLiquid, rb_intern("MemoryError"));
    rb_global_variable(&cMemoryError);

    cLiquidVariable = rb_const_get(mLiquid, rb_intern("Variable"));
    rb_global_variable(&cLiquidVariable);

    cLiquidTemplate = rb_const_get(mLiquid, rb_intern("Template"));
    rb_global_variable(&cLiquidTemplate);

    cLiquidBlockBody = rb_const_get(mLiquid, rb_intern("BlockBody"));
    rb_global_variable(&cLiquidBlockBody);

    cLiquidVariableLookup = rb_const_get(mLiquid, rb_intern("VariableLookup"));
    rb_global_variable(&cLiquidVariableLookup);

    cLiquidRangeLookup = rb_const_get(mLiquid, rb_intern("RangeLookup"));
    rb_global_variable(&cLiquidRangeLookup);

    liquid_define_tokenizer();
    liquid_define_parser();
    liquid_define_native_parser();
    liquid_define_raw();
    liquid_define_resource_limits();
    liquid_define_expression();
    liquid_define_variable();
    liquid_define_document_body();
    liquid_define_block_body();
    liquid_define_context();
    liquid_define_native_values();
    liquid_define_parse_context();
    liquid_define_variable_lookup();
    liquid_define_vm_assembler_pool();
    liquid_define_vm_assembler();
    liquid_define_vm();
    liquid_define_usage();
}
