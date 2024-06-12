// .soil files contain the byte code, initial memory, debug information, etc.
// Here, we parse the binary into program. In particular, we compile the byte
// code into x86_64 machine code.
//
// In the generated code, Soil registers are mapped to x86_64 registers:
//
// Soil | x86_64
// -----|-------
// sp   | r8
// st   | r9
// a    | r10
// b    | r11
// c    | r12
// d    | r13
// e    | r14
// f    | r15
//      | rbp: Base address of the memory.
//
// While parsing sections, we always keep the following information in registers:
// - r8: cursor through the binary
// - r9: end of the binary

const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MachineCode = @import("machine_code.zig");
const Program = @import("program.zig");
const LabelAndOffset = Program.LabelAndOffset;
const Reg = @import("reg.zig").Reg;

pub fn compile(alloc: Alloc, binary: []u8, syscalls: type) !Program {
    var program = Program{
        // Allocate one byte more than memory_size so that SyscallTable that need null-terminated
        // strings can temporarily swap out one byte after a string in memory, even if it's at the
        // end of the VM memory.
        .initial_memory = &[_]u8{},
        .machine_code = &[_]u8{},
    };

    var compiler = Compiler{
        .alloc = alloc,
        .input = binary,
        .cursor = 0,
    };
    if (try compiler.eat_byte() != 's') return error.MagicBytesMismatch;
    if (try compiler.eat_byte() != 'o') return error.MagicBytesMismatch;
    if (try compiler.eat_byte() != 'i') return error.MagicBytesMismatch;
    if (try compiler.eat_byte() != 'l') return error.MagicBytesMismatch;

    while (true) {
        const section_type = compiler.eat_byte() catch break;
        const section_len: usize = @intCast(try compiler.eat_word());
        switch (section_type) {
            0 => program.machine_code = try compiler.compile_byte_code(section_len, syscalls),
            1 => program.initial_memory = try compiler.eat_amount(section_len),
            2 => _ = try compiler.parse_labels(),
            else => compiler.cursor += section_len, // skip section
        }
    }

    return program;
}

const Compiler = struct {
    alloc: Alloc,
    input: []u8,
    cursor: usize,

    pub fn eat_amount(self: *Compiler, amount: usize) ![]u8 {
        if (self.cursor >= self.input.len - amount + 1) return error.End;
        const consumed = self.input[self.cursor..(self.cursor + amount)];
        self.cursor += amount;
        return consumed;
    }
    pub fn eat_byte(self: *Compiler) !u8 {
        return (try self.eat_amount(1))[0];
    }
    pub fn eat_word(self: *Compiler) !i64 {
        return std.mem.readInt(i64, (try Compiler.eat_amount(self, 8))[0..8], .little);
    }

    fn parse_labels(self: *Compiler) ![]LabelAndOffset {
        const count: usize = @intCast(try self.eat_word());
        var labels_to_offset = ArrayList(LabelAndOffset).init(self.alloc);
        for (0..count) |_| {
            const offset: usize = @intCast(try self.eat_word());
            const label_len: usize = @intCast(try self.eat_word());
            const label = try self.eat_amount(label_len);
            try labels_to_offset.append(.{ .offset = offset, .label = label });
        }
        return labels_to_offset.items;
    }

    fn parse_reg(self: *Compiler) !Reg {
        return Reg.parse(try self.eat_byte());
    }
    const Regs = struct { a: Reg, b: Reg };
    fn parse_regs(self: *Compiler) !Regs {
        const byte = try self.eat_byte();
        return .{ .a = try Reg.parse(byte & 0x0f), .b = try Reg.parse(byte >> 4) };
    }
    fn compile_byte_code(self: *Compiler, len: usize, syscalls: type) ![]align(std.mem.page_size) u8 {
        const byte_code_base = self.cursor;
        const end = byte_code_base + len;

        var machine_code = try MachineCode.init(self.alloc);

        // Mappings between offsets.
        var byte_to_machine_code = ArrayList(usize).init(self.alloc);
        var machine_to_byte_code = ArrayList(usize).init(self.alloc);

        while (self.cursor < end) {
            std.debug.print("Compiling instruction.\n", .{});
            const byte_code_offset = self.cursor - byte_code_base;
            const machine_code_offset = machine_code.len;

            try self.compile_instruction(&machine_code, syscalls);

            const byte_code_offset_after = self.cursor - byte_code_base;
            const machine_code_offset_after = machine_code.len;

            while (byte_to_machine_code.items.len < byte_code_offset_after)
                try byte_to_machine_code.append(machine_code_offset);
            while (machine_to_byte_code.items.len < machine_code_offset_after)
                try machine_to_byte_code.append(byte_code_offset);
        }

        for (machine_code.patches.items) |patch| {
            const target: i32 = @intCast(byte_to_machine_code.items[patch.target]);
            const base: i32 = @intCast(patch.where + 4); // relative to the end of the jump/call instruction
            const relative = target - base;
            std.mem.writeInt(i32, machine_code.buffer[patch.where..(patch.where + 4)][0..4], relative, .little);
        }

        return machine_code.buffer[0..machine_code.len];
    }
    fn compile_instruction(self: *Compiler, machine_code: *MachineCode, syscalls: type) !void {
        const opcode = try self.eat_byte();
        switch (opcode) {
            0x00 => {}, // nop
            0xe0 => { // panic
                try machine_code.emit_call_comptime(@intFromPtr(&panic_with_info)); // call panic_with_info
            },
            0xd0 => { // move
                const regs = try self.parse_regs();
                try machine_code.emit_mov_soil_soil(regs.a, regs.b); // mov <to>, <from>
            },
            0xd1 => { // movei
                const reg = try self.parse_reg();
                const value = try self.eat_word();
                try machine_code.emit_mov_soil_word(reg, value); // mov <to>, <value>
            },
            0xd2 => { // moveib
                const reg = try self.parse_reg();
                const value = try self.eat_byte();
                try machine_code.emit_xor_soil_soil(reg, reg); // xor <to>, <to>
                try machine_code.emit_mov_soilb_byte(reg, value); // mov <to>b, <value>
            },
            0xd3 => { // load
                const regs = try self.parse_regs();
                try machine_code.emit_mov_soil_mem_of_rbp_plus_soil(regs.a, regs.b); // mov <to>, [rbp + <from>]
            },
            0xd4 => { // loadb
                const regs = try self.parse_regs();
                try machine_code.emit_mov_soilb_mem_of_rbp_plus_soil(regs.a, regs.b); // mov <to>b, [rbp + <from>]
                try machine_code.emit_and_soil_0xff(regs.a); // and <to>, 0ffh
            },
            0xd5 => { // store
                const regs = try self.parse_regs();
                try machine_code.emit_mov_mem_of_rbp_plus_soil_soil(regs.a, regs.b); // mov <to>, [rbp + <from>]
            },
            0xd6 => { // storeb
                const regs = try self.parse_regs();
                try machine_code.emit_mov_mem_of_rbp_plus_soil_soilb(regs.a, regs.b); // mov <to>, [rbp + <from>]
            },
            0xd7 => { // push
                const reg = try self.parse_reg();
                try machine_code.emit_sub_r8_8(); // sub r8, 8
                try machine_code.emit_mov_mem_of_rbp_plus_soil_soil(.sp, reg); // mov [rbp + r8], <from>
            },
            0xd8 => { // pop
                const reg = try self.parse_reg();
                try machine_code.emit_mov_soil_mem_of_rbp_plus_soil(reg, .sp); // mov <to>, [rbp + r8]
                try machine_code.emit_add_r8_8(); // add r8, 8
            },
            0xf0 => { // jump
                const target: usize = @intCast(try self.eat_word());
                try machine_code.emit_jmp(target); // jmp <target>
            },
            0xf1 => { // cjump
                const target: usize = @intCast(try self.eat_word());
                try machine_code.emit_test_r9_r9(); // test r9, r9
                try machine_code.emit_jnz(target); // jnz <target>
            },
            0xf2 => { // call
                const target: usize = @intCast(try self.eat_word());
                try machine_code.emit_call(target); // call <target>
            },
            0xf3 => { // ret
                try machine_code.emit_ret(); // ret
            },
            0xf4 => { // syscall
                // Syscalls are implemented in Zig.
                const number = try self.eat_byte();
                inline for (0..256) |n| {
                    if (number == n) {
                        const decls = @typeInfo(syscalls).Struct.decls;
                        if (decls.len <= n) {
                            // TODO: add call to stub
                            break;
                        }
                        const impl = @field(syscalls, decls[n].name);
                        const signature = @typeInfo(@TypeOf(impl)).Fn;
                        std.debug.assert(!signature.is_generic);
                        std.debug.assert(!signature.is_var_args);
                        std.debug.assert(signature.calling_convention == .C);

                        try machine_code.emit_push(Reg.sp);
                        try machine_code.emit_push(Reg.st);
                        try machine_code.emit_push(Reg.a);
                        try machine_code.emit_push(Reg.b);
                        try machine_code.emit_push(Reg.c);
                        try machine_code.emit_push(Reg.d);
                        try machine_code.emit_push(Reg.e);
                        try machine_code.emit_push(Reg.f);

                        const num_args = signature.params.len;
                        if (num_args >= 1) try machine_code.emit_mov_rdi_r8();
                        if (num_args >= 2) try machine_code.emit_mov_rsi_r9();
                        if (num_args >= 3) try machine_code.emit_mov_rdx_r10();
                        if (num_args >= 4) try machine_code.emit_mov_rcx_r11();
                        if (num_args >= 5) try machine_code.emit_mov_r8_r12();

                        try machine_code.emit_call_comptime(@intFromPtr(&impl));

                        try machine_code.emit_pop(Reg.f);
                        try machine_code.emit_pop(Reg.e);
                        try machine_code.emit_pop(Reg.d);
                        try machine_code.emit_pop(Reg.c);
                        try machine_code.emit_pop(Reg.b);
                        try machine_code.emit_pop(Reg.a);
                        try machine_code.emit_pop(Reg.st);
                        try machine_code.emit_pop(Reg.sp);
                        @compileLog(signature);
                    }
                }
                // TODO: implement
                // mov r14, 0
                // eat_byte r14b
                // emit_mov_al_byte r14b         ; mov al, <syscall-number>
                // mov r14, [SyscallTable.table + 8 * r14]
                // emit_call_comptime r14        ; call <syscall>
                // instruction_end
            },
            0xc0 => { // cmp
                const regs = try self.parse_regs();
                try machine_code.emit_mov_soil_soil(.st, regs.a);
                try machine_code.emit_sub_soil_soil(.st, regs.b);
            },
            0xc1 => { // isequal
                try machine_code.emit_test_r9_r9(); // test r9, r9
                try machine_code.emit_sete_r9b(); // sete r9b
                try machine_code.emit_and_r9_0xff(); // and r9, 0fh
            },
            0xc2 => { // isless
                try machine_code.emit_shr_r9_63(); // shr r9, 63
            },
            0xc3 => { // isgreater
                try machine_code.emit_test_r9_r9(); // test r9, r9
                try machine_code.emit_setg_r9b(); // setg r9b
                try machine_code.emit_and_r9_0xff(); // and r9, 0fh
            },
            0xc4 => { // islessequal
                try machine_code.emit_test_r9_r9(); // test r9, r9
                try machine_code.emit_setle_r9b(); // setle r9b
                try machine_code.emit_and_r9_0xff(); // and r9, 0fh
            },
            0xc5 => { // isgreaterequal
                try machine_code.emit_not_r9(); // not r9
                try machine_code.emit_shr_r9_63(); // shr r9, 63
            },
            0xa0 => { // add
                const regs = try self.parse_regs();
                try machine_code.emit_add_soil_soil(regs.a, regs.b); // add <to>, <from>
            },
            0xa1 => { // sub
                const regs = try self.parse_regs();
                try machine_code.emit_sub_soil_soil(regs.a, regs.b); // sub <to>, <from>
            },
            0xa2 => { // mul
                const regs = try self.parse_regs();
                try machine_code.emit_imul_soil_soil(regs.a, regs.b); // imul <to>, <from>
            },
            0xa3 => { // div
                const regs = try self.parse_regs();
                // idiv implicitly divides rdx:rax by the operand. rax -> quotient
                try machine_code.emit_xor_rdx_rdx(); // xor rdx, rdx
                try machine_code.emit_mov_rax_soil(regs.a); // mov rax, <to>
                try machine_code.emit_idiv_soil(regs.b); // idiv <from>
                try machine_code.emit_mov_soil_rax(regs.a); // mov <to>, rax
            },
            0xa4 => { // rem
                const regs = try self.parse_regs();
                // idiv implicitly divides rdx:rax by the operand. rdx -> remainder
                try machine_code.emit_xor_rdx_rdx(); // xor rdx, rdx
                try machine_code.emit_mov_rax_soil(regs.a); // mov rax, <to>
                try machine_code.emit_idiv_soil(regs.b); // idiv <from>
                try machine_code.emit_mov_soil_rdx(regs.a); // mov <to>, rdx
            },
            0xb0 => { // and
                const regs = try self.parse_regs();
                try machine_code.emit_and_soil_soil(regs.a, regs.b); // and <to>, <from>
            },
            0xb1 => { // or
                const regs = try self.parse_regs();
                try machine_code.emit_or_soil_soil(regs.a, regs.b); // or <to>, <from>
            },
            0xb2 => { // xor
                const regs = try self.parse_regs();
                try machine_code.emit_xor_soil_soil(regs.a, regs.b); // xor <to>, <from>
            },
            0xb3 => { // not
                const reg = try self.parse_reg();
                try machine_code.emit_not_soil(reg); // and <to>, <from>
            },
            else => return error.UnknownOpcode,
        }
    }
};

// ; Panic with stack trace
// ; ======================

// panic_with_info:
//   eprint str_vm_panicked, str_vm_panicked.len

//   ; The stack
//   eprint str_stack_intro, str_stack_intro.len
//   ; dbg: jmp dbg
// .print_all_stack_entries:
//   ; .dbg: jmp .dbg
//   pop rax
//   cmp rax, label_after_call_to_jit
//   je .done_printing_stack
//   call .print_stack_entry
//   jmp .print_all_stack_entries
// .print_stack_entry: ; absolute machine code address is in rax
//   ; If a machine code offset is on the stack, then this refers to the
//   ; instruction _after_ the call instruction (the instruction that will be
//   ; returned to). To get the original call instruction, we need to look at the
//   ; previous instruction. We can do so by mapping the byte before the current
//   ; instruction. That's safe to do because the first byte of the machine code
//   ; can never be a return target (that would imply that there's another
//   ; instruction before it that called something).
//   mov rbx, rax
//   dec rbx ; to compensate for what's described above
//   sub rbx, [machine_code]
//   cmp rbx, [machine_code.len]
//   jg .outside_of_byte_code
//   imul rbx, 4
//   add rbx, [machine_code_to_byte_code]
//   mov rax, 0
//   mov eax, [rbx] ; byte code offset
//   ; find the corresponding label by iterating all the labels from the back
//   mov rcx, [labels.len]
// .finding_label:
//   cmp rcx, 0
//   je .no_label_matches
//   dec rcx
//   mov rdx, rcx
//   imul rdx, 24
//   add rdx, [labels] ; rdx is now a pointer to the label entry (byte code offset, label pointer, len)
//   mov rdi, [rdx] ; load the byte code offset of the label
//   cmp rdi, rax ; is this label before our stack trace byte code offset?
//   jg .finding_label ; nope
//   ; it matches! print it
//   push rax
//   push rbx
//   mov rax, [rdx + 8] ; pointer to the label string
//   mov rbx, [rdx + 16] ; length of the label
//   call eprint
//   eprint str_newline, 1
//   pop rbx
//   pop rax
//   ret
// .outside_of_byte_code:
//   eprint str_outside_of_byte_code, str_outside_of_byte_code.len
// .no_label_matches:
//   eprint str_no_label, str_no_label.len
//   ret
// .done_printing_stack:
//   ; The registers
//   ; printf("Registers:\n");
//   ; printf("sp = %8ld %8lx\n", SP, SP);
//   ; printf("st = %8ld %8lx\n", ST, ST);
//   ; printf("a  = %8ld %8lx\n", REGA, REGA);
//   ; printf("b  = %8ld %8lx\n", REGB, REGB);
//   ; printf("c  = %8ld %8lx\n", REGC, REGC);
//   ; printf("d  = %8ld %8lx\n", REGD, REGD);
//   ; printf("e  = %8ld %8lx\n", REGE, REGE);
//   ; printf("f  = %8ld %8lx\n", REGF, REGF);
//   ; printf("\n");

fn panic_with_info() void {}

fn panic_with_stack_trace() void {
    std.debug.print("Panicking\n");
    std.process.exit(1);
}
