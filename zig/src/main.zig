// Soil interpreter that uses JIT compilation
// ==========================================
//
// This file contains an interpreter for Soil binaries. Upon start, it parses the
// binary and translates the byte code into x86_64 machine code instructions. It
// then jumps to those instructions. That causes the CPU hardware to directly
// execute the (translated) code written in Soil, without the overhead of an
// interpreter.

const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;

const memory_size = 1000000000;

pub fn load_binary(alloc: Alloc, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(alloc, path, 1000000000);
}

// Compiling the binary
// ====================
//
// .soil files contain the byte code, initial memory, debug information, etc.
// Here, we parse the binary and set up the VM. In particular, we initialize the
// memory and JIT-compile the byte code into x86_64 machine code.
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

const Program = struct {
    initial_memory: []u8,
    machine_code: []align(std.mem.page_size) u8,
};
const LabelAndOffset = struct { label: []u8, offset: usize };

const SyscallTable = [256]fn () void;

fn compile(alloc: Alloc, binary: []u8, syscalls: type) !Program {
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

    const Reg = enum {
        sp,
        st,
        a,
        b,
        c,
        d,
        e,
        f,

        fn parse(byte: u8) !Reg {
            return switch (byte) {
                0 => Reg.sp,
                1 => Reg.st,
                2 => Reg.a,
                3 => Reg.b,
                4 => Reg.c,
                5 => Reg.d,
                6 => Reg.e,
                7 => Reg.f,
                else => return error.UnknownRegister,
            };
        }

        fn to_byte(self: Reg) u8 {
            return @as(u8, @intFromEnum(self));
        }
    };
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

    // Turns out, the encoding of x86_64 instructions is ... interesting.
    const MachineCode = struct {
        buffer: []align(std.mem.page_size) u8,
        len: usize,
        patches: ArrayList(Patch),

        const Patch = struct {
            where: usize,
            target: usize,
        };

        fn init(alloc: Alloc) !MachineCode {
            return MachineCode{
                .buffer = try alloc.allocWithOptions(u8, 100000000, std.mem.page_size, null),
                .len = 0,
                .patches = ArrayList(Patch).init(alloc),
            };
        }

        inline fn reserve(self: *MachineCode, comptime amount: u8) !void {
            if (self.len + amount > self.buffer.len) return error.OutOfMemory;
            self.len += amount;
        }
        fn emit_byte(self: *MachineCode, value: u8) !void {
            try self.reserve(1);
            self.buffer[self.len - 1] = value;
        }
        fn emit_int(self: *MachineCode, value: i32) !void {
            try self.reserve(4);
            std.mem.writeInt(i32, self.buffer[self.len - 4 .. self.len][0..4], value, .little);
        }
        fn emit_word(self: *MachineCode, value: i64) !void {
            try self.reserve(8);
            std.mem.writeInt(i64, self.buffer[self.len - 8 .. self.len][0..8], value, .little);
        }

        fn emit_relative_patch(self: *MachineCode, target: usize) !void {
            try self.patches.append(.{ .where = self.buffer.len, .target = target });
            try self.reserve(4);
        }
        fn emit_relative_comptime(self: *MachineCode, target: usize) !void {
            // Relative targets are relative to the end of the instruction (hence, the + 4).
            const base: i32 = @intCast(@intFromPtr(&self.buffer) + self.len + 4);
            const target_i32: i32 = @intCast(target);
            const relative: i32 = target_i32 - base;
            try self.emit_int(relative);
        }

        fn emit_add_soil_soil(self: *MachineCode, a: Reg, b: Reg) !void { // add <a>, <b>
            try self.emit_byte(0x4d);
            try self.emit_byte(0x01);
            try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
        }
        fn emit_add_r8_8(self: *MachineCode) !void { // add r8, 8
            try self.emit_byte(0x49);
            try self.emit_byte(0x83);
            try self.emit_byte(0xc0);
            try self.emit_byte(0x08);
        }
        fn emit_add_rax_rbp(self: *MachineCode) !void { // add rax, rbp
            try self.emit_byte(0x48);
            try self.emit_byte(0x89);
            try self.emit_byte(0xe8);
        }
        fn emit_and_soil_0xff(self: *MachineCode, a: Reg) !void { // and <a>, 0xff
            try self.emit_byte(0x49);
            try self.emit_byte(0x81);
            try self.emit_byte(0xe0 + a.to_byte());
            try self.emit_byte(0xff);
            try self.emit_byte(0x00);
            try self.emit_byte(0x00);
            try self.emit_byte(0x00);
        }
        fn emit_and_r9_0xff(self: *MachineCode) !void { // and r9, 0xff
            try self.emit_byte(0x49);
            try self.emit_byte(0x81);
            try self.emit_byte(0xe1);
            try self.emit_byte(0xff);
            try self.emit_byte(0x00);
            try self.emit_byte(0x00);
            try self.emit_byte(0x00);
        }
        fn emit_and_rax_0xff(self: *MachineCode) !void { // and rax, 0xff
            try self.emit_byte(0x48);
            try self.emit_byte(0x25);
            try self.emit_byte(0xff);
            try self.emit_byte(0x00);
            try self.emit_byte(0x00);
            try self.emit_byte(0x00);
        }
        fn emit_and_soil_soil(self: *MachineCode, a: Reg, b: Reg) !void { // and <a>, <b>
            try self.emit_byte(0x4d);
            try self.emit_byte(0x21);
            try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
        }
        fn emit_call(self: *MachineCode, target: usize) !void { // call <target>
            try self.emit_byte(0xe8);
            try self.emit_relative_patch(target);
        }
        fn emit_call_comptime(self: *MachineCode, target: usize) !void { // call <target>
            try self.emit_byte(0xe8);
            try self.emit_relative_comptime(target);
        }
        fn emit_idiv_soil(self: *MachineCode, a: Reg) !void { // idiv <a>
            try self.emit_byte(0x49);
            try self.emit_byte(0xf7);
            try self.emit_byte(0xf8 + a.to_byte());
        }
        fn emit_imul_soil_soil(self: *MachineCode, a: Reg, b: Reg) !void { // and <a>, <b>
            try self.emit_byte(0x4d);
            try self.emit_byte(0x0f);
            try self.emit_byte(0xaf);
            try self.emit_byte(0xc0 + b.to_byte() * 8 * a.to_byte());
        }
        fn emit_jmp(self: *MachineCode, target: usize) !void { // jmp <target>
            try self.emit_byte(0xe);
            try self.emit_relative_patch(target);
        }
        fn emit_jmp_to_comptime(self: *MachineCode, target: usize) !void { // jmp <target> // target can't be r12 or rax
            try self.emit_byte(0xe9);
            try self.emit_relative_comptime(target);
        }
        fn emit_jnz(self: *MachineCode, target: usize) !void { // jnz <target> // target can't be r12 or r13
            try self.emit_byte(0x0f);
            try self.emit_byte(0x85);
            try self.emit_relative_patch(target);
        }
        fn emit_mov_al_byte(self: *MachineCode, a: Reg) !void { // move al, <a>
            try self.emit_byte(0xb0);
            try self.emit_byte(a.to_byte());
        }
        fn emit_mov_rax_soil(self: *MachineCode, a: Reg) !void { // mov rax, <a>
            try self.emit_byte(0x4c);
            try self.emit_byte(0x89);
            try self.emit_byte(0xc0 + 8 * a.to_byte());
        }
        fn emit_mov_mem_of_rbp_plus_soil_soil(self: *MachineCode, a: Reg, b: Reg) !void { // mov [rbp + <a>], <b>
            try self.emit_byte(0x4d);
            try self.emit_byte(0x89);
            if (a == .d) { // for <a> = r13, the encoding is different
                try self.emit_byte(0x44 + 8 * b.to_byte());
                try self.emit_byte(0x2d);
                try self.emit_byte(0x00);
            } else {
                try self.emit_byte(0x04 + 8 * b.to_byte());
                try self.emit_byte(0x28 + a.to_byte());
            }
        }
        fn emit_mov_mem_of_rbp_plus_soil_soilb(self: *MachineCode, a: Reg, b: Reg) !void { // mov [rbp + <a>], <b>b
            try self.emit_byte(0x45);
            try self.emit_byte(0x88);
            if (a == .d) { // for <a> = r13, the encoding is different
                try self.emit_byte(0x44 + 8 * b.to_byte());
                try self.emit_byte(0x2d);
                try self.emit_byte(0x00);
            } else {
                try self.emit_byte(0x04 + 8 * b.to_byte());
                try self.emit_byte(0x28 + a.to_byte());
            }
        }
        fn emit_mov_soil_rdx(self: *MachineCode, a: Reg) !void { // mov <a>, rdx
            try self.emit_byte(0x49);
            try self.emit_byte(0x89);
            try self.emit_byte(0xd0 + a.to_byte());
        }
        fn emit_mov_soil_rax(self: *MachineCode, a: Reg) !void { // mov <a>, rax
            try self.emit_byte(0x49);
            try self.emit_byte(0x89);
            try self.emit_byte(0xc0 + a.to_byte());
        }
        fn emit_mov_soil_mem_of_rbp_plus_soil(self: *MachineCode, a: Reg, b: Reg) !void { // mov <a>, [rbp + <b>]
            try self.emit_byte(0x4d);
            try self.emit_byte(0x8b);
            if (b == .d) { // for <b> = r13, the encoding is different
                try self.emit_byte(0x44 + 8 * a.to_byte());
                try self.emit_byte(0x2d);
                try self.emit_byte(0x00);
            } else {
                try self.emit_byte(0x04 + 8 * a.to_byte());
                try self.emit_byte(@as(u8, 0x28) + b.to_byte());
            }
        }
        fn emit_mov_soilb_mem_of_rbp_plus_soil(self: *MachineCode, a: Reg, b: Reg) !void { // mov <a>b, [rbp + <b>]
            try self.emit_byte(0x45);
            try self.emit_byte(0x8a);
            if (b == .d) { // for <b> = r13, the encoding is different
                try self.emit_byte(0x44 + 8 * a.to_byte());
                try self.emit_byte(0x2d);
                try self.emit_byte(0x00);
            } else {
                try self.emit_byte(0x04 + 8 * a.to_byte());
                try self.emit_byte(0x28 + b.to_byte());
            }
        }
        fn emit_mov_soil_soil(self: *MachineCode, a: Reg, b: Reg) !void { // mov <a>, <b>
            try self.emit_byte(0x4d);
            try self.emit_byte(0x89);
            try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
        }
        fn emit_mov_soil_word(self: *MachineCode, a: Reg, value: i64) !void { // mov <a>, <value>
            try self.emit_byte(0x49);
            try self.emit_byte(0xb8 + a.to_byte());
            try self.emit_word(value);
        }
        fn emit_mov_soilb_byte(self: *MachineCode, a: Reg, value: u8) !void { // mov <a>b, <value>
            try self.emit_byte(0x41);
            try self.emit_byte(0xb0 + a.to_byte());
            try self.emit_byte(value);
        }
        fn emit_mov_rax_mem_of_rax(self: *MachineCode) !void { // mov rax, [rax]
            try self.emit_byte(0x48);
            try self.emit_byte(0x8b);
            try self.emit_byte(0x00);
        }
        fn emit_nop(self: *MachineCode) !void { // nop
            try self.emit_byte(0x90);
        }
        fn emit_not_r9(self: *MachineCode) !void { // not r9
            try self.emit_byte(0x49);
            try self.emit_byte(0xf7);
            try self.emit_byte(0xd1);
        }
        fn emit_not_soil(self: *MachineCode, a: Reg) !void { // not a
            try self.emit_byte(0x49);
            try self.emit_byte(0xf7);
            try self.emit_byte(0xd0 + a.to_byte());
        }
        fn emit_or_soil_soil(self: *MachineCode, a: Reg, b: Reg) !void { // or <a>, <b>
            try self.emit_byte(0x4d);
            try self.emit_byte(0x09);
            try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
        }
        fn emit_push(self: *MachineCode, a: Reg) !void { // push <a>
            try self.emit_byte(0x41);
            try self.emit_byte(0x50 + a.to_byte());
        }
        fn emit_pop(self: *MachineCode, a: Reg) !void { // pop <a>
            try self.emit_byte(0x41);
            try self.emit_byte(0x58 + a.to_byte());
        }
        fn emit_ret(self: *MachineCode) !void { // ret
            try self.emit_byte(0xc3);
        }
        fn emit_shr_r9_63(self: *MachineCode) !void { // shr r9, 63
            try self.emit_byte(0x49);
            try self.emit_byte(0xc1);
            try self.emit_byte(0xe9);
            try self.emit_byte(0x3f);
        }
        fn emit_sete_r9b(self: *MachineCode) !void { // sete r9b
            try self.emit_byte(0x41);
            try self.emit_byte(0x0f);
            try self.emit_byte(0x94);
            try self.emit_byte(0xc1);
        }
        fn emit_setg_r9b(self: *MachineCode) !void { // setg r9b
            try self.emit_byte(0x41);
            try self.emit_byte(0x0f);
            try self.emit_byte(0x9f);
            try self.emit_byte(0xc1);
        }
        fn emit_setle_r9b(self: *MachineCode) !void { // setle r9b
            try self.emit_byte(0x41);
            try self.emit_byte(0x0f);
            try self.emit_byte(0x9e);
            try self.emit_byte(0xc1);
        }
        fn emit_sub_soil_soil(self: *MachineCode, a: Reg, b: Reg) !void { // sub <a>, <b>
            try self.emit_byte(0x4d);
            try self.emit_byte(0x29);
            try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
        }
        fn emit_sub_r8_8(self: *MachineCode) !void { // sub r8, 8
            try self.emit_byte(0x49);
            try self.emit_byte(0x83);
            try self.emit_byte(0xe8);
            try self.emit_byte(0x08);
        }
        fn emit_test_r9_r9(self: *MachineCode) !void { // test r9, r9
            try self.emit_byte(0x4d);
            try self.emit_byte(0x85);
            try self.emit_byte(0xc9);
        }
        fn emit_xor_rdx_rdx(self: *MachineCode) !void { // xor rdx, rdx
            try self.emit_byte(0x48);
            try self.emit_byte(0x31);
            try self.emit_byte(0xd2);
        }
        fn emit_xor_soil_soil(self: *MachineCode, a: Reg, b: Reg) !void { // xor <a>, <b>
            try self.emit_byte(0x4d);
            try self.emit_byte(0x31);
            try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
        }
    };
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

// ; Running the code
// ; ================

fn run(program: Program, alloc: Alloc) !void {
    if (program.initial_memory.len > memory_size) return error.MemoryTooSmall;
    const memory = try alloc.alloc(u8, memory_size + 1);
    @memcpy(memory[0..program.initial_memory.len], program.initial_memory);

    const PROT = std.os.linux.PROT;
    const protection = PROT.READ | PROT.EXEC;
    std.debug.assert(std.os.linux.mprotect(@ptrCast(program.machine_code), program.machine_code.len, protection) == 0);

    std.debug.print("Machine code is at {x}.\n", .{program.machine_code});

    const mem_size = memory_size;
    const mem_base = program.initial_memory;
    const machine_code = program.machine_code;
    asm volatile (
        \\ mov $0, %%r9
        \\ mov $0, %%r10
        \\ mov $0, %%r11
        \\ mov $0, %%r12
        \\ mov $0, %%r13
        \\ mov $0, %%r14
        \\ mov $0, %%r15
        \\ call *%%rax
        : [ret] "=rax" (-> void),
        : [mem_size] "r8" (mem_size),
          [mem_base] "rbp" (mem_base),
          [machine_code] "rax" (machine_code),
        : "memory", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rax", "rbx", "rcx", "rdx", "rsi", "rdi"
    );
    //   ; When we dump the stack at a panic, we know we reached to root of the VM
    //   ; calls when we see this label on the call stack.
    //   label_after_call_to_jit:
    //   exit 0
}

const Syscalls = struct {
    pub fn exit(status: usize) void {
        std.debug.print("syscall: exit\n", .{});
        _ = status;
    }
    pub fn print(msg_data: usize, msg_len: usize) void {
        std.debug.print("syscall: print\n", .{});
        _ = msg_data;
        _ = msg_len;
    }
    pub fn log(msg_data: usize, msg_len: usize) void {
        std.debug.print("syscall: log\n", .{});
        _ = msg_data;
        _ = msg_len;
    }
    pub fn create(filename_data: usize, filename_len: usize, mode: usize) usize {
        std.debug.print("syscall: create\n", .{});
        _ = filename_data;
        _ = filename_len;
        _ = mode;
    }
    pub fn open_reading(filename_data: usize, filename_len: usize, flags: usize, mode: usize) usize {
        std.debug.print("syscall: open_reading\n", .{});
        _ = filename_data;
        _ = filename_len;
        _ = flags;
        _ = mode;
    }
    pub fn open_writing(filename_data: usize, filename_len: usize, flags: usize, mode: usize) usize {
        std.debug.print("syscall: open_writing\n", .{});
        _ = filename_data;
        _ = filename_len;
        _ = flags;
        _ = mode;
    }
    pub fn read(file_descriptor: usize, buffer_data: usize, buffer_len: usize) usize {
        std.debug.print("syscall: read\n", .{});
        _ = file_descriptor;
        _ = buffer_data;
        _ = buffer_len;
    }
    pub fn write(file_descriptor: usize, buffer_data: usize, buffer_len: usize) usize {
        std.debug.print("syscall: write\n", .{});
        _ = file_descriptor;
        _ = buffer_data;
        _ = buffer_len;
    }
    pub fn close(file_descriptor: usize) usize {
        std.debug.print("syscall: close\n", .{});
        _ = file_descriptor;
    }
    pub fn argc() usize {
        std.debug.print("syscall: argc\n", .{});
    }
    pub fn arg(index: usize, buffer_data: usize, buffer_len: usize) usize {
        std.debug.print("syscall: arg\n", .{});
        _ = index;
        _ = buffer_data;
        _ = buffer_len;
    }
    pub fn read_input(buffer_data: usize, buffer_len: usize) usize {
        std.debug.print("syscall: read_input\n", .{});
        _ = buffer_data;
        _ = buffer_len;
    }
    pub fn execute(binary_data: usize, binary_len: usize) void {
        std.debug.print("syscall: execute\n", .{});
        _ = binary_data;
        _ = binary_len;
    }
    pub fn ui_dimensions() struct { usize, usize } {
        std.debug.print("syscall: ui_dimensions\n", .{});
    }
    pub fn ui_render(buffer_data: usize, buffer_width: usize, buffer_height: usize) void {
        std.debug.print("syscall: ui_render\n", .{});
        _ = buffer_data;
        _ = buffer_width;
        _ = buffer_height;
    }
};

// const syscall_table = table: {
//     const entries: [256]*void = undefined;
//     // TODO: fill entries with placeholder
//     for (@typeInfo(Syscalls).Struct.decls) |decl| {
//         @compileLog(decl.name);
//     }

//     // exit          // | status          |              |               |      |
//     // print         // | msg.data        | msg.len      |               |      |
//     // log           // | msg.data        | msg.len      |               |      |
//     // create        // | filename.data   | filename.len | mode          |      |
//     // open_reading  // | filename.data   | filename.len | flags         | mode |
//     // open_writing  // | filename.data   | filename.len | flags         | mode |
//     // read          // | file descriptor | buffer.data  | buffer.len    |      |
//     // write         // | file descriptor | buffer.data  | buffer.len    |      |
//     // close         // | file descriptor |              |               |      |
//     // argc          // |                 |              |               |      |
//     // arg           // | arg index       | buffer.data  | buffer.len    |      |
//     // read_input    // | buffer.data     | buffer.len   |               |      |
//     // execute       // | binary.data     | binary.len   |               |      |
//     // ui_dimensions // |                 |              |               |      |
//     // ui_render     // | buffer.data     | buffer.width | buffer.height |      |

//     break :table entries;
// };

pub fn main() !void {
    std.debug.print("Soil VM.\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var args = std.process.args();
    _ = args.next() orelse return error.NoProgramName;
    const binary_path = args.next() orelse return error.NoSoilBinary;
    var rest = ArrayList([]const u8).init(alloc);
    while (args.next()) |arg| {
        try rest.append(arg);
    }

    const binary = try load_binary(alloc, binary_path);
    const program = try compile(alloc, binary, Syscalls);
    try run(program, alloc);
}

// ; Throughout this file, I use the following syntax:
// ; < inputs
// ; > outputs
// ; ~ clobbered, e.g. registers that may have been overwritten

// ; The syscall instruction:
// ; < rax, rdi, rsi, rdx, ...
// ; > rax
// ; ~ rcx, r11: https://stackoverflow.com/questions/69515893/when-does-linux-x86-64-syscall-clobber-r8-r9-and-r10

// macro push_syscall_clobbers {
//   push rax
//   push rdi
//   push rsi
//   push rcx
//   push r11
// }
// macro pop_syscall_clobbers {
//   pop r11
//   pop rcx
//   pop rsi
//   pop rdi
//   pop rax
// }

// ; Prints something to stdout.
// ; < rax: pointer to string
// ; < rbx: length of string
// print:
//   push_syscall_clobbers
//   mov rsi, rax
//   mov rax, 1 ; write
//   mov rdi, 1 ; stdout
//   mov rdx, rbx
//   syscall
//   pop_syscall_clobbers
//   ret

// ; Prints something to stderr.
// ; < rax: pointer to string
// ; < rbx: length of string
// eprint:
//   push_syscall_clobbers
//   mov rsi, rax
//   mov rax, 1 ; write
//   mov rdi, 2 ; stderr
//   mov rdx, rbx
//   syscall
//   pop_syscall_clobbers
//   ret

// macro eprint msg, len { ; msg can't be rdi or rsi. len can't be rdi, rsi, rdx
//   push_syscall_clobbers
//   mov rax, 1 ; write
//   mov rdi, 2 ; stderr
//   mov rsi, msg
//   mov rdx, len
//   syscall
//   pop_syscall_clobbers
// }

// ; Panics with a message. Doesn't return.
// ; < rax: pointer to message
// ; < rbx: length of message
// panic:
//   call eprint
//   exit 1
// macro panic msg, len {
//   mov rax, msg
//   mov rbx, len
//   call panic
// }

// macro replace_byte_with_hex_digit target, with { ; clobbers rbx, rcx
//   mov cl, 48 ; ASCII 0
//   cmp with, 10
//   mov rbx, 97
//   cmovge rcx, rbx ; ASCII a
//   add cl, with
//   mov [target], cl
// }
// macro replace_two_bytes_with_hex_byte target, with { ; clobbers rbx, rcx, dl
//   mov dl, with
//   shr with, 4
//   replace_byte_with_hex_digit target, with
//   mov with, dl
//   and with, 0fh
//   mov rdx, target
//   inc rdx
//   replace_byte_with_hex_digit rdx, with
// }

// ; The generated machine code must be page-aligned. Because our heap only
// ; allocates full pages, the current end is the next page-aligned address.
// advance_heap_to_next_page:
//   mov rax, [my_heap.end]
//   mov [my_heap.head], rax
//   ret

// main:
//   mov rax, [rsp]
//   mov [saved_argc], rax
//   cmp rax, 2
//   jl .too_few_args
//   lea rax, [rsp + 8]
//   mov [saved_argv], rax
//   call init_heap
//   call load_binary
//   call compile_binary
//   call run
//   exit 0
// .too_few_args:
//   panic str_usage, str_usage.len

// ; SyscallTable
// ; ========

// SyscallTable:
// .table:
//   dq .exit         ;  0
//   dq .print        ;  1
//   dq .log          ;  2
//   dq .create       ;  3
//   dq .open_reading ;  4
//   dq .open_writing ;  5
//   dq .read         ;  6
//   dq .write        ;  7
//   dq .close        ;  8
//   dq .argc         ;  9
//   dq .arg          ; 10
//   dq .read_input   ; 11
//   dq .execute      ; 12
//   dq 245 dup .unknown

// .unknown:
//   replace_two_bytes_with_hex_byte (str_unknown_syscall + str_unknown_syscall.hex_offset), al
//   panic str_unknown_syscall, str_unknown_syscall.len

// .exit:
//   mov rax, 60   ; exit syscall
//   mov dil, r10b ; status code (from the a register)
//   syscall

// .print:
//   push_syscall_clobbers
//   mov rax, 1 ; write syscall
//   mov rdi, 1 ; stdout
//   lea rsi, [rbp + r10] ; pointer to string (from the a register)
//   mov rdx, r11 ; length of the string (from the b register)
//   syscall
//   pop_syscall_clobbers
//   ret

// .log:
//   push_syscall_clobbers
//   mov rax, 1 ; write syscall
//   mov rdi, 2 ; stderr
//   lea rsi, [rbp + r10] ; pointer to message (from the a register)
//   mov rdx, r11 ; length of the message (from the b register)
//   syscall
//   pop_syscall_clobbers
//   ret

// .create:
//   ; make the filename null-terminated, saving the previous end byte in bl
//   mov rcx, rbp
//   add rcx, r10
//   add rcx, r11
//   mov bl, [rcx]
//   mov [rcx], byte 0
//   push_syscall_clobbers
//   mov rax, 2            ; open syscall
//   lea rdi, [r10 + rbp]  ; filename
//   mov rsi, 01102o       ; flags: RDWR|CREAT|TRUNC
//   mov rdx, 0777o        ; mode: everyone has access for rwx
//   syscall
//   mov r10, rax
//   pop_syscall_clobbers
//   mov [rcx], bl ; restore end replaced by null-byte
//   ret

// .open_reading:
//   ; make the filename null-terminated, saving the previous end byte in bl
//   mov rcx, rbp
//   add rcx, r10
//   add rcx, r11
//   mov bl, [rcx]
//   mov [rcx], byte 0
//   push_syscall_clobbers
//   mov rax, 2            ; open syscall
//   lea rdi, [r10 + rbp]  ; filename
//   mov rsi, 0            ; flags: RDONLY
//   mov rdx, 0            ; mode: ignored anyways because we don't create a file
//   syscall
//   mov r10, rax
//   pop_syscall_clobbers
//   mov [rcx], bl ; restore end replaced by null-byte
//   ret

// .open_writing:
//   ; make the filename null-terminated, saving the previous end byte in bl
//   mov rcx, rbp
//   add rcx, r10
//   add rcx, r11
//   mov bl, [rcx]
//   mov [rcx], byte 0
//   push_syscall_clobbers
//   mov rax, 2            ; open syscall
//   lea rdi, [r10 + rbp]  ; filename
//   mov rsi, 1101o        ; flags: RDWR | CREAT | TRUNC
//   mov rdx, 664o         ; rw-rw-r--
//   syscall
//   mov r10, rax
//   pop_syscall_clobbers
//   mov [rcx], bl ; restore end replaced by null-byte
//   ret

// .read:
//   push_syscall_clobbers
//   mov rax, 0            ; read
//   mov rdi, r10          ; file descriptor
//   lea rsi, [r11 + rbp]  ; buffer.data
//   mov rdx, r12          ; buffer.len
//   syscall
//   mov r10, rax
//   pop_syscall_clobbers
//   ret

// .write:
//   push_syscall_clobbers
//   mov rax, 1            ; write
//   mov rdi, r10          ; file descriptor
//   lea rsi, [r11 + rbp]  ; buffer.data
//   mov rdx, r12          ; buffer.len
//   syscall
//   mov r10, rax
//   pop_syscall_clobbers
//   ret

// .close:
//   push_syscall_clobbers
//   mov rax, 3 ; close
//   mov rdi, r10 ; file descriptor
//   syscall
//   ; TODO: assert that this worked
//   pop_syscall_clobbers
//   ret

// .argc:
//   mov r10, [saved_argc]
//   dec r10
//   ret

// .arg:
//   ; jmp .arg
//   ; TODO: check that the index is valid
//   ; mov rax, [saved_argc]
//   ; cmp r10, rax
//   ; jge .invalid_stuff
//   mov rax, r10
//   cmp rax, 0
//   je .load_arg
//   inc rax
// .load_arg:
//   ; base pointer of the string given to us by the OS
//   imul rax, 8
//   add rax, [saved_argv]
//   mov rax, [rax]
//   ; index
//   mov rcx, 0
//   ; TODO: check that the buffer is completely in the VM memory
// .copy_arg_loop:
//   cmp rcx, r12 ; we filled the entire buffer
//   je .done_copying_arg
//   mov rsi, rax
//   add rsi, rcx
//   mov dl, [rsi]
//   cmp dl, 0 ; we reached the end of the string (terminating null-byte)
//   je .done_copying_arg
//   mov rdi, r11
//   add rdi, rbp
//   add rdi, rcx
//   mov [rdi], dl
//   inc rcx
//   jmp .copy_arg_loop
// .done_copying_arg:
//   ; jmp .done_copying_arg
//   mov r10, rcx
//   ret

// .read_input:
//   push_syscall_clobbers
//   mov rax, 0            ; read
//   mov rdi, 0            ; stdin
//   lea rsi, [r10 + rbp]  ; buffer.data
//   mov rdx, r11          ; buffer.len
//   syscall
//   mov r10, rax
//   pop_syscall_clobbers
//   ret

// .execute:
//   ; jmp .execute
//   mov rax, r11 ; binary.len
//   call malloc
//   mov [binary], rax
//   mov [binary.len], r11
//   add r10, rbp
// .copy_binary:
//   cmp r11, 0
//   je .clear_stack
//   mov bl, [r10]
//   mov [rax], bl
//   inc r10
//   inc rax
//   dec r11
//   jmp .copy_binary
// .clear_stack:
//   pop rax
//   cmp rax, label_after_call_to_jit
//   je .done_clearing_the_stack
//   jmp .clear_stack
// .done_clearing_the_stack:
//   call compile_binary
//   jmp run

// segment readable writable

// saved_argc: dq 0
// saved_argv: dq 0

// my_heap:
//   .head: dq 0
//   .end: dq 0

// str_couldnt_open_file: db "Couldn't open file", 0xa
//   .len = ($ - str_couldnt_open_file)
// str_foo: db "foo", 0xa
//   .len = ($ - str_foo)
// str_magic_bytes_mismatch: db "magic bytes don't match", 0xa
//   .len = ($ - str_magic_bytes_mismatch)
// str_newline: db 0xa
// str_no_label: db "<no label>", 0xa
//   .len = ($ - str_no_label)
// str_oom: db "Out of memory", 0xa
//   .len = ($ - str_oom)
// str_outside_of_byte_code: db "<outside of byte code>", 0xa
//   .len = ($ - str_outside_of_byte_code)
// str_stack_intro: db "Stack:", 0xa
//   .len = ($ - str_stack_intro)
// str_todo: db "Todo", 0xa
//   .len = ($ - str_todo)
// str_unknown_opcode: db "unknown opcode xx", 0xa
//   .len = ($ - str_unknown_opcode)
//   .hex_offset = (.len - 3)
// str_unknown_syscall: db "unknown syscall xx", 0xa
//   .len = ($ - str_unknown_syscall)
//   .hex_offset = (.len - 3)
// str_usage: db "Usage: soil <file> [<args>]", 0xa
//   .len = ($ - str_usage)
// str_vm_panicked: db 0xa, "Oh no! The program panicked.", 0xa, 0xa
//   .len = ($ - str_vm_panicked)

// ; The entire content of the .soil file.
// binary:
//   dq 0
//   .len: dq 0

// ; The generated x86_64 machine code generated from the byte code.
// machine_code:
//   dq 0
//   .len: dq 0

// ; A mapping from bytes of the byte code to the byte-index in the machine code.
// ; Not all of these bytes are valid, only the ones that are at the start of a
// ; byte code instruction.
// byte_code_to_machine_code:
//   dq 0
//   .len: dq 0

// machine_code_to_byte_code:
//   dq 0
//   .len: dq 0

// ; Patches in the generated machine code that need to be fixed. Each patch
// ; contains a machine code position (4 bytes) and a byte code target (4 bytes).
// patches:
//   dq 0
//   .len: dq 0

// ; The memory of the VM.
// memory:
//   dq 0
//   .len: dq memory_size

// ; Labels. For each label, it saves three things:
// ; - the offset in the byte code
// ; - a pointer to the label string
// ; - the length of the label string
// labels:
//   dq 0
//   .len: dq 0 ; the number of labels, not the amount of bytes
