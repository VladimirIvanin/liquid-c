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

have_func "rb_hash_bulk_insert"
have_func "rb_autoload_p"
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
begin
  require "fiddle"
  exported_method_entry = RUBY_ENGINE == "ruby" && Fiddle::Handle::DEFAULT["rb_callable_method_entry"]
rescue LoadError, Fiddle::DLError
  exported_method_entry = false
end
have_func("rb_callable_method_entry") if exported_method_entry
if RUBY_ENGINE == "ruby" && defined?(Fiddle::Handle)
  begin
    exported_hash_identity = Fiddle::Handle::DEFAULT["rb_hash_compare_by_id_p"]
  rescue Fiddle::DLError
    exported_hash_identity = false
  end
  have_func("rb_hash_compare_by_id_p") if exported_hash_identity
end

if RUBY_ENGINE == "ruby" && defined?(Fiddle::Handle)
  begin
    exported_event_flags = Fiddle::Handle::DEFAULT["ruby_vm_event_flags"]
  rescue Fiddle::DLError
    exported_event_flags = false
  end
  if exported_event_flags && try_link(<<~C)
    #include <ruby.h>
    extern rb_event_flag_t ruby_vm_event_flags;
    int main(void) { return (int)ruby_vm_event_flags; }
  C
    $defs << "-DHAVE_RUBY_VM_EVENT_FLAGS"
  end
end

$warnflags&.gsub!("-Wdeclaration-after-statement", "")
create_makefile("liquid_c")
