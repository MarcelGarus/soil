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

memory_size = 1000000

jmp main

; Throughout this file, I use the following syntax:
; < inputs
; > outputs
; ~ clobbered, e.g. registers that may have been overwritten

; The syscall instruction:
; < rax, rdi, rsi, rdx, ...
; > rax
; ~ rcx, r11: https://stackoverflow.com/questions/69515893/when-does-linux-x86-64-syscall-clobber-r8-r9-and-r10

; Prints something.
; < rax: pointer to string
; < rbx: length of string
; ~ rax
print:
  push rdi
  push rcx
  push r11
  mov rsi, rax
  mov rax, 1 ; write
  mov rdi, 1 ; stdout
  mov rdx, rbx
  syscall
  pop r11
  pop rcx
  pop rdi
  ret

; Panics with a message. Doesn't return.
; < rsi: pointer to message
; < rdx: length of message
panic:
  call print
  mov rax, 60
  mov rdi, 1
  syscall
macro panic msg {
  mov rsi, msg
  mov rdx, `msg.len
  call panic
}
macro todo {
  panic str_todo
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
  panic str_oom

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
  mov rax, [my_heap.head]
  mov [binary], rax
.load_more:
  mov rax, 128
  call malloc
  mov rsi, rax ; buffer
  mov rax, 0   ; read
  mov rdi, 0   ; stdin
  mov rdx, 128 ; size
  syscall
  cmp rax, 128
  jl .done_loading
  jmp .load_more
.done_loading:
  add rax, rsi ; address of end
  sub rax, [binary] ; length of binary
  mov [binary.len], rax
  ret


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
  mov rax, memory_size
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
  panic str_magic_bytes_mismatch

.parse_section:
  cmp r8, r9
  jge .done_with_parsing_sections
  eat_byte r10b ; type
  eat_word r11 ; length
  ; type: machine code
  cmp r10b, 0
  je .parse_byte_code
  ; type: initial memory
  cmp r10b, 1
  je .parse_initial_memory
  ; type: unknown
  add r8, r11 ; skip section
  jmp .parse_section

.done_with_parsing_sections:
  ret

; Copies the initial memory into the actual memory section.
.parse_initial_memory:
  mov r10, r8 ; end of the initial memory
  add r10, r11
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
  ; - The instruction mapping maps byte offsets of the byte code into byte
  ;   offsets in the machine code. It's sized 4*len(byte code) and uses 4 bytes
  ;   per each byte. Not every byte in that array is meaningful, only the ones
  ;   where a byte code instruction starts.
  ; - Patches for jumps store a position in the machine code (4 bytes) and a
  ;   target in the byte code (4 bytes). Because a jump instruction in the byte
  ;   code takes an 8 byte target argument, allocating len(byte code) for
  ;   patches is enough.
  lea rax, [r11 * 4 + 4] ; for now, r11 is still the length of the byte code
  call malloc
  mov [instruction_mapping], rax
  mov rax, r11
  call malloc
  mov [patches], rax
  add r11, r10 ; from now on, r11 points to the end of the byte code section
  ; To be able to change the memory protection of the machine code, it needs to
  ; be aligned to page boundaries.
  call advance_heap_to_next_page
  mov [machine_code], rax

.parse_instruction:
  ; Add a mapping from byte code to x86_64 machine code instruction.
  ; instruction_mapping[byte code cursor - byte_code start] = machine code cursor
  mov r12, [instruction_mapping]
  add r12, r8
  sub r12, r10
  mov r13, [my_heap.head]
  sub r13, [machine_code]
  mov [r12], r13d

  cmp r8, r11
  jge .done_parsing_instructions
  mov r12, 0
  eat_byte r12b
  mov r13, [.jump_table + r12 * 8]
  jmp r13

.done_parsing_instructions:
  mov r10, [my_heap.head]
  sub r10, [machine_code]
  mov [machine_code.len], r10
  call advance_heap_to_next_page
  ; Fix patches
  mov r10, [patches]       ; cursor through patches
  mov r11, [patches.len]
  lea r11, [8 * r11 + r10] ; end of the patches
.fix_patch:
  cmp r10, r11
  je .done_fixing_patches
  mov r12, 0
  mov r13, 0
  mov r12d, [r10]     ; the position in the machine code
  mov r13d, [r10 + 4] ; the target in the byte code
  mov r14, 0
  mov r14d, [instruction_mapping + 4 * r13] ; byte index in the machine code
  sub r14, r12 ; relative length in bytes to jump in the machine code
  add r12, [machine_code]
  mov [r12], r14d
  add r10, 8
  jmp .fix_patch
.done_fixing_patches:
  ret

.jump_table:
  ; This macro generates (to - from + 1) pointers to .invalid. Both bounds are
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

  macro emit_add_soil_soil a, b { ; add a, b -> 4d 01 (c0 + a + 8 * b)
    emit_bytes 4dh, 01h
    shl b, 3
    add b, a
    add b, 0c0h
    emit_byte b
    sub b, 0c0h
    sub b, a
    shr b, 3
  }
  macro emit_add_rax_rbp { emit_bytes 48h, 01h, 0e8h } ; mov rax, rbp
  macro emit_and_rax_ff { emit_bytes 48h, 25h, 0ffh, 00h, 00h, 00h } ; and rax, 0ffh
  macro emit_jmp target { ; target can't be r12 or r13
    emit_byte 0e9h
    ; Save a patch
    push r12
    push r13
    mov r12, [patches]
    mov r13, [patches.len]
    lea r12, [r12 + r13 * 8]
    inc r13
    mov [patches.len], r13
    mov r13, [my_heap.head]
    mov [r12], r13d
    mov r13, target
    mov [r12 + 4], r13d
    pop r13
    pop r12
    emit_bytes 00h, 00h, 00h, 00h
  }
  macro emit_mov_rax_soil a { ; mov rax, <a> -> 4c 89 (c0 + 8 * a)
    emit_bytes 4ch, 89h
    shl a, 3
    add a, 0c0h
    emit_byte a
    sub a, 0c0h
    shr a, 3
  }
  macro emit_mov_soil_rax a { ; mov <a>, rax -> 49 89 (c0 + a)
    emit_bytes 49h, 89h
    add a, 0c0h
    emit_byte a
    sub a, 0c0h
  }
  macro emit_mov_soil_word a, value { ; mov <a>, <value> -> 49 (b8 + a) (value)
    ; Example: mov r8, aabbccddeeffh -> 49 b8 ff ee dd cc bb aa 00 00
    emit_byte 49h
    add a, 0b8h
    emit_byte a
    emit_word value
    sub a, 0b8h
  }
  macro emit_mov_soil_byte a, value { ; mov <a>b, <value> -> 41 (b0 + a) (value)
    emit_byte 41h
    add a, 0b0h
    emit_byte a
    emit_byte value
    sub a, 0b0h
  }
  macro emit_mov_rax_mem_of_rax { emit_bytes 48h, 8bh, 00h } ; mov rax, [rax]
  macro emit_nop { emit_byte 90h }  ; nop
  macro emit_ret { emit_byte 0c3h } ; ret
  macro emit_xor_soil_self a { ; xor <a>, <a> -> 4d 31 (c0 + 9 * a) ; a can't be r12 or r13
    push r12
    push r13
    emit_bytes 4dh, 31h
    mov r12, 0
    mov r12b, a
    mov r13, r12 ; r13 = a
    shl r13, 3   ; r13 = 8 * a
    add r13, r12 ; r13 = 9 * a
    add r13, 0c0h
    emit_byte r13b
    pop r13
    pop r12
  }

.invalid:
  panic str_unknown_opcode
.nop:
  emit_nop ; nop
  jmp .parse_instruction
.panic:
  ; TODO: print stack trace and VM state
  mov rax, 60
  mov rdi, 1
  syscall
.move:
  eat_regs_into_dil_sil
  emit_mov_rax_soil sil ; mov rax, <from>
  emit_mov_soil_rax dil ; mov <to>, rax
  jmp .parse_instruction
.movei:
  eat_reg_into_dil
  eat_word r12
  emit_mov_soil_word dil, r12 ; mov <to>, <word>
  jmp .parse_instruction
.moveib:
  eat_reg_into_dil
  eat_byte r12b
  emit_xor_soil_self dil       ; xor <to>, <to>
  emit_mov_soil_byte dil, r12b ; mov <to>b, <byte>
  jmp .parse_instruction
.load:
  eat_regs_into_dil_sil
  emit_mov_rax_soil sil   ; mov rax, <from>
  emit_add_rax_rbp        ; add rax, rbp    ; add the memory base pointer
  emit_mov_rax_mem_of_rax ; mov rax, [rax]
  emit_mov_soil_rax dil   ; mov <to>, rax
  jmp .parse_instruction
.loadb:
  eat_regs_into_dil_sil
  emit_mov_rax_soil sil   ; mov rax, <from>
  emit_add_rax_rbp        ; add rax, rbp    ; add the memory base pointer
  emit_mov_rax_mem_of_rax ; mov rax, [rax]
  emit_and_rax_ff         ; and rax, 0ffh
  emit_mov_soil_rax dil   ; mov <to>, rax
  jmp .parse_instruction
.store:
  todo
;   eat_regs_into_dil_sil
;   load_reg rax, rdi
;   load_reg rbx, sil
;   add rax, rbp
;   mov [rax], rbx
;   advance_ip_by 2
;   end_of_instruction
.storeb:
  todo
;   eat_regs_into_dil_sil
;   load_reg rax, rdi
;   load_reg rbx, rsi
;   add rax, rbp
;   mov [rax], bl
;   advance_ip_by 2
;   end_of_instruction
.push:
  todo
;   eat_reg_into_dil
;   load_reg rax, rdi
;   sub r9, 8
;   mov rbx, r9
;   add rbx, rbp
;   mov [rbx], rax
;   advance_ip_by 2
;   end_of_instruction
.pop:
  todo
;   eat_reg_into_dil
;   mov rax, r9
;   add rax, rbp
;   store_reg rdi, [rax]
;   add r9, 8
;   advance_ip_by 2
;   end_of_instruction
.jump:
  eat_word r14
  emit_jmp r14 ; jmp <target>
  jmp .parse_instruction
.cjump:
  todo
;   advance_ip_by 10
;   cmp r10, 0
;   cmovne r8, [rsp + 1]
;   end_of_instruction
.call:
  todo
;   sub r9, 8
;   mov rax, r9
;   add rax, rbp
;   mov [rax], r8
;   mov r8, [rsp + 1]
;   end_of_instruction
.ret:
  emit_ret ; ret
  jmp .parse_instruction
.syscall:
  todo
;   mov rax, 0
;   mov al, [rsp + 1]
;   mov rax, [syscalls.table + rax * 8]
;   call rax
;   advance_ip_by 2
;   end_of_instruction
.cmp:
  todo
;   eat_regs_into_dil_sil
;   load_reg rax, rdi
;   load_reg rbx, rsi
;   mov r10, rax
;   sub r10, rbx
;   advance_ip_by 2
;   end_of_instruction
.isequal:
  todo
;   cmp r10, 0
;   mov r10, 0
;   mov rax, 1
;   cmove r10, rax
;   advance_ip_by 1
;   end_of_instruction
.isless:
  todo
;   cmp r10, 0
;   mov r10, 0
;   mov rax, 1
;   cmovl r10, rax
;   advance_ip_by 1
;   end_of_instruction
.isgreater:
  todo
;   cmp r10, 0
;   mov r10, 0
;   mov rax, 1
;   cmovg r10, rax
;   advance_ip_by 1
;   end_of_instruction
.islessequal:
  todo
;   cmp r10, 0
;   mov r10, 0
;   mov rax, 1
;   cmovle r10, rax
;   advance_ip_by 1
;   end_of_instruction
.isgreaterequal:
  todo
;   cmp r10, 0
;   mov r10, 0
;   mov rax, 1
;   cmovge r10, rax
;   advance_ip_by 1
;   end_of_instruction
.add:
  eat_regs_into_dil_sil
  emit_add_soil_soil dil, sil
  jmp .parse_instruction
.sub:
  todo
  ; eat_regs_into_dil_sil
  ; load_reg rax, rdi
  ; load_reg rbx, rsi
  ; sub rax, rbx
  ; store_reg rdi, rax
  ; advance_ip_by 2
  ; end_of_instruction
.mul:
  todo
  ; eat_regs_into_dil_sil
  ; load_reg rax, rdi
  ; load_reg rbx, rsi
  ; mul rbx ; rdx:rax = rax * rbx
  ; store_reg rdi, rax
  ; advance_ip_by 2
  ; end_of_instruction
.div:
  todo
  ; eat_regs_into_dil_sil
  ; load_reg rax, rdi
  ; load_reg rbx, rsi
  ; mov rdx, 0
  ; div rbx ; rdx:rax = rdx:rax / rbx
  ; store_reg rdi, rax
  ; advance_ip_by 2
  ; end_of_instruction
.and:
  todo
  ; eat_regs_into_dil_sil
  ; load_reg rax, rdi
  ; load_reg rbx, rsi
  ; and rax, rbx
  ; store_reg rdi, rax
  ; advance_ip_by 2
  ; end_of_instruction
.or:
  todo
  ; eat_regs_into_dil_sil
  ; load_reg rax, rdi
  ; load_reg rbx, rsi
  ; or rax, rbx
  ; store_reg rdi, rax
  ; advance_ip_by 2
  ; end_of_instruction
.xor:
  todo
  ; eat_regs_into_dil_sil
  ; load_reg rax, rdi
  ; load_reg rbx, rsi
  ; xor rax, rbx
  ; store_reg rdi, rax
  ; advance_ip_by 2
  ; end_of_instruction
.negate:
  todo
  ; eat_reg_into_dil
  ; load_reg rax, rdi
  ; neg rax
  ; store_reg rdi, rax
  ; advance_ip_by 2
  ; end_of_instruction


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
  ; Jump into the machine code
  call qword [machine_code]
  nop
  nop
  nop

main:
  call init_heap
  call load_binary
  call compile_binary
  call run
  mov rax, 60
  mov rdi, 0
  syscall

; Syscalls
; ========

syscalls:
  .table:
    dq .exit         ; 0
    dq .print        ; 1
    dq .log          ; 2
    dq .create       ; 3
    dq .open_reading ; 4
    dq .open_writing ; 5
    dq .read         ; 6
    dq .write        ; 7
    dq .close        ; 8
    dq 248 dup .unknown

  .unknown:
    panic str_unknown_syscall

  .exit:
    mov rax, 60 ; exit syscall
    mov rdi, [rbp + r11] ; status code (from the a register)
    syscall

  .print:
    mov rax, 1 ; write syscall
    mov rdi, 1 ; stdout
    lea rsi, [rbp + r11] ; pointer to string (from the a register)
    mov rdx, r12 ; length of the string (from the b register)
    syscall
    ret

  .log:
    mov rax, 1 ; write syscall
    mov rdi, 2 ; stderr
    lea rsi, [rbp + r11] ; pointer to message (from the a register)
    mov rdx, r12 ; length of the message (from the b register)
    syscall
    ret

  .create:
    todo

  .open_reading:
    todo

  .open_writing:
    todo

  .read:
    todo

  .write:
    todo

  .close:
    todo

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
str_unknown_syscall: db "Unknown syscall", 0xa
  .len = ($ - str_unknown_syscall)

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
instruction_mapping:
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
