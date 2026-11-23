# frozen_string_literal: true

require "mkmf"
$defs << "-DLIQUID_C_TEST_ALLOC_FAILURES" if ENV["LIQUID_C_TEST_ALLOC_FAILURES"] == "true"
$CFLAGS << " -std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers"
append_cflags("-fvisibility=hidden")
# In Ruby 2.6 and earlier, the Ruby headers did not have struct timespec defined
valid_headers = RbConfig::CONFIG["host_os"] !~ /linux/ || Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.7")
pedantic = !ENV["LIQUID_C_PEDANTIC"].to_s.empty?
if pedantic && valid_headers
  $CFLAGS << " -Werror"
end
if ENV["DEBUG"] == "true"
  append_cflags("-fbounds-check")
  CONFIG["optflags"] = " -O0"
  # Hack to enable assertions since ruby/assert.h disables assertions unless
  # Ruby was compiled with -DRUBY_DEBUG.
  # https://github.com/ruby/ruby/blob/9e678cdbd054f78576a8f21b3f97cccc395ade22/include/ruby/assert.h#L36-L41
  $CFLAGS << (RUBY_ENGINE == "ruby" ? " -DRUBY_DEBUG" : " -DNDEBUG")
else
  $CFLAGS << " -DNDEBUG"
end

have_func "rb_autoload_p"
have_func "st_memsize", "ruby/st.h"
have_func("rb_method_basic_definition_p") if RUBY_ENGINE == "ruby"
["rb_gc_count", "rb_method_call", "rb_obj_init_copy", "rb_str_to_dbl", "rb_big_lshift", "rb_big_or"].each do |function|
  have_func(function)
end
unless have_func("ruby_stack_check")
  $defs << "-D_GNU_SOURCE" if RbConfig::CONFIG["host_os"].include?("linux")
  unless have_func("pthread_getattr_np(pthread_self(), &(pthread_attr_t){0})", "pthread.h") ||
      have_func("pthread_get_stackaddr_np(pthread_self())", "pthread.h")
    abort("Native stack bounds are unavailable on this platform")
  end
end
# Link tests against a static libruby can find hidden symbols which extensions
# cannot resolve at load time (MRI 3.3+). Probe the running process as well.
def mri_exports?(symbol)
  return false unless RUBY_ENGINE == "ruby"

  require "fiddle"
  Fiddle::Handle::DEFAULT[symbol]
rescue LoadError, Fiddle::DLError
  false
end

["rb_callable_method_entry", "rb_hash_compare_by_id_p"].each do |function|
  have_func(function) if mri_exports?(function)
end
if mri_exports?("ruby_vm_event_flags") && try_link(<<~C)
  #define HAVE_RUBY_VM_EVENT_FLAGS 1
  #include "mri_compat.h"
  int main(void) { return liquid_vm_tracing(); }
C
  $defs << "-DHAVE_RUBY_VM_EVENT_FLAGS"
end

$warnflags&.gsub!("-Wdeclaration-after-statement", "")
create_makefile("liquid_c")
