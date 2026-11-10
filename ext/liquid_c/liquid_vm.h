#ifndef VM_H
#define VM_H

#include <ruby.h>
#include "block.h"
#include "vm_assembler.h"
#include "context.h"

typedef struct vm_variable_frame {
    struct vm_variable_frame *previous;
    VALUE variable;
    const uint8_t *instructions;
    const VALUE *constants;
    const VALUE *nodelist;
    size_t max_stack_size;
} vm_variable_frame_t;

typedef struct vm {
    c_buffer_t stack;
    bool invoking_filter;
    unsigned long context_generation;
    unsigned long context_revision;
    vm_variable_frame_t *variable_frame;
    context_t context;
} vm_t;

void liquid_define_vm(void);
vm_t *vm_from_context(VALUE context);
void liquid_vm_render(block_body_header_t *block, const VALUE *const_ptr, VALUE context, VALUE output, const VALUE *nodelist);
void liquid_vm_next_instruction(const uint8_t **ip_ptr);
bool liquid_vm_filtering(VALUE context);
VALUE liquid_vm_evaluate(VALUE context, vm_assembler_t *code);

#endif
