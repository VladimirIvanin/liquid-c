#ifndef LIQUID_MRI_COMPAT_H
#define LIQUID_MRI_COMPAT_H

#include <ruby.h>
#include <stdbool.h>

// Only functions that extconf found exported by the running MRI are declared.
#ifdef HAVE_RB_HASH_COMPARE_BY_ID_P
RUBY_EXTERN VALUE rb_hash_compare_by_id_p(VALUE hash);
#endif

#endif
