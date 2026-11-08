#include "liquid.h"
#include "resource_limits.h"

VALUE cLiquidResourceLimits;

static void resource_limits_mark(void *ptr)
{
    resource_limits_t *limits = ptr;
    rb_gc_mark(limits->self);
    rb_gc_mark(limits->last_capture_length);
    rb_gc_mark(limits->render_length_limit);
    rb_gc_mark(limits->render_score_limit);
    rb_gc_mark(limits->assign_score_limit);
    rb_gc_mark(limits->cumulative_render_score_limit);
    rb_gc_mark(limits->cumulative_assign_score_limit);
    rb_gc_mark(limits->render_score);
    rb_gc_mark(limits->assign_score);
    rb_gc_mark(limits->cumulative_render_score);
    rb_gc_mark(limits->cumulative_assign_score);
}

static void resource_limits_free(void *ptr)
{
    xfree(ptr);
}

static size_t resource_limits_memsize(const void *ptr)
{
    return sizeof(resource_limits_t);
}

const rb_data_type_t resource_limits_data_type = {
    "liquid_resource_limits",
    { resource_limits_mark, resource_limits_free, resource_limits_memsize },
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};

static bool score_exceeds_limit(VALUE score, VALUE limit)
{
    if (!RTEST(limit)) {
        return false;
    }

    if (FIXNUM_P(score) && FIXNUM_P(limit)) {
        return FIX2LONG(score) > FIX2LONG(limit);
    }

    return RTEST(rb_funcall(score, rb_intern(">"), 1, limit));
}

static VALUE add_score(VALUE score, VALUE amount)
{
    if (FIXNUM_P(score) && FIXNUM_P(amount)) {
        long result = FIX2LONG(score) + FIX2LONG(amount);
        return LONG2NUM(result);
    }
    return rb_funcall(score, rb_intern("+"), 1, amount);
}

__attribute__((noreturn))
void resource_limits_raise_limits_reached(resource_limits_t *limits)
{
    rb_check_frozen(limits->self);
    limits->reached_limit = true;
    rb_raise(cMemoryError, "Memory limits exceeded");
}

static void resource_limits_reset(resource_limits_t *limits)
{
    rb_check_frozen(limits->self);
    limits->reached_limit = false;
    limits->last_capture_length = Qnil;
    limits->render_score = INT2FIX(0);
    limits->assign_score = INT2FIX(0);
    if (score_exceeds_limit(limits->cumulative_render_score, limits->cumulative_render_score_limit) ||
        score_exceeds_limit(limits->cumulative_assign_score, limits->cumulative_assign_score_limit)) {
        resource_limits_raise_limits_reached(limits);
    }
}

static VALUE resource_limits_allocate(VALUE klass)
{
    resource_limits_t *limits;
    VALUE obj = TypedData_Make_Struct(klass, resource_limits_t, &resource_limits_data_type, limits);
    limits->self = obj;
    limits->render_length_limit = Qnil;
    limits->render_score_limit = Qnil;
    limits->assign_score_limit = Qnil;
    limits->cumulative_render_score_limit = Qnil;
    limits->cumulative_assign_score_limit = Qnil;
    limits->render_score = INT2FIX(0);
    limits->assign_score = INT2FIX(0);
    limits->cumulative_render_score = INT2FIX(0);
    limits->cumulative_assign_score = INT2FIX(0);
    resource_limits_reset(limits);
    return obj;
}

static VALUE resource_limits_render_length_limit_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    return limits->render_length_limit;
}

static VALUE resource_limits_set_render_length_limit_method(VALUE self, VALUE value)
{
    rb_check_frozen(self);
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    limits->render_length_limit = value;
    return value;
}

static VALUE resource_limits_render_score_limit_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    return limits->render_score_limit;
}

static VALUE resource_limits_set_render_score_limit_method(VALUE self, VALUE value)
{
    rb_check_frozen(self);
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    limits->render_score_limit = value;
    return value;
}

static VALUE resource_limits_assign_score_limit_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    return limits->assign_score_limit;
}

static VALUE resource_limits_set_assign_score_limit_method(VALUE self, VALUE value)
{
    rb_check_frozen(self);
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    limits->assign_score_limit = value;
    return value;
}

static VALUE resource_limits_cumulative_render_score_limit_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    return limits->cumulative_render_score_limit;
}

static VALUE resource_limits_set_cumulative_render_score_limit_method(VALUE self, VALUE value)
{
    rb_check_frozen(self);
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    limits->cumulative_render_score_limit = value;
    return value;
}

static VALUE resource_limits_cumulative_assign_score_limit_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    return limits->cumulative_assign_score_limit;
}

static VALUE resource_limits_set_cumulative_assign_score_limit_method(VALUE self, VALUE value)
{
    rb_check_frozen(self);
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    limits->cumulative_assign_score_limit = value;
    return value;
}

static VALUE resource_limits_render_score_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    return limits->render_score;
}

static VALUE resource_limits_assign_score_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    return limits->assign_score;
}

static VALUE resource_limits_cumulative_render_score_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    return limits->cumulative_render_score;
}

static VALUE resource_limits_cumulative_assign_score_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    return limits->cumulative_assign_score;
}

static VALUE resource_limits_initialize_method(int argc, VALUE *argv, VALUE self)
{
    VALUE render_length_limit, render_score_limit, assign_score_limit;
    VALUE cumulative_render_score_limit, cumulative_assign_score_limit;
    rb_check_frozen(self);
    if (argc == 1) {
        VALUE options = argv[0];
        ID aref = rb_intern("[]");
        render_length_limit = rb_funcall(options, aref, 1, ID2SYM(rb_intern("render_length_limit")));
        render_score_limit = rb_funcall(options, aref, 1, ID2SYM(rb_intern("render_score_limit")));
        assign_score_limit = rb_funcall(options, aref, 1, ID2SYM(rb_intern("assign_score_limit")));
        cumulative_render_score_limit = rb_funcall(options, aref, 1, ID2SYM(rb_intern("cumulative_render_score_limit")));
        cumulative_assign_score_limit = rb_funcall(options, aref, 1, ID2SYM(rb_intern("cumulative_assign_score_limit")));
    } else {
        rb_scan_args(argc, argv, "32",
            &render_length_limit, &render_score_limit, &assign_score_limit,
            &cumulative_render_score_limit, &cumulative_assign_score_limit);
    }

    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);

    rb_check_frozen(self);
    limits->render_length_limit = render_length_limit;
    limits->render_score_limit = render_score_limit;
    limits->assign_score_limit = assign_score_limit;
    limits->cumulative_render_score_limit = cumulative_render_score_limit;
    limits->cumulative_assign_score_limit = cumulative_assign_score_limit;
    limits->cumulative_render_score = INT2FIX(0);
    limits->cumulative_assign_score = INT2FIX(0);
    resource_limits_reset(limits);
    return Qnil;
}

static void increment_render_score(resource_limits_t *limits, VALUE amount)
{
    VALUE score = add_score(limits->render_score, amount);
    rb_check_frozen(limits->self);
    limits->render_score = score;
    VALUE cumulative_score = add_score(limits->cumulative_render_score, amount);
    rb_check_frozen(limits->self);
    limits->cumulative_render_score = cumulative_score;
    if (score_exceeds_limit(limits->render_score, limits->render_score_limit) ||
        score_exceeds_limit(limits->cumulative_render_score, limits->cumulative_render_score_limit)) {
        resource_limits_raise_limits_reached(limits);
    }
}

static VALUE resource_limits_increment_render_score_method(VALUE self, VALUE amount)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    increment_render_score(limits, amount);
    return Qnil;
}

static void increment_assign_score(resource_limits_t *limits, VALUE amount)
{
    VALUE score = add_score(limits->assign_score, amount);
    rb_check_frozen(limits->self);
    limits->assign_score = score;
    VALUE cumulative_score = add_score(limits->cumulative_assign_score, amount);
    rb_check_frozen(limits->self);
    limits->cumulative_assign_score = cumulative_score;
    if (score_exceeds_limit(limits->assign_score, limits->assign_score_limit) ||
        score_exceeds_limit(limits->cumulative_assign_score, limits->cumulative_assign_score_limit)) {
        resource_limits_raise_limits_reached(limits);
    }
}

static VALUE resource_limits_increment_assign_score_method(VALUE self, VALUE amount)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    increment_assign_score(limits, amount);
    return Qnil;
}

void resource_limits_increment_render_score(resource_limits_t *limits, long amount)
{
    increment_render_score(limits, LONG2NUM(amount));
}

void resource_limits_increment_write_score(resource_limits_t *limits, VALUE output)
{
    VALUE last_capture = limits->last_capture_length;
    if (NIL_P(last_capture) && !RTEST(limits->render_length_limit))
        return;
    VALUE captured;
    if (RB_TYPE_P(output, T_STRING) && rb_method_basic_definition_p(CLASS_OF(output), rb_intern("bytesize"))) {
        captured = LONG2NUM(RSTRING_LEN(output));
    } else {
        captured = rb_funcall(output, rb_intern("bytesize"), 0);
    }
    if (!NIL_P(last_capture)) {
        VALUE increment = rb_funcall(captured, rb_intern("-"), 1, last_capture);
        rb_check_frozen(limits->self);
        limits->last_capture_length = captured;
        increment_assign_score(limits, increment);
    } else if (score_exceeds_limit(captured, limits->render_length_limit)) {
        resource_limits_raise_limits_reached(limits);
    }
}

static VALUE resource_limits_increment_write_score_method(VALUE self, VALUE output)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    resource_limits_increment_write_score(limits, output);
    return Qnil;
}

static VALUE resource_limits_raise_limits_reached_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    resource_limits_raise_limits_reached(limits);
    return Qnil;
}

static VALUE resource_limits_reached_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    return limits->reached_limit ? Qtrue : Qfalse;
}

struct capture_ensure_t {
    resource_limits_t *limits;
    VALUE old_capture_length;
};

static VALUE capture_ensure(VALUE data)
{
    struct capture_ensure_t *args = (struct capture_ensure_t *)data;
    rb_check_frozen(args->limits->self);
    args->limits->last_capture_length = args->old_capture_length;
    return Qnil;
}

static VALUE resource_limits_with_capture_method(VALUE self)
{
    rb_check_frozen(self);
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    struct capture_ensure_t args = { limits, limits->last_capture_length };
    limits->last_capture_length = INT2FIX(0);
    return rb_ensure(rb_yield, Qundef, capture_ensure, (VALUE)&args);
}

static VALUE resource_limits_reset_method(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    resource_limits_reset(limits);
    return Qnil;
}

static VALUE resource_limits_marshal_dump(VALUE self)
{
    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    VALUE state = rb_ary_new();
    rb_ary_push(state, limits->render_length_limit);
    rb_ary_push(state, limits->render_score_limit);
    rb_ary_push(state, limits->assign_score_limit);
    rb_ary_push(state, limits->cumulative_render_score_limit);
    rb_ary_push(state, limits->cumulative_assign_score_limit);
    rb_ary_push(state, limits->render_score);
    rb_ary_push(state, limits->assign_score);
    rb_ary_push(state, limits->cumulative_render_score);
    rb_ary_push(state, limits->cumulative_assign_score);
    rb_ary_push(state, limits->reached_limit ? Qtrue : Qfalse);
    rb_ary_push(state, NIL_P(limits->last_capture_length) ? INT2FIX(-1) : limits->last_capture_length);
    return state;
}

static VALUE resource_limits_initialize_copy(VALUE self, VALUE original)
{
    rb_check_frozen(self);
    resource_limits_t *limits, *source;
    ResourceLimits_Get_Struct(self, limits);
    ResourceLimits_Get_Struct(original, source);
    *limits = *source;
    limits->self = self;
    return self;
}

static VALUE resource_limits_marshal_load(VALUE self, VALUE state)
{
    rb_check_frozen(self);
    Check_Type(state, T_ARRAY);
    if (RARRAY_LEN(state) != 11) {
        rb_raise(rb_eArgError, "Invalid resource limits state");
    }

    VALUE reached = RARRAY_AREF(state, 9);
    if (reached != Qtrue && reached != Qfalse) {
        rb_raise(rb_eTypeError, "Resource limits reached state must be boolean");
    }
    VALUE capture = RARRAY_AREF(state, 10);
    if (!NIL_P(capture) && !RB_INTEGER_TYPE_P(capture)) {
        rb_raise(rb_eTypeError, "Resource limits capture length must be an Integer");
    }
    VALUE capture_length = capture == INT2FIX(-1) ? Qnil : capture;

    resource_limits_t *limits;
    ResourceLimits_Get_Struct(self, limits);
    limits->render_length_limit = RARRAY_AREF(state, 0);
    limits->render_score_limit = RARRAY_AREF(state, 1);
    limits->assign_score_limit = RARRAY_AREF(state, 2);
    limits->cumulative_render_score_limit = RARRAY_AREF(state, 3);
    limits->cumulative_assign_score_limit = RARRAY_AREF(state, 4);
    limits->render_score = RARRAY_AREF(state, 5);
    limits->assign_score = RARRAY_AREF(state, 6);
    limits->cumulative_render_score = RARRAY_AREF(state, 7);
    limits->cumulative_assign_score = RARRAY_AREF(state, 8);
    limits->reached_limit = RTEST(RARRAY_AREF(state, 9));
    limits->last_capture_length = capture_length;
    return Qnil;
}

void liquid_define_resource_limits(void)
{
    cLiquidResourceLimits = rb_define_class_under(mLiquidC, "ResourceLimits", rb_cObject);
    rb_global_variable(&cLiquidResourceLimits);
    rb_define_alloc_func(cLiquidResourceLimits, resource_limits_allocate);
    rb_define_method(cLiquidResourceLimits, "initialize", resource_limits_initialize_method, -1);
    rb_define_method(cLiquidResourceLimits, "render_length_limit", resource_limits_render_length_limit_method, 0);
    rb_define_method(cLiquidResourceLimits, "render_length_limit=", resource_limits_set_render_length_limit_method, 1);
    rb_define_method(cLiquidResourceLimits, "render_score_limit", resource_limits_render_score_limit_method, 0);
    rb_define_method(cLiquidResourceLimits, "render_score_limit=", resource_limits_set_render_score_limit_method, 1);
    rb_define_method(cLiquidResourceLimits, "assign_score_limit", resource_limits_assign_score_limit_method, 0);
    rb_define_method(cLiquidResourceLimits, "assign_score_limit=", resource_limits_set_assign_score_limit_method, 1);
    rb_define_method(cLiquidResourceLimits, "cumulative_render_score_limit", resource_limits_cumulative_render_score_limit_method, 0);
    rb_define_method(cLiquidResourceLimits, "cumulative_render_score_limit=", resource_limits_set_cumulative_render_score_limit_method, 1);
    rb_define_method(cLiquidResourceLimits, "cumulative_assign_score_limit", resource_limits_cumulative_assign_score_limit_method, 0);
    rb_define_method(cLiquidResourceLimits, "cumulative_assign_score_limit=", resource_limits_set_cumulative_assign_score_limit_method, 1);
    rb_define_method(cLiquidResourceLimits, "render_score", resource_limits_render_score_method, 0);
    rb_define_method(cLiquidResourceLimits, "assign_score", resource_limits_assign_score_method, 0);
    rb_define_method(cLiquidResourceLimits, "cumulative_render_score", resource_limits_cumulative_render_score_method, 0);
    rb_define_method(cLiquidResourceLimits, "cumulative_assign_score", resource_limits_cumulative_assign_score_method, 0);
    rb_define_method(cLiquidResourceLimits, "increment_render_score", resource_limits_increment_render_score_method, 1);
    rb_define_method(cLiquidResourceLimits, "increment_assign_score", resource_limits_increment_assign_score_method, 1);
    rb_define_method(cLiquidResourceLimits, "increment_write_score", resource_limits_increment_write_score_method, 1);
    rb_define_method(cLiquidResourceLimits, "raise_limits_reached", resource_limits_raise_limits_reached_method, 0);
    rb_define_method(cLiquidResourceLimits, "reached?", resource_limits_reached_method, 0);
    rb_define_method(cLiquidResourceLimits, "with_capture", resource_limits_with_capture_method, 0);
    rb_define_method(cLiquidResourceLimits, "reset", resource_limits_reset_method, 0);
    rb_define_private_method(cLiquidResourceLimits, "initialize_copy", resource_limits_initialize_copy, 1);
    rb_define_method(cLiquidResourceLimits, "marshal_dump", resource_limits_marshal_dump, 0);
    rb_define_method(cLiquidResourceLimits, "marshal_load", resource_limits_marshal_load, 1);
}
