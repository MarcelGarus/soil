; fasm 

format ELF64 executable

segment readable executable

memory_size = 1000000

jmp main

; Syntax notes for function definitions:
; < inputs
; > outputs
; ~ clobbered, e.g. registers that may be overwritten

; Prints something.
; > rsi: pointer to string
; > rdx: length of string
; ~ rax, rdi
print:
  mov rax, 1
  mov rdi, 1
  syscall
  ret

; Panics.
; < rsi: pointer to message
; < rdx: length of message
panic:
  call print
  mov rax, 60
  mov rdi, 1
  syscall
macro panic msg, len {
  mov rsi, msg
  mov rdx, len
  call panic
}

macro todo {
  panic str_todo, str_todo.len
}

; Memory allocation
; =================
;
; Sadly, other parts of the VM need dynamic memory allocation. For example, we
; don't know how big the binary will be that is given to us on stdin. To deal
; with that, we first implement a generic memory bump allocator. It never frees
; memory, but that's okay because we only allocate memory for the binary and the
; VM's memory.

; Initializes the heap.
; ~ rax, rdi
init_heap:
  mov rax, 12 ; brk
  mov rdi, 0  ; brk(0) returns the break (where the data segment ends)
  syscall
  mov [my_heap.head], rax
  mov [my_heap.end], rax
  ret

; Allocates the given amount of memory on the heap.
; < r8: amount to allocate
; < r9: alignment
; > rax: newly allocated address
; ~ rdi, r10, r11, r12
malloc:
  mov r10, [my_heap.head] ; the address of the newly allocated memory
  cmp r9, 8
  jg .error ; alignment must be <= 8
  popcnt r11, r9
  cmp r11, 1
  jne .error  ; alignment must be 1, 2, 4, or 8
  ; rounding up to alignment means r10 = (r10 + (r9 - 1)) & bitmask for lower
  ; for example, for alignment 4: r10 = (r10 + 3) & ...1111100
  add r10, r9
  dec r10
  neg r9 ; make r9 a bitmask; ...1111 or ...1110 or ...1100 or ...1000
  and r10, r9
  ; r10 is now rounded up so that it matches the required alignment
  ; find the end of the allocated data -> r11
  mov r11, r10
  add r11, r8
  cmp r11, [my_heap.end]
  jge .realloc
  mov [my_heap.head], r11
  mov rax, r10
  ret
.realloc:
  ; find the amount to allocate
  mov r12, [my_heap.end]
.find_new_brk:
  add r12, 4096
  cmp r12, r11
  jl .find_new_brk
.found_new_brk:
  push r10
  push r11
  mov rax, 12  ; brk
  mov rdi, r12 ; brk(r12) moves the break to r12
  syscall
  pop r11
  pop r10
  cmp rax, r12
  jl .error ; setting the brk failed
  mov [my_heap.head], r11
  mov [my_heap.end], rax
  mov rax, r10
  ret
.error:
  mov rax, 0
  ret

; Loading the binary
; ==================
;
; The binary comes on stdin. Here, we make the pointer at the `binary` label
; point to a memory region where the binary has been loaded into memory.

load_binary:
  mov r8, memory_size
  mov r9, 1
  call malloc
  mov [binary], rax
  mov qword [binary.cap], memory_size
.read_bytes:
  mov rax, 0
  mov rdi, 0
  mov rsi, [binary]
  mov rdx, [binary.cap]
  syscall
  mov [binary.len], rax
  ret


; Parsing the binary
; ==================
;
; .soil files don't just contain the machine code. They also contain other stuff
; such as debug information. Here, we implement a parser that parses a binary
; and sets up the VM state (registers and memory).
;
; While parsing sections, we always keep the following information in registers:
; - r8: The cursor through the binary.
; - r9: The end of the binary.

init_vm_from_binary:
  ; Allocate memory for the VM.
  mov r8, memory_size
  mov r9, 8
  call malloc
  mov [memory], rax

  ; Parse the binary.
  mov r8, [binary] ; cursor through the binary
  mov r9, [binary.len] ; pointer to the end of the binary
  add r9, r8

  macro eat_byte reg {
    mov reg, [r8]
    inc r8
  }
  macro eat_word reg {
    mov reg, [r8]
    add r8, 8
  }
  macro eat_magic_byte expected {
    eat_byte al
    cmp al, expected
    jne .magic_bytes_mismatch
  }

  eat_magic_byte 's'
  eat_magic_byte 'o'
  eat_magic_byte 'i'
  eat_magic_byte 'l'
  jmp .parse_section

.magic_bytes_mismatch:
  panic str_magic_bytes_mismatch, str_magic_bytes_mismatch.len

.parse_section:
  cmp r8, r9
  jge .done_with_parsing_sections
  eat_byte r10b ; type
  eat_word r11 ; length
  ; type: machine code
  cmp r10b, 0
  je .parse_machine_code
  ; type: unknown
  add r8, r11 ; skip section
  jmp .parse_section

.parse_machine_code:
  ; copy code into memory
  mov r10, r8 ; end of the machine code
  add r10, r11
  ; TODO: assert that machine code fits into memory
  mov r12, [memory] ; cursor through the memory
  ; r8 is the cursor, r10 the end
.copy_machine_code_loop:
  cmp r8, r10
  je .parse_section
  mov r14b, [r8]
  mov [r12], r14b
  inc r8
  inc r12
  jmp .copy_machine_code_loop

.done_with_parsing_sections:
  mov r8, 0 ; ip
  mov r9, 1023 ; sp
  mov r10, 0
  mov r11, 0
  mov r12, 0
  mov r13, 0
  mov r14, 0
  mov r15, 0
  mov rbp, [memory]
  ret


; Running the VM
; ==============
;
; In order for the VM to be fast, it uses hardware registers as much as
; possible. To do that, all Soil registers have corresponding x86_64 registers:
;
; Soil | x86_64
; -----|-------
; ip   | r8
; sp   | r9
; st   | r10
; a    | r11
; b    | r12
; c    | r13
; d    | r14
; e    | r15
;
; The code below also follows some conventions for what goes in which registers:
; - rbp: the base address of the VM memory, never changed
; - rsp: the start of the current instruction
; - rdi: destination
; - rsi: source
; - rax, rbx, rcx, rdx: general purpose, depends on instruction

; Because registers are not first-class in assembly, references to registers
; can't be passed around. That's why it takes some effort to move values in
; and out of registers (called load and store, not to be confused with loading
; and storing bytes from/to memory).
macro mov_if_reg_is dest, source, reg, constant {
  cmp reg, constant
  cmove dest, source
}
macro load_reg dest, reg {
  mov_if_reg_is dest, r8,  reg, 0000b ; ip
  mov_if_reg_is dest, r9,  reg, 0001b ; sp
  mov_if_reg_is dest, r10, reg, 0010b ; st
  mov_if_reg_is dest, r11, reg, 0011b ; a
  mov_if_reg_is dest, r12, reg, 0100b ; b
  mov_if_reg_is dest, r13, reg, 0101b ; c
  mov_if_reg_is dest, r14, reg, 0110b ; d
  mov_if_reg_is dest, r15, reg, 0111b ; e
}
macro store_reg reg, dest {
  mov_if_reg_is r8,  dest, reg, 0000b ; ip
  mov_if_reg_is r9,  dest, reg, 0001b ; sp
  mov_if_reg_is r10, dest, reg, 0010b ; st
  mov_if_reg_is r11, dest, reg, 0011b ; a
  mov_if_reg_is r12, dest, reg, 0100b ; b
  mov_if_reg_is r13, dest, reg, 0101b ; c
  mov_if_reg_is r14, dest, reg, 0110b ; d
  mov_if_reg_is r15, dest, reg, 0111b ; e
}

run:
  mov rsp, r8 ; ip
  add rsp, rbp
  ; Fetch the instruction's opcode and jump to the handler.
  mov rax, 0
  mov al, [rsp]
  mov rbx, [.jump_table + rax * 8]
  jmp rbx
.jump_table:
  ; This macro generates (to - from + 1) pointers to .invalid. Bounds are
  ; inclusive.
  macro invalid_opcodes from, to {
    opcode = from
    while opcode <= to
      dq .invalid
      opcode = opcode + 1
    end while
  }
  dq .nop ; 00
  invalid_opcodes 01h, 9fh
  dq .add ; a0
  dq .sub ; a1
  dq .mul ; a2
  dq .div ; a3
  invalid_opcodes 0a4h, 0afh
  dq .and ; b0
  dq .or ; b1
  dq .xor ; b2
  dq .negate ; b3
  invalid_opcodes 0b4h, 0bfh
  dq .cmp ; c0
  dq .isequal ; c1
  dq .isless ; c2
  dq .isgreater ; c3
  dq .islessequal ; c4
  dq .isgreaterequal ; c5
  invalid_opcodes 0c6h, 0cfh
  dq .move ; d0
  dq .movei ; d1
  dq .moveib ; d2
  dq .load ; d3
  dq .loadb ; d4
  dq .store ; d5
  dq .storeb ; d6
  dq .push ; d7
  dq .pop ; d8
  invalid_opcodes 0d9h, 0dfh
  dq .panic ; e0
  invalid_opcodes 0e1h, 0efh
  dq .jump ; f0
  dq .cjump ; f1
  dq .call ; f2
  dq .ret ; f3
  dq .syscall ; f4
  invalid_opcodes 0f5h, 0ffh

  ; for instructions with one register argument
  macro extract_reg_into_rdi {
    mov dil, [rsp + 1]
    and rdi, 0x0f
  }
  ; for instructions with two register arguments
  macro extract_regs_into_rdi_rsi {
    mov rdi, 0
    mov dil, [rsp + 1]
    mov rsi, rdi
    and rdi, 0x0f
    shr rsi, 4
  }
  macro advance_ip_by num {
    add r8, num
  }
  macro end_of_instruction {
    jmp run
  }

  ; Execute the instruction.
.invalid:
  panic str_unknown_opcode, str_unknown_opcode.len
.nop:
  advance_ip_by 1
  end_of_instruction
.panic:
  panic r11, r12
.move:
  extract_regs_into_rdi_rsi
  load_reg rax, rsi
  store_reg rdi, rax
  advance_ip_by 2
  end_of_instruction
.movei:
  extract_reg_into_rdi
  mov rsi, [rsp + 2]
  store_reg rdi, rsi
  advance_ip_by 10
  end_of_instruction
.moveib:
  extract_reg_into_rdi
  mov rsi, 0
  mov sil, [rsp + 2]
  store_reg rdi, rsi
  advance_ip_by 3
  end_of_instruction
.load:
  extract_regs_into_rdi_rsi
  load_reg rax, rsi
  add rax, rbp
  mov rax, [rax]
  store_reg rdi, rax
  advance_ip_by 2
  end_of_instruction
.loadb:
  extract_regs_into_rdi_rsi
  load_reg rax, rsi
  add rax, rbp
  mov rbx, 0
  mov bl, [rbx]
  store_reg rdi, rbx
  advance_ip_by 2
  end_of_instruction
.store:
  extract_regs_into_rdi_rsi
  load_reg rax, rdi
  load_reg rbx, rsi
  add rax, rbp
  mov [rax], rbx
  advance_ip_by 2
  end_of_instruction
.storeb:
  extract_regs_into_rdi_rsi
  load_reg rax, rdi
  load_reg rbx, rsi
  add rax, rbp
  mov [rax], bl
  advance_ip_by 2
  end_of_instruction
.push:
  extract_reg_into_rdi
  load_reg rax, rdi
  sub r9, 8
  mov rbx, r9
  add rbx, rbp
  mov [rbx], rax
  advance_ip_by 2
  end_of_instruction
.pop:
  extract_reg_into_rdi
  mov rax, r9
  add rax, rbp
  store_reg rdi, [rax]
  add r9, 8
  advance_ip_by 2
  end_of_instruction
.jump:
  mov r8, [rsp + 1]
  end_of_instruction
.cjump:
  advance_ip_by 10
  cmp r10, 0
  cmovne r8, [rsp + 1]
  end_of_instruction
.call:
  sub r9, 8
  mov rax, r9
  add rax, rbp
  mov [rax], r8
  mov r8, [rsp + 1]
  end_of_instruction
.ret:
  mov rax, r9
  add rax, rbp
  mov r8, [rax]
  add r9, 8
  end_of_instruction
.syscall:
  mov rax, 0
  mov al, [rsp + 1]
  mov rax, [syscall_handlers + rax * 8]
  call rax
  advance_ip_by 2
  end_of_instruction
.cmp:
  extract_regs_into_rdi_rsi
  load_reg rax, rdi
  load_reg rbx, rsi
  mov r10, rax
  sub r10, rbx
  advance_ip_by 2
  end_of_instruction
.isequal:
  cmp r10, 0
  mov r10, 0
  mov rax, 1
  cmove r10, rax
  advance_ip_by 1
  end_of_instruction
.isless:
  cmp r10, 0
  mov r10, 0
  mov rax, 1
  cmovl r10, rax
  advance_ip_by 1
  end_of_instruction
.isgreater:
  cmp r10, 0
  mov r10, 0
  mov rax, 1
  cmovg r10, rax
  advance_ip_by 1
  end_of_instruction
.islessequal:
  cmp r10, 0
  mov r10, 0
  mov rax, 1
  cmovle r10, rax
  advance_ip_by 1
  end_of_instruction
.isgreaterequal:
  cmp r10, 0
  mov r10, 0
  mov rax, 1
  cmovge r10, rax
  advance_ip_by 1
  end_of_instruction
.add:
  extract_regs_into_rdi_rsi
  load_reg rax, rdi
  load_reg rbx, rsi
  add rax, rbx
  store_reg rdi, rax
  advance_ip_by 2
  end_of_instruction
.sub:
  extract_regs_into_rdi_rsi
  load_reg rax, rdi
  load_reg rbx, rsi
  sub rax, rbx
  store_reg rdi, rax
  advance_ip_by 2
  end_of_instruction
.mul:
  extract_regs_into_rdi_rsi
  load_reg rax, rdi
  load_reg rbx, rsi
  mul rbx ; rdx:rax = rax * rbx
  store_reg rdi, rax
  advance_ip_by 2
  end_of_instruction
.div:
  extract_regs_into_rdi_rsi
  load_reg rax, rdi
  load_reg rbx, rsi
  mov rdx, 0
  div rbx ; rdx:rax = rdx:rax / rbx
  store_reg rdi, rax
  advance_ip_by 2
  end_of_instruction
.and:
  extract_regs_into_rdi_rsi
  load_reg rax, rdi
  load_reg rbx, rsi
  and rax, rbx
  store_reg rdi, rax
  advance_ip_by 2
  end_of_instruction
.or:
  extract_regs_into_rdi_rsi
  load_reg rax, rdi
  load_reg rbx, rsi
  or rax, rbx
  store_reg rdi, rax
  advance_ip_by 2
  end_of_instruction
.xor:
  extract_regs_into_rdi_rsi
  load_reg rax, rdi
  load_reg rbx, rsi
  xor rax, rbx
  store_reg rdi, rax
  advance_ip_by 2
  end_of_instruction
.negate:
  extract_reg_into_rdi
  load_reg rax, rdi
  neg rax
  store_reg rdi, rax
  advance_ip_by 2
  end_of_instruction

; Main function
; =============

main:
  call init_heap
  call load_binary
  call init_vm_from_binary
  call run
  mov rax, 60
  mov rdi, 0
  syscall

; Syscalls
; =======

syscall_exit:
  mov rax, 60 ; exit syscall
  mov rdi, [rbp + r11] ; status code (from the a register)
  syscall

syscall_print:
  mov rax, 1 ; write syscall
  mov rdi, 1 ; stdout
  lea rsi, [rbp + r11] ; pointer to string (from the a register)
  mov rdx, r12 ; length of the string (from the b register)
  syscall
  ret

syscall_log:
  mov rax, 1 ; write syscall
  mov rdi, 2 ; stderr
  lea rsi, [rbp + r11] ; pointer to message (from the a register)
  mov rdx, r12 ; length of the message (from the b register)
  syscall
  ret

segment readable writable

my_heap:
  .head: dq 0
  .end: dq 0

str_foo: db "foo", 0xa
  .len = ($ - str_foo)
str_magic_bytes_mismatch: db "Magic bytes don't match", 0xa
  .len = ($ - str_magic_bytes_mismatch)
str_oom: db "Out of memory", 0xa
  .len = ($ - str_oom)
str_todo: db "Todo", 0xa
  .len = ($ - str_todo)
str_unknown_opcode: db "Unknown opcode", 0xa
  .len = ($ - str_unknown_opcode)

binary:
  dq 8
  .len: dq 0
  .cap: dq 0
memory:
  dq 8

syscall_handlers:
  dq syscall_exit
  dq syscall_print
  dq syscall_log
  dq 253 dup 0
