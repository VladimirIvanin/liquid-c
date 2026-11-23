#ifndef LIQUID_MRI_COMPAT_H
#define LIQUID_MRI_COMPAT_H

#include <ruby.h>
#include <stdbool.h>

// extconf probes the running MRI before enabling these optional interfaces.
#ifdef HAVE_RB_CALLABLE_METHOD_ENTRY
struct rb_callable_method_entry_struct;
RUBY_EXTERN const struct rb_callable_method_entry_struct *rb_callable_method_entry(VALUE klass, ID method);

static inline VALUE liquid_method_entry(VALUE klass, ID method)
{
    return (VALUE)rb_callable_method_entry(klass, method);
}
#endif

#ifdef HAVE_RUBY_VM_EVENT_FLAGS
RUBY_EXTERN rb_event_flag_t ruby_vm_event_flags;

static inline bool liquid_vm_tracing(void)
{
    return ruby_vm_event_flags != 0;
}
#endif

#ifdef HAVE_RB_HASH_COMPARE_BY_ID_P
RUBY_EXTERN VALUE rb_hash_compare_by_id_p(VALUE hash);
#endif

#if defined(HAVE_RB_CALLABLE_METHOD_ENTRY) && defined(HAVE_RUBY_VM_EVENT_FLAGS)
#define LIQUID_HAVE_GUARDED_COMPILER 1
#endif

#endif
