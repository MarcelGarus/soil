; Soil interpreter that uses JIT compilation
; ==========================================
;
; This file contains an interpreter for Soil binaries. Upon start, it parses the
; binary and translates the byte code into x86_64 machine code instructions. It
; then jumps to those instructions. That causes the CPU hardware to directly
; execute the (translated) code written in Soil, without the overhead of an
; interpreter.
;
; TODO: Benchmark performance
;
; This file is intended to be compiled using fasm, the flat assembler:
; https://flatassembler.net/
; Fasm is nice because it allows specifying macros and constants, making the
; assembly a bit more readable.

; This file compiles directly to an ELF executable, not an .o file that then
; needs to be linked.
format ELF64 executable

segment readable executable

memory_size = 100000000

jmp main

; Throughout this file, I use the following syntax:
; < inputs
; > outputs
; ~ clobbered, e.g. registers that may have been overwritten

; The syscall instruction:
; < rax, rdi, rsi, rdx, ...
; > rax
; ~ rcx, r11: https://stackoverflow.com/questions/69515893/when-does-linux-x86-64-syscall-clobber-r8-r9-and-r10

macro push_syscall_clobbers {
  push rax
  push rdi
  push rsi
  push rcx
  push r11
}
macro pop_syscall_clobbers {
  pop r11
  pop rcx
  pop rsi
  pop rdi
  pop rax
}

macro exit status {
  mov rax, 60
  mov rdi, status
  syscall
}

; Prints something to stdout.
; < rax: pointer to string
; < rbx: length of string
print:
  push_syscall_clobbers
  mov rsi, rax
  mov rax, 1 ; write
  mov rdi, 1 ; stdout
  mov rdx, rbx
  syscall
  pop_syscall_clobbers
  ret

; Prints something to stderr.
; < rax: pointer to string
; < rbx: length of string
eprint:
  push_syscall_clobbers
  mov rsi, rax
  mov rax, 1 ; write
  mov rdi, 2 ; stderr
  mov rdx, rbx
  syscall
  pop_syscall_clobbers
  ret

macro eprint msg, len { ; msg can't be rdi or rsi. len can't be rdi, rsi, rdx
  push_syscall_clobbers
  mov rax, 1 ; write
  mov rdi, 2 ; stderr
  mov rsi, msg
  mov rdx, len
  syscall
  pop_syscall_clobbers
}

; Panics with a message. Doesn't return.
; < rax: pointer to message
; < rbx: length of message
panic:
  call eprint
  exit 1
macro panic msg, len {
  mov rax, msg
  mov rbx, len
  call panic
}
macro todo { panic str_todo, str_todo.len }

macro replace_byte_with_hex_digit target, with { ; clobbers rbx, rcx
  mov cl, 48 ; ASCII 0
  cmp with, 10
  mov rbx, 97
  cmovge rcx, rbx ; ASCII a
  add cl, with
  mov [target], cl
}
macro replace_two_bytes_with_hex_byte target, with { ; clobbers rbx, rcx, dl
  mov dl, with
  shr with, 4
  replace_byte_with_hex_digit target, with
  mov with, dl
  and with, 0fh
  mov rdx, target
  inc rdx
  replace_byte_with_hex_digit rdx, with
}

; Memory allocation
; =================
;
; This program needs dynamic memory allocation, for example, to store the binary
; and the compiled instructions in memory. The sbrk ("set break") syscall allows
; finding and setting the "break" of the program, aka the address where the data
; section ends.
;
; This is how the virtual address space of the program looks like:
;
; +---+--------------+----------------+-----------------------------+----------+
; | - | machine code | data           |  -                          | stack    |
; +---+--------------+----------------+-----------------------------+----------+
;   ^             ^      ^            ^             ^                   ^
;   |             |      |            |             |                   |
; unmapped so     |  all the stuff    |     lots and lots of            |
; that 0x0 is     |  the program      |     unmapped addresses          |
; always invalid  |  needs to save    |                                 |
;                 |                "the break",                automatically
;      the instructions            modified by the             grows downward
;      from this file              sbrk syscall
;
; Memory management uses a "bump allocator": It stores a heap head and a heap
; end. Initially, both point to the break, where the data section ends.
;
; ... data | unmapped                        ...
; ---------+------------------------------------
;          ^
;          head
;          end
;
; When you allocate something, it checks if there is enough space between the
; heap head and the heap end.
; 
; - If there is enough space:
;
;   ... used | unused             | unmapped ...
;   ---------+--------------------+-------------
;            ^                    ^
;            head                 end
;
;   Increment the head by the amount to allocate. Return the previous head as
;   the address where the data can be stored.
;
;   ... used | new     | unused   | unmapped ...
;   ---------+---------+----------+-------------
;            ^         ^          ^
;            returned  head       end
;
; - If there is not enough space:
;
;   ... used | | unmapped                    ...
;   ---------+-+--------------------------------
;            ^ ^
;         head end
;
;   Perform an sbrk syscall to allocate enough memory, rounded up to entire
;   memory pages (4096 bytes).
;
;   ... used | unused             | unmapped ...
;   ---------+--------------------+-------------
;            ^                    ^
;            head                 end
;
; Memory is never freed.

; Initializes the heap.
; ~ rax, rdi
init_heap:
  mov rax, 12 ; sbrk
  mov rdi, 0  ; sbrk(0) returns the break (where the data segment ends)
  syscall
  mov [my_heap.head], rax
  mov [my_heap.end], rax
  ret

; Allocates the given amount of memory on the heap. Consecutively allocated
; memory is guaranteed to live next to each other. Panics if out of memory.
; < rax: amount to allocate
; > rax: newly allocated address
malloc:
  push r8
  push r9
  mov r8, [my_heap.head] ; the address of the newly allocated memory
  ; find the end of the allocated data -> r9
  mov r9, r8
  add r9, rax
  cmp r9, [my_heap.end]
  jge .realloc
  mov [my_heap.head], r9
  mov rax, r8
  pop r9
  pop r8
  ret
.realloc:
  push r10
  ; find the amount to allocate
  mov r10, [my_heap.end]
.find_new_brk:
  add r10, 4096
  cmp r10, r9
  jl .find_new_brk
.found_new_brk:
  push rcx
  push r11
  push rdi
  mov rax, 12  ; sbrk
  mov rdi, r10 ; sbrk(r10) moves the break to r10
  syscall
  pop rdi
  pop r11
  pop rcx
  cmp rax, r10
  jl .error ; setting the brk failed
  mov [my_heap.head], r9
  mov [my_heap.end], rax
  mov rax, r8
  pop r10
  pop r9
  pop r8
  ret
.error:
  panic str_oom, str_oom.len

; The generated machine code must be page-aligned. Because our heap only
; allocates full pages, the current end is the next page-aligned address.
advance_heap_to_next_page:
  mov rax, [my_heap.end]
  mov [my_heap.head], rax
  ret

; Appends a byte to the heap. This is useful when we store data parts of dynamic
; size such as when reading the input – just store the current heap head, emit
; all the bytes, and you have a continuous memory region with the data.
; Doing something like that in higher-level languages when you don't know the
; size upfront requires copying data (a typical ArrayList would allocate new
; memory twice the size when it's full and then copy all the original data).
;
; < b cannot be rax
; ~ rax
macro emit_byte b {
  mov rax, 1
  call malloc
  mov byte [rax], b
}
macro emit_bytes [b] {
  emit_byte b
}

; Loading the binary
; ==================
;
; The binary comes on stdin. Here, we make the pointer at the `binary` label
; point to a memory region where the binary has been loaded into memory.

load_binary:
  mov rax, r10
  mov rax, 2            ; open syscall
  mov rdi, [saved_argv]
  add rdi, 8
  mov rdi, [rdi]        ; argv[1] -> the file path
  mov rsi, 0            ; flags: RDONLY
  mov rdx, 0            ; mode: ignored anyways because we don't create a file
  syscall
  cmp rax, 0
  jle .couldnt_open_file
  mov rdi, rax
  mov rbx, [my_heap.head]
  mov [binary], rbx
.load_more:
  mov rax, 128
  call malloc
  mov rsi, rax ; buffer
  mov rax, 0   ; read
  ; the file descriptor is already in rdi
  mov rdx, 128 ; size
  syscall
  cmp rax, 128
  jl .done_loading
  jmp .load_more
.done_loading:
  add rax, rsi ; address of end
  sub rax, [binary] ; length of binary
  mov [binary.len], rax
  mov rax, 3   ; close syscall
  ; the file descriptor is already in rdi
  syscall
  ret
.couldnt_open_file:
  panic str_couldnt_open_file, str_couldnt_open_file.len


; Compiling the binary
; ====================
;
; .soil files contain the byte code, initial memory, debug information, etc.
; Here, we parse the binary and set up the VM. In particular, we initialize the
; memory and JIT-compile the byte code into x86_64 machine code.
;
; In the generated code, Soil registers are mapped to x86_64 registers:
;
; Soil | x86_64
; -----|-------
; sp   | r8
; st   | r9
; a    | r10
; b    | r11
; c    | r12
; d    | r13
; e    | r14
; f    | r15
;      | rbp: Base address of the memory.
;
; While parsing sections, we always keep the following information in registers:
; - r8: cursor through the binary
; - r9: end of the binary

compile_binary:
  ; Allocate memory for the VM.
  ; Allocate one byte more than memory_size so that syscalls that need null-
  ; terminated strings can temporarily swap out one byte after a string in
  ; memory, even if it's at the end of the VM memory.
  mov rax, memory_size
  inc rax
  call malloc
  mov [memory], rax

  ; Parse the binary.
  mov r8, [binary] ; cursor through the binary
  mov r9, [binary.len] ; pointer to the end of the binary
  add r9, r8

  macro eat_byte reg {
    mov reg, [r8] ; reg is expected to be an 8-bit register
    inc r8
  }
  macro eat_word reg {
    mov reg, [r8] ; reg is expected to be a 64-bit register
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
  ; type: byte code
  cmp r10b, 0
  je .parse_byte_code
  ; type: initial memory
  cmp r10b, 1
  je .parse_initial_memory
  ; type: labels
  cmp r10b, 3
  je .parse_labels
  ; type: unknown
  add r8, r11 ; skip section
  jmp .parse_section

.done_with_parsing_sections:
  ret

; Copies the initial memory into the actual memory section.
.parse_initial_memory:
  mov r10, r8
  add r10, r11 ; end of the initial memory
  ; TODO: assert that initial memory fits into memory
  mov r12, [memory] ; cursor through the memory
  ; r8 is the cursor, r10 the end
.copy_memory_loop:
  cmp r8, r10
  je .parse_section
  mov r14b, [r8]
  mov [r12], r14b
  inc r8
  inc r12
  jmp .copy_memory_loop

; Loads all the labels.
.parse_labels:
; .dbg: jmp .dbg
  eat_word r10 ; number of labels
  mov [labels.len], r10
  mov rax, r10
  imul rax, 24
  call malloc
  mov [labels], rax
  mov r11, 0 ; the number of labels we have already parsed
.parse_label:
  cmp r11, r10
  je .done_parsing_labels
  eat_word r12 ; byte code offset
  eat_word r13 ; length
  ; save the label to the labels
  mov r15, r11
  imul r15, 24
  add r15, [labels]
  mov [r15], r12
  mov [r15 + 8], r8
  mov [r15 + 16], r13
  add r8, r13 ; label length
  ; next one
  inc r11
  jmp .parse_label
.done_parsing_labels:
  jmp .parse_section

; JIT compiles the byte code into x86_64 machine code.
;
; During the instruction translation, the following registers are kept intact:
; r8:  The cursor through the binary.
; r9:  The end of the entire binary.
; r10: The start of the byte code.
; r11: The end of the byte code section.
.parse_byte_code:
  mov r10, r8
  ; This Soil interpreter only supports 4 GiB of code, which should be enough
  ; for most programs (this is not a limit of the memory it uses, only of the
  ; machine code). As a result, we use 4 bytes for indexing into the code.
  ;
  ; Apart from generating machine code, we also create the following:
  ;
  ; - A map from byte code offsets to machine code offsets. It's sized
  ;   4*len(byte code + 1). For every byte code byte, it stores a uint32 offset
  ;   into the machine code. Only the entries where byte code instructions start
  ;   are meaningful. TODO: change that.
  ; - A map from machine code offsets to byte code offsets. It's sized
  ;   4*len(byte code + 1)
  ; - Patches for jumps store a position in the machine code (4 bytes) and a
  ;   target in the byte code (4 bytes). Because a jump instruction in the byte
  ;   code takes an 8 byte target argument, allocating len(byte code) for
  ;   patches is enough.
  lea rax, [r11 * 4 + 4] ; for now, r11 is still the length of the byte code
  call malloc
  mov [byte_code_to_machine_code], rax
  mov rbx, 0
  mov [byte_code_to_machine_code.len], rbx
  lea rax, [r11 * 8 + 4] ; TODO: this is only a rough guess
  call malloc
  mov [machine_code_to_byte_code], rax
  mov rbx, 0
  mov [machine_code_to_byte_code.len], rbx
  mov rax, r11
  call malloc
  mov [patches], rax
  mov rbx, 0
  mov [patches.len], rbx
  add r11, r10 ; from now on, r11 points to the end of the byte code section
  ; To be able to change the memory protection of the machine code, it needs to
  ; be aligned to page boundaries.
  call advance_heap_to_next_page
  mov [machine_code], rax
.parse_instruction:
  cmp r8, r11
  jge .done_parsing_all_instructions
  mov r12, 0
  eat_byte r12b
  mov r13, [.jump_table + r12 * 8]
  jmp r13
.instruction_parsed:
  ; Add mappings between byte code and machine code.
  mov r12, [byte_code_to_machine_code.len] ; byte code offset
  mov r13, [machine_code_to_byte_code.len] ; machine code offset
.add_mappings_byte_to_machine_code:
  mov r14, [byte_code_to_machine_code.len]
  mov r15, r8
  sub r15, r10 ; byte code offset of next instruction
  cmp r14, r15
  jge .add_mappings_machine_to_byte_code
  lea r15, [r14 * 4]
  add r15, [byte_code_to_machine_code]
  mov [r15], r13
  inc r14
  mov [byte_code_to_machine_code.len], r14
  jmp .add_mappings_byte_to_machine_code
.add_mappings_machine_to_byte_code:
  mov r14, [machine_code_to_byte_code.len]
  mov r15, [my_heap.head]
  sub r15, [machine_code]
  cmp r14, r15
  jge .parse_instruction
  lea r15, [r14 * 4]
  add r15, [machine_code_to_byte_code]
  mov [r15], r12
  inc r14
  mov [machine_code_to_byte_code.len], r14
  jmp .add_mappings_machine_to_byte_code
.done_parsing_all_instructions:
  mov r10, [my_heap.head]
  sub r10, [machine_code]
  mov [machine_code.len], r10
  call advance_heap_to_next_page
  ; Fix patches
  mov r10, 0 ; cursor through patches
  mov r11, [patches.len]
.fix_patch:
  cmp r10, r11
  je .done_fixing_patches
  ; Calculate the absolute position of the target that needs to be patched.
  mov r12, [patches]
  lea r12, [r12 + r10 * 8]
  mov r13, 0
  mov r13d, [r12]
  add r13, [machine_code]
  mov r12, r13
  ; Calculate the patch target.
  mov r13, [patches]
  lea r13, [r13 + r10 * 8 + 4]
  mov r14, 0
  mov r14d, [r13] ; index into the byte code
  shl r14, 2
  add r14, [byte_code_to_machine_code]
  mov r13, 0
  mov r13d, [r14] ; index into the machine code
  add r13, [machine_code] ; absolute target
  ; Patch the target.
  sub r13, r12 ; jump is relative
  sub r13, 4 ; ... to the end of the jump/call instruction
  mov [r12], r13d
  inc r10
  jmp .fix_patch
.done_fixing_patches:
  jmp .parse_section

.jump_table:
  ; This macro generates (to - from + 1) pointers to compile_invalid. Both
  ; bounds are inclusive.
  macro invalid_opcodes from, to {
    opcode = from
    while opcode <= to
      dq compile_invalid
      opcode = opcode + 1
    end while
  }
  dq compile_nop ; 00
  invalid_opcodes 01h, 9fh
  dq compile_add ; a0
  dq compile_sub ; a1
  dq compile_mul ; a2
  dq compile_div ; a3
  dq compile_rem ; a4
  invalid_opcodes 0a5h, 0afh
  dq compile_and ; b0
  dq compile_or ; b1
  dq compile_xor ; b2
  dq compile_not ; b3
  invalid_opcodes 0b4h, 0bfh
  dq compile_cmp ; c0
  dq compile_isequal ; c1
  dq compile_isless ; c2
  dq compile_isgreater ; c3
  dq compile_islessequal ; c4
  dq compile_isgreaterequal ; c5
  invalid_opcodes 0c6h, 0cfh
  dq compile_move ; d0
  dq compile_movei ; d1
  dq compile_moveib ; d2
  dq compile_load ; d3
  dq compile_loadb ; d4
  dq compile_store ; d5
  dq compile_storeb ; d6
  dq compile_push ; d7
  dq compile_pop ; d8
  invalid_opcodes 0d9h, 0dfh
  dq compile_panic ; e0
  invalid_opcodes 0e1h, 0efh
  dq compile_jump ; f0
  dq compile_cjump ; f1
  dq compile_call ; f2
  dq compile_ret ; f3
  dq compile_syscall ; f4
  invalid_opcodes 0f5h, 0ffh

macro instruction_end {
  jmp compile_binary.instruction_parsed
}

  ; for instructions with one register argument
  macro eat_reg_into_dil {
    eat_byte dil
    and rdi, 0x0f
  }
  ; for instructions with two register arguments
  macro eat_regs_into_dil_sil {
    mov rdi, 0
    eat_byte dil
    mov rsi, rdi
    and rdi, 0x0f
    shr rsi, 4
  }
  ; < value can't be rax
  ; ~ rax
  macro emit_word value {
    mov rax, 8
    call malloc
    mov qword [rax], value
  }

  ; Turns out, the encoding of x86_64 instructions is ... interesting. These
  ; helper macros emit the machine code instructions.

  macro emit_8_times_a a { ; (8 * <a>)
    shl a, 3
    emit_byte a
    shr a, 3
  }
  macro emit_value_plus_a value, a { ; (<value> + <a>)
    add a, value
    emit_byte a
    sub a, value
  }
  macro emit_value_plus_8_times_a value, a {
    shl a, 3
    emit_value_plus_a value, a
    shr a, 3
  }
  macro emit_a_plus_8_times_b a, b { ; (<a> + 8 * <b>)
    shl b, 3
    add a, b
    emit_byte a
    sub a, b
    shr b, 3
  }
  macro emit_c0_plus_a_plus_8_times_b a, b { ; (c0 + <a> + 8 * <b>)
    shl b, 3
    add b, a
    emit_value_plus_a 0c0h, b
    sub b, a
    shr b, 3
  }
  macro emit_relative_patch target { ; target can't be r12 or r13
    push r12
    push r13
    mov r12, [patches]
    mov r13, [patches.len]
    lea r12, [r12 + r13 * 8]
    inc r13
    mov [patches.len], r13
    mov r13, [my_heap.head]
    sub r13, [machine_code]
    mov [r12], r13d
    mov r13, target
    mov [r12 + 4], r13d
    pop r13
    pop r12
    emit_bytes 00h, 00h, 00h, 00h
  }
  macro emit_relative_comptime target { ; target can't be r12
    push r12
    mov r12, target
    sub r12, [my_heap.head]
    sub r12, 4 ; the address is relative to the end of the instruction
    mov rax, 4
    call malloc
    mov [rax], r12d
    pop r12
  }

  macro emit_add_soil_soil a, b { ; add a, b
    emit_bytes 4dh, 01h
    emit_c0_plus_a_plus_8_times_b a, b
  }
  macro emit_add_r8_8 { emit_bytes 49h, 83h, 0c0h, 08h } ; add r8, 8
  macro emit_add_rax_rbp { emit_bytes 48h, 89h, 0e8h } ; mov rax, rbp
  macro emit_and_soil_0xff a {
    emit_bytes 49h, 81h
    emit_value_plus_a 0e0h, a
    emit_bytes 0ffh, 00h, 00h, 00h
  }
  macro emit_and_r9_0xff { emit_bytes 49h, 81h, 0e1h, 0ffh, 00h, 00h, 00h } ; and r9, 0xff
  macro emit_and_rax_0xff { emit_bytes 48h, 25h, 0ffh, 00h, 00h, 00h } ; and rax, 0ffh
  macro emit_and_soil_soil a, b { ; and <a>, <b>
    emit_bytes 4dh, 21h
    emit_c0_plus_a_plus_8_times_b a, b
  }
  macro emit_call target { ; call <target> ; target can't be r12 or r13
    emit_byte 0e8h
    emit_relative_patch target
  }
  macro emit_call_comptime target { ; call <target> ; target can't be r12 or rax
    emit_byte 0e8h
    mov r12, target
    sub r12, [my_heap.head]
    sub r12, 4
    mov rax, 4
    call malloc
    mov qword [rax], r12
  }
  macro emit_idiv_soil a { ; idiv <a>
    emit_bytes 49h, 0f7h
    emit_value_plus_a 0f8h, a
  }
  macro emit_imul_soil_soil a, b { ; and <a>, <b>
    emit_bytes 4dh, 0fh, 0afh
    emit_c0_plus_a_plus_8_times_b b, a ; yes, these are flipped
  }
  macro emit_jmp target { ; jmp <target> ; target can't be r12 or r13
    emit_byte 0e9h
    emit_relative_patch target
  }
  macro emit_jmp_to_comptime target { ; jmp <target> ; target can't be r12 or rax
    emit_byte 0e9h
    mov r12, target
    sub r12, [my_heap.head]
    sub r12, 4
    mov rax, 4
    call malloc
    mov qword [rax], r12
  }
  macro emit_jnz target { ; jnz <target> ; target can't be r12 or r13
    emit_bytes 0fh, 85h
    emit_relative_patch target
  }
  macro emit_mov_al_byte a { ; move al, <a>
    emit_bytes 0b0h
    emit_byte a
  }
  macro emit_mov_rax_soil a { ; mov rax, <a>
    emit_bytes 4ch, 89h
    emit_value_plus_8_times_a 0c0h, a
  }
  macro emit_mov_mem_of_rbp_plus_soil_soil a, b { ; mov [rbp + <a>], <b>
    emit_bytes 4dh, 89h
    cmp a, 5 ; for <a> = r13, the encoding is different
    jz .foo
    emit_value_plus_8_times_a 04h, b
    emit_value_plus_a 28h, a
    jmp .bar
    .foo:
    emit_value_plus_8_times_a 44h, b
    emit_bytes 2dh, 00h
    .bar:
  }
  macro emit_mov_mem_of_rbp_plus_soil_soilb a, b { ; mov [rbp + <a>], <b>b
    emit_bytes 45h, 88h
    cmp a, 5 ; for <a> = r13, the encoding is different
    jz .foo
    emit_value_plus_8_times_a 04h, b
    emit_value_plus_a 28h, a
    jmp .bar
    .foo:
    emit_value_plus_8_times_a 44h, b
    emit_bytes 2dh, 00h
    .bar:
  }
  macro emit_mov_soil_rdx a { ; mov <a>, rdx
    emit_bytes 49h, 89h
    emit_value_plus_a 0d0h, a
  }
  macro emit_mov_soil_rax a { ; mov <a>, rax
    emit_bytes 49h, 89h
    emit_value_plus_a 0c0h, a
  }
  macro emit_mov_soil_mem_of_rdp_plus_soil a, b { ; mov <a>, [rbp + <b>]
    emit_bytes 4dh, 8bh
    cmp b, 5 ; for <b> = r13, the encoding is different
    jz .foo
    emit_value_plus_8_times_a 04h, a
    emit_value_plus_a 28h, b
    jmp .bar
    .foo:
    emit_value_plus_8_times_a 44h, a
    emit_bytes 2dh, 00h
    .bar:
  }
  macro emit_mov_soilb_mem_of_rbp_plus_soil a, b { ; mov <a>b, [rbp + <b>]
    emit_bytes 45h, 8ah
    cmp b, 5 ; for <b> = r13, the encoding is different
    jz .foo
    emit_value_plus_8_times_a 04h, a
    emit_value_plus_a 28h, b
    jmp .bar
    .foo:
    emit_value_plus_8_times_a 44h, a
    emit_bytes 2dh, 00h
    .bar:
  }
  macro emit_mov_soil_soil a, b { ; mov <a>, <b>
    emit_bytes 4dh, 89h
    emit_c0_plus_a_plus_8_times_b a, b
  }
  macro emit_mov_soil_word a, value { ; mov <a>, <value> -> 49 (b8 + a) (value)
    ; Example: mov r8, aabbccddeeffh -> 49 b8 ff ee dd cc bb aa 00 00
    emit_byte 49h
    emit_value_plus_a 0b8h, a
    emit_word value
  }
  macro emit_mov_soil_byte a, value { ; mov <a>b, <value> -> 41 (b0 + a) (value)
    emit_byte 41h
    emit_value_plus_a 0b0h, a
    emit_byte value
  }
  macro emit_mov_rax_mem_of_rax { emit_bytes 48h, 8bh, 00h } ; mov rax, [rax]
  macro emit_nop { emit_byte 90h } ; nop
  macro emit_not_r9 { emit_bytes 49h, 0f7h, 0d1h } ; not r9
  macro emit_not_soil a { ; not a
    emit_bytes 49h, 0f7h
    emit_value_plus_a 0d0h, a
  }
  macro emit_or_soil_soil a, b { ; or <a>, <b>
    emit_bytes 4dh, 09h
    emit_c0_plus_a_plus_8_times_b a, b
  }
  macro emit_ret { emit_byte 0c3h } ; ret
  macro emit_shr_r9_63 { emit_bytes 49h, 0c1h, 0e9h, 3fh } ; shr r9, 63
  macro emit_sete_r9b { emit_bytes 41h, 0fh, 94h, 0c1h } ; sete r9b
  macro emit_setg_r9b { emit_bytes 41h, 0fh, 9fh, 0c1h } ; setg r9b
  macro emit_setle_r9b { emit_bytes 41h, 0fh, 9eh, 0c1h } ; setle r9b
  macro emit_sub_soil_soil a, b { ; sub <a>, <b>
    emit_bytes 4dh, 29h
    emit_c0_plus_a_plus_8_times_b a, b
  }
  macro emit_sub_r8_8 { emit_bytes 49h, 83h, 0e8h, 08h } ; sub r8, 8
  macro emit_test_r9_r9 { emit_bytes 4dh, 85h, 0c9h } ; test r9, r9
  macro emit_xor_rdx_rdx { emit_bytes 48h, 31h, 0d2h } ; xor rdx, rdx
  macro emit_xor_soil_soil a, b { ; xor <a>, <b>
    emit_bytes 4dh, 31h
    emit_c0_plus_a_plus_8_times_b a, b
  }

compile_invalid: replace_two_bytes_with_hex_byte (str_unknown_opcode + str_unknown_opcode.hex_offset), r12b
                panic str_unknown_opcode, str_unknown_opcode.len
compile_nop:    nop                           ; nop
                instruction_end
compile_panic:  emit_call_comptime panic_with_info ; call panic_with_info
                instruction_end
compile_move:   eat_regs_into_dil_sil
                emit_mov_soil_soil dil, sil   ; mov <to>, <from>
                instruction_end
compile_movei:  eat_reg_into_dil
                eat_word r12
                emit_mov_soil_word dil, r12   ; mov <to>, <word>
                instruction_end
compile_moveib: eat_reg_into_dil
                eat_byte r12b
                mov sil, dil
                emit_xor_soil_soil dil, sil   ; xor <to>, <to>
                emit_mov_soil_byte dil, r12b  ; mov <to>b, <byte>
                instruction_end
compile_load:   eat_regs_into_dil_sil
                emit_mov_soil_mem_of_rdp_plus_soil dil, sil ; mov <to>, [rbp + <from>]
                instruction_end
compile_loadb:  eat_regs_into_dil_sil
                emit_mov_soilb_mem_of_rbp_plus_soil dil, sil ; mov <to>b, [rbp + <from>]
                emit_and_soil_0xff dil        ; and <to>, 0ffh
                instruction_end
compile_store:  eat_regs_into_dil_sil
                emit_mov_mem_of_rbp_plus_soil_soil dil, sil ; mov [rbp + <to>], <from>
                instruction_end
compile_storeb: eat_regs_into_dil_sil
                emit_mov_mem_of_rbp_plus_soil_soilb dil, sil ; mov [rbp + <to>], <from>b
                instruction_end
compile_push:   eat_reg_into_dil
                emit_sub_r8_8                 ; sub r8, 8
                mov sil, 0 ; sp
                emit_mov_mem_of_rbp_plus_soil_soil sil, dil ; mov [rbp + r8], <from>
                instruction_end
compile_pop:    eat_reg_into_dil
                mov sil, 0 ; sp
                emit_mov_soil_mem_of_rdp_plus_soil dil, sil ; mov <a>, [rbp + r8]
                emit_add_r8_8                 ; add r8, 8
                instruction_end
compile_jump:   eat_word r14
                emit_jmp r14                  ; jmp <target>
                instruction_end
compile_cjump:  eat_word r14
                emit_test_r9_r9               ; test r9, r9
                emit_jnz r14                  ; jmp <target>
                instruction_end
compile_call:   eat_word r14
                emit_call r14                 ; call <target>
                instruction_end
compile_ret:    emit_ret                      ; ret
                instruction_end
compile_syscall: mov r14, 0
                eat_byte r14b
                emit_mov_al_byte r14b         ; mov al, <syscall-number>
                mov r14, [syscalls.table + 8 * r14]
                emit_call_comptime r14        ; call <syscall>
                instruction_end
compile_cmp:    eat_regs_into_dil_sil
                mov bl, 1 ; st = r9
                emit_mov_soil_soil bl, dil    ; mov r9, <left>
                emit_sub_soil_soil bl, sil    ; sub r9, <right>
                instruction_end
compile_isequal: emit_test_r9_r9               ; test r9, r9
                emit_sete_r9b                 ; sete r9b
                emit_and_r9_0xff              ; and r9, 0fh
                instruction_end
compile_isless: emit_shr_r9_63                ; shr r9, 63
                instruction_end
compile_isgreater: emit_test_r9_r9             ; test r9, r9
                emit_setg_r9b                 ; setg r9b
                emit_and_r9_0xff              ; and r9, 0fh
                instruction_end
compile_islessequal: emit_test_r9_r9           ; test r9, r9
                emit_setle_r9b                ; setle r9b
                emit_and_r9_0xff              ; and r9, 0fh
                instruction_end
compile_isgreaterequal: emit_not_r9            ; not r9
                emit_shr_r9_63                ; shr r9, 63
                instruction_end
compile_add:    eat_regs_into_dil_sil
                emit_add_soil_soil dil, sil   ; add <to>, <from>
                instruction_end
compile_sub:    eat_regs_into_dil_sil
                emit_sub_soil_soil dil, sil   ; sub <to>, <from>
                instruction_end
compile_mul:    eat_regs_into_dil_sil
                emit_imul_soil_soil dil, sil  ; imul <to>, <from>
                instruction_end
compile_div:    eat_regs_into_dil_sil
                ; idiv implicitly divides rdx:rax by the operand. rax -> quotient
                emit_xor_rdx_rdx              ; xor rdx, rdx
                emit_mov_rax_soil dil         ; mov rax, <to>
                emit_idiv_soil sil            ; idiv <from>
                emit_mov_soil_rax dil         ; mov <to>, rax
                instruction_end
compile_rem:    eat_regs_into_dil_sil
                ; idiv implicitly divides rdx:rax by the operand. rdx -> remainder
                emit_xor_rdx_rdx              ; xor rdx, rdx
                emit_mov_rax_soil dil         ; mov rax, <to>
                emit_idiv_soil sil            ; idiv <from>
                emit_mov_soil_rdx dil         ; mov <to>, rdx
                instruction_end
compile_and:    eat_regs_into_dil_sil
                emit_and_soil_soil dil, sil   ; and <to>, <from>
                instruction_end
compile_or:     eat_regs_into_dil_sil
                emit_or_soil_soil dil, sil    ; or <to>, <from>
                instruction_end
compile_xor:    eat_regs_into_dil_sil
                emit_xor_soil_soil dil, sil   ; xor <to>, <from>
                instruction_end
compile_not:    eat_reg_into_dil
                emit_not_soil dil             ; not <to>
                instruction_end


; Panic with stack trace
; ======================

panic_with_info:
  eprint str_vm_panicked, str_vm_panicked.len

  ; The stack
  eprint str_stack_intro, str_stack_intro.len
  ; dbg: jmp dbg
.print_all_stack_entries:
  ; .dbg: jmp .dbg
  pop rax
  cmp rax, label_after_call_to_jit
  je .done_printing_stack
  call .print_stack_entry
  jmp .print_all_stack_entries
.print_stack_entry: ; absolute machine code address is in rax
  ; If a machine code offset is on the stack, then this refers to the
  ; instruction _after_ the call instruction (the instruction that will be
  ; returned to). To get the original call instruction, we need to look at the
  ; previous instruction. We can do so by mapping the byte before the current
  ; instruction. That's safe to do because the first byte of the machine code
  ; can never be a return target (that would imply that there's another
  ; instruction before it that called something).
  mov rbx, rax
  dec rbx ; to compensate for what's described above
  sub rbx, [machine_code]
  cmp rbx, [machine_code.len]
  jg .outside_of_byte_code
  imul rbx, 4
  add rbx, [machine_code_to_byte_code]
  mov rax, 0
  mov eax, [rbx] ; byte code offset
  ; find the corresponding label by iterating all the labels from the back
  mov rcx, [labels.len]
.finding_label:
  cmp rcx, 0
  je .no_label_matches
  dec rcx
  mov rdx, rcx
  imul rdx, 24
  add rdx, [labels] ; rdx is now a pointer to the label entry (byte code offset, label pointer, len)
  mov rdi, [rdx] ; load the byte code offset of the label
  cmp rdi, rax ; is this label before our stack trace byte code offset?
  jg .finding_label ; nope
  ; it matches! print it
  push rax
  push rbx
  mov rax, [rdx + 8] ; pointer to the label string
  mov rbx, [rdx + 16] ; length of the label
  call eprint
  eprint str_newline, 1
  pop rbx
  pop rax
  ret
.outside_of_byte_code:
  eprint str_outside_of_byte_code, str_outside_of_byte_code.len
.no_label_matches:
  eprint str_no_label, str_no_label.len
  ret
.done_printing_stack:

  ; The registers
  ; printf("Registers:\n");
  ; printf("sp = %8ld %8lx\n", SP, SP);
  ; printf("st = %8ld %8lx\n", ST, ST);
  ; printf("a  = %8ld %8lx\n", REGA, REGA);
  ; printf("b  = %8ld %8lx\n", REGB, REGB);
  ; printf("c  = %8ld %8lx\n", REGC, REGC);
  ; printf("d  = %8ld %8lx\n", REGD, REGD);
  ; printf("e  = %8ld %8lx\n", REGE, REGE);
  ; printf("f  = %8ld %8lx\n", REGF, REGF);
  ; printf("\n");

  ; The memory
  ; FILE* dump = fopen("crash", "w+");
  ; fwrite(mem, 1, MEMORY_SIZE, dump);
  ; fclose(dump);
  ; printf("Memory dumped to crash.\n");

  exit 1


; Running the code
; ================

run:
  ; Make the machine code executable
  mov rax, 10                 ; mprotect
  mov rdi, [machine_code]     ; start
  mov rsi, [machine_code.len] ; length
  mov rdx, 5h                 ; new rights: PROT_READ | PROT_EXEC
  syscall
  ; Set initial register contents
  mov r8, memory_size ; sp
  mov r9, 0 ; st
  mov r10, 0 ; a
  mov r11, 0 ; b
  mov r12, 0 ; c
  mov r13, 0 ; d
  mov r14, 0 ; e
  mov r15, 0 ; f
  mov rbp, [memory]
  ; .dbg: jmp .dbg
  ; Jump into the machine code
  call qword [machine_code]
  ; When we dump the stack at a panic, we know we reached to root of the VM
  ; calls when we see this label on the call stack.
  label_after_call_to_jit:
  exit 0

main:
  mov rax, [rsp]
  mov [saved_argc], rax
  cmp rax, 2
  jl .too_few_args
  lea rax, [rsp + 8]
  mov [saved_argv], rax
  call init_heap
  call load_binary
  call compile_binary
  call run
  exit 0
.too_few_args:
  panic str_usage, str_usage.len


; Syscalls
; ========

syscalls:
.table:
  dq .exit         ;  0
  dq .print        ;  1
  dq .log          ;  2
  dq .create       ;  3
  dq .open_reading ;  4
  dq .open_writing ;  5
  dq .read         ;  6
  dq .write        ;  7
  dq .close        ;  8
  dq .argc         ;  9
  dq .arg          ; 10
  dq .read_input   ; 11
  dq .execute      ; 12
  dq 245 dup .unknown

.unknown:
  replace_two_bytes_with_hex_byte (str_unknown_syscall + str_unknown_syscall.hex_offset), al
  panic str_unknown_syscall, str_unknown_syscall.len

.exit:
  mov rax, 60   ; exit syscall
  mov dil, r10b ; status code (from the a register)
  syscall

.print:
  push_syscall_clobbers
  mov rax, 1 ; write syscall
  mov rdi, 1 ; stdout
  lea rsi, [rbp + r10] ; pointer to string (from the a register)
  mov rdx, r11 ; length of the string (from the b register)
  syscall
  pop_syscall_clobbers
  ret

.log:
  push_syscall_clobbers
  mov rax, 1 ; write syscall
  mov rdi, 2 ; stderr
  lea rsi, [rbp + r10] ; pointer to message (from the a register)
  mov rdx, r11 ; length of the message (from the b register)
  syscall
  pop_syscall_clobbers
  ret

.create:
  ; make the filename null-terminated, saving the previous end byte in bl
  mov rcx, rbp
  add rcx, r10
  add rcx, r11
  mov bl, [rcx]
  mov [rcx], byte 0
  push_syscall_clobbers
  mov rax, 2            ; open syscall
  lea rdi, [r10 + rbp]  ; filename
  mov rsi, 01102o       ; flags: RDWR|CREAT|TRUNC
  mov rdx, 0777o        ; mode: everyone has access for rwx
  syscall
  mov r10, rax
  pop_syscall_clobbers
  mov [rcx], bl ; restore end replaced by null-byte
  ret

.open_reading:
  ; make the filename null-terminated, saving the previous end byte in bl
  mov rcx, rbp
  add rcx, r10
  add rcx, r11
  mov bl, [rcx]
  mov [rcx], byte 0
  push_syscall_clobbers
  mov rax, 2            ; open syscall
  lea rdi, [r10 + rbp]  ; filename
  mov rsi, 0            ; flags: RDONLY
  mov rdx, 0            ; mode: ignored anyways because we don't create a file
  syscall
  mov r10, rax
  pop_syscall_clobbers
  mov [rcx], bl ; restore end replaced by null-byte
  ret

.open_writing:
  ; make the filename null-terminated, saving the previous end byte in bl
  mov rcx, rbp
  add rcx, r10
  add rcx, r11
  mov bl, [rcx]
  mov [rcx], byte 0
  push_syscall_clobbers
  mov rax, 2            ; open syscall
  lea rdi, [r10 + rbp]  ; filename
  mov rsi, 1101o        ; flags: RDWR | CREAT | TRUNC
  mov rdx, 0            ; mode: ignored anyways because we don't create a file
  syscall
  mov r10, rax
  pop_syscall_clobbers
  mov [rcx], bl ; restore end replaced by null-byte
  ret

.read:
  push_syscall_clobbers
  mov rax, 0            ; read
  mov rdi, r10          ; file descriptor
  lea rsi, [r11 + rbp]  ; buffer.data
  mov rdx, r12          ; buffer.len
  syscall
  mov r10, rax
  pop_syscall_clobbers
  ret

.write:
  push_syscall_clobbers
  mov rax, 1            ; write
  mov rdi, r10          ; file descriptor
  lea rsi, [r11 + rbp]  ; buffer.data
  mov rdx, r12          ; buffer.len
  syscall
  mov r10, rax
  pop_syscall_clobbers
  ret

.close:
  push_syscall_clobbers
  mov rax, 3 ; close
  mov rdi, r10 ; file descriptor
  syscall
  ; TODO: assert that this worked
  pop_syscall_clobbers
  ret

.argc:
  mov r10, [saved_argc]
  dec r10
  ret

.arg:
  ; jmp .arg
  ; TODO: check that the index is valid
  ; mov rax, [saved_argc]
  ; cmp r10, rax
  ; jge .invalid_stuff
  mov rax, r10
  cmp rax, 0
  je .load_arg
  inc rax
.load_arg:
  ; base pointer of the string given to us by the OS
  imul rax, 8
  add rax, [saved_argv]
  mov rax, [rax]
  ; index
  mov rcx, 0
  ; TODO: check that the buffer is completely in the VM memory
.copy_arg_loop:
  cmp rcx, r12 ; we filled the entire buffer
  je .done_copying_arg
  mov rsi, rax
  add rsi, rcx
  mov dl, [rsi]
  cmp dl, 0 ; we reached the end of the string (terminating null-byte)
  je .done_copying_arg
  mov rdi, r11
  add rdi, rbp
  add rdi, rcx
  mov [rdi], dl
  inc rcx
  jmp .copy_arg_loop
.done_copying_arg:
  ; jmp .done_copying_arg
  mov r10, rcx
  ret

.read_input:
  push_syscall_clobbers
  mov rax, 0            ; read
  mov rdi, 0            ; stdin
  lea rsi, [r10 + rbp]  ; buffer.data
  mov rdx, r11          ; buffer.len
  syscall
  mov r10, rax
  pop_syscall_clobbers
  ret

.execute:
  ; jmp .execute
  mov rax, r11 ; binary.len
  call malloc
  mov [binary], rax
  mov [binary.len], r11
  add r10, rbp
.copy_binary:
  cmp r11, 0
  je .clear_stack
  mov bl, [r10]
  mov [rax], bl
  inc r10
  inc rax
  dec r11
  jmp .copy_binary
.clear_stack:
  pop rax
  cmp rax, label_after_call_to_jit
  je .done_clearing_the_stack
  jmp .clear_stack
.done_clearing_the_stack:
  call compile_binary
  jmp run

segment readable writable

saved_argc: dq 0
saved_argv: dq 0

my_heap:
  .head: dq 0
  .end: dq 0

str_couldnt_open_file: db "Couldn't open file", 0xa
  .len = ($ - str_couldnt_open_file)
str_foo: db "foo", 0xa
  .len = ($ - str_foo)
str_magic_bytes_mismatch: db "magic bytes don't match", 0xa
  .len = ($ - str_magic_bytes_mismatch)
str_newline: db 0xa
str_no_label: db "<no label>", 0xa
  .len = ($ - str_no_label)
str_oom: db "Out of memory", 0xa
  .len = ($ - str_oom)
str_outside_of_byte_code: db "<outside of byte code>", 0xa
  .len = ($ - str_outside_of_byte_code)
str_stack_intro: db "Stack:", 0xa
  .len = ($ - str_stack_intro)
str_todo: db "Todo", 0xa
  .len = ($ - str_todo)
str_unknown_opcode: db "unknown opcode xx", 0xa
  .len = ($ - str_unknown_opcode)
  .hex_offset = (.len - 3)
str_unknown_syscall: db "unknown syscall xx", 0xa
  .len = ($ - str_unknown_syscall)
  .hex_offset = (.len - 3)
str_usage: db "Usage: soil <file> [<args>]", 0xa
  .len = ($ - str_usage)
str_vm_panicked: db 0xa, "Oh no! The program panicked.", 0xa, 0xa
  .len = ($ - str_vm_panicked)

; The entire content of the .soil file.
binary:
  dq 0
  .len: dq 0

; The generated x86_64 machine code generated from the byte code.
machine_code:
  dq 0
  .len: dq 0

; A mapping from bytes of the byte code to the byte-index in the machine code.
; Not all of these bytes are valid, only the ones that are at the start of a
; byte code instruction.
byte_code_to_machine_code:
  dq 0
  .len: dq 0

machine_code_to_byte_code:
  dq 0
  .len: dq 0

; Patches in the generated machine code that need to be fixed. Each patch
; contains a machine code position (4 bytes) and a byte code target (4 bytes).
patches:
  dq 0
  .len: dq 0

; The memory of the VM.
memory:
  dq 0
  .len: dq memory_size

; Labels. For each label, it saves three things:
; - the offset in the byte code
; - a pointer to the label string
; - the length of the label string
labels:
  dq 0
  .len: dq 0 ; the number of labels, not the amount of bytes
