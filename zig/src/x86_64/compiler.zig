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
const Vm = @import("vm.zig");
const LabelAndOffset = Vm.LabelAndOffset;
const Reg = @import("reg.zig").Reg;
const Impl = @import("../impl.zig");

pub fn compile(alloc: Alloc, binary: []u8, syscalls: type) !Vm {
    var vm = Vm{
        .byte_code = &[_]u8{},
        .machine_code = &[_]u8{},
        .machine_code_ptr = @ptrFromInt(1),
        .byte_to_machine_code = &[_]usize{},
        .machine_to_byte_code = &[_]usize{},
        .memory = try alloc.alloc(u8, Vm.memory_size),
        .labels = &[_]LabelAndOffset{},
        .try_stack = try alloc.alloc(Vm.TryScope, 1024),
        .try_stack_len = 0,
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
            0 => {
                const byte_code = compiler.input[compiler.cursor..][0..section_len];
                const compiled = try compiler.compile_byte_code(section_len, syscalls);
                vm.byte_code = byte_code;
                vm.machine_code = compiled.machine_code;
                vm.machine_code_ptr = compiled.machine_code.ptr;
                vm.byte_to_machine_code = compiled.byte_to_machine_code;
                vm.machine_to_byte_code = compiled.machine_to_byte_code;
            },
            1 => @memcpy(vm.memory[0..section_len], try compiler.eat_amount(section_len)),
            3 => vm.labels = try compiler.parse_labels(),
            else => compiler.cursor += section_len, // skip section
        }
    }

    return vm;
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

    const CompiledCode = struct {
        machine_code: []align(std.mem.page_size) u8,
        byte_to_machine_code: []usize,
        machine_to_byte_code: []usize,
    };
    fn compile_byte_code(self: *Compiler, len: usize, syscalls: type) !CompiledCode {
        const byte_code_base = self.cursor;
        const end = byte_code_base + len;

        var machine_code = try MachineCode.init(self.alloc);

        // Mappings between offsets.
        var byte_to_machine_code = ArrayList(usize).init(self.alloc);
        var machine_to_byte_code = ArrayList(usize).init(self.alloc);

        while (self.cursor < end) {
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
            switch (patch.target) {
                .absolute => |ab| {
                    var target: i32 = @intCast(byte_to_machine_code.items[ab]);
                    target += @intCast(@intFromPtr(machine_code.buffer.ptr));
                    std.mem.writeInt(i32, machine_code.buffer[patch.where..][0..4], target, .little);
                },
                .relative => |rel| {
                    const base: i32 = @intCast(patch.where + 4); // relative to the end of the jump/call instruction
                    const target: i32 = @intCast(byte_to_machine_code.items[rel]);
                    const relative = target - base;
                    std.mem.writeInt(i32, machine_code.buffer[patch.where..][0..4], relative, .little);
                },
            }
        }

        return .{
            .machine_code = machine_code.buffer[0..machine_code.len],
            .byte_to_machine_code = byte_to_machine_code.items,
            .machine_to_byte_code = machine_to_byte_code.items,
        };
    }
    fn compile_instruction(self: *Compiler, machine_code: *MachineCode, syscalls: type) !void {
        const opcode = try self.eat_byte();
        switch (opcode) {
            0x00 => {}, // nop
            0xe0 => { // panic
                try machine_code.emit_mov_rcx_mem_of_rbx_plus_byte(@offsetOf(Vm, "try_stack_len")); // mov rcx, [rbx + ...] // load try_stack_len
                try machine_code.emit_cmp_rcx_0(); // cmp rcx, 0
                try machine_code.emit_jne_by_offset(15); // jne --------------------------------------+
                try machine_code.emit_mov_rdi_rbx(); // mov rdi, rbx (VM)                             | (3 bytes)
                try machine_code.emit_mov_rsi_rsp(); // mov rsi, rsp (stack pointer)                  | (3 bytes)
                try machine_code.emit_and_rsp_0xfffffffffffffff0(); // Align the stack to 16 bytes.   | (4 bytes)
                try machine_code.emit_call_comptime(@intFromPtr(&panic_vm)); // call panic_vm  | (5 bytes)
                // jump target <----------------------------------------------------------------------+
                try machine_code.emit_dec_rcx(); // dec rcx
                try machine_code.emit_mov_mem_of_rbx_plus_byte_rcx(@offsetOf(Vm, "try_stack_len")); // mov [rbx + ...], rcx // store try_stack_len
                try machine_code.emit_mov_rax_rcx(); // mov rax, rcx
                try machine_code.emit_imul_rax_24(); // imul rax, 24
                try machine_code.emit_add_rax_mem_of_rbx_plus_byte(@offsetOf(Vm, "try_stack")); // add rax, [rbx + ...]
                try machine_code.emit_mov_rsp_mem_of_rax(); // mov rsp, [rax]
                try machine_code.emit_add_rax_8(); // add rax, 8
                try machine_code.emit_mov_r8_mem_of_rax(); // mov r8, [rax]
                try machine_code.emit_add_rax_8(); // add rax, 8
                try machine_code.emit_mov_rax_mem_of_rax(); // mov rax, [rax]
                try machine_code.emit_jmp_rax(); // jmp rax
            },
            0xe1 => { // trystart
                const catch_: usize = @intCast(try self.eat_word());
                try machine_code.emit_mov_rcx_mem_of_rbx_plus_byte(@offsetOf(Vm, "try_stack_len")); // mov rcx, [rbx + ...] // load try_stack_len
                try machine_code.emit_mov_rax_rcx(); // mov rax, rcx
                try machine_code.emit_imul_rax_24(); // imul rax, 24
                try machine_code.emit_add_rax_mem_of_rbx_plus_byte(@offsetOf(Vm, "try_stack")); // add rax, [rbx + ...] // load try_stack
                try machine_code.emit_mov_mem_of_rax_rsp(); // mov [rax], rsp
                try machine_code.emit_add_rax_8(); // add rax, 8
                try machine_code.emit_mov_mem_of_rax_r8(); // mov [rax], r8
                try machine_code.emit_add_rax_8(); // add rax, 8
                try machine_code.emit_mov_mem_of_rax_absolute_target(catch_); // mov [rax], <catch>
                try machine_code.emit_inc_rcx(); // inc rcx
                try machine_code.emit_mov_mem_of_rbx_plus_byte_rcx(@offsetOf(Vm, "try_stack_len")); // mov [rbx + ...], rcx // store try_stack_len
            },
            0xe2 => { // tryend
                try machine_code.emit_mov_rcx_mem_of_rbx_plus_byte(@offsetOf(Vm, "try_stack_len")); // mov rcx, [rbx + ...] // load try_stack_len
                try machine_code.emit_dec_rcx(); // dec rcx
                try machine_code.emit_mov_mem_of_rbx_plus_byte_rcx(@offsetOf(Vm, "try_stack_len")); // mov [rbx + ...], rcx // store try_stack_len
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
                        const name = comptime syscalls.name_by_number(n);
                        const fun_exists = name != null and @hasDecl(syscalls, name.?);
                        if (!fun_exists) {
                            std.log.err("Syscall {} doesn't exist.", .{n});
                            // TODO: add call to stub
                        } else {
                            const fun = @field(syscalls, name.?);
                            const signature = @typeInfo(@TypeOf(fun)).Fn;

                            if (signature.is_generic)
                                @compileError(name.? ++ " syscall is generic.");
                            if (signature.is_var_args)
                                @compileError(name.? ++ " syscall uses var args.");
                            if (signature.calling_convention != .C)
                                @compileError(name.? ++ " syscall doesn't use the C calling convention.");
                            inline for (signature.params, 0..) |param, i| {
                                if (param.type) |param_type| {
                                    if (i == 0) {
                                        if (param_type != *Vm)
                                            @compileError(name.? ++ " syscall's first arg is not *Vm, but " ++ @typeName(param_type) ++ ".");
                                    } else {
                                        if (param_type != i64)
                                            @compileError(name.? ++ " syscall's args must be i64 (the register contents), but an argument is a " ++ @typeName(param_type) ++ ".");
                                    }
                                }
                            }

                            // Save all the Soil register contents on the stack.
                            try machine_code.emit_push_soil(Reg.sp);
                            try machine_code.emit_push_soil(Reg.st);
                            try machine_code.emit_push_soil(Reg.a);
                            try machine_code.emit_push_soil(Reg.b);
                            try machine_code.emit_push_soil(Reg.c);
                            try machine_code.emit_push_soil(Reg.d);
                            try machine_code.emit_push_soil(Reg.e);
                            try machine_code.emit_push_soil(Reg.f);
                            try machine_code.emit_push_rbp();
                            try machine_code.emit_push_rbx();

                            // Align the stack to 16 bytes.
                            try machine_code.emit_mov_rbp_rsp();
                            try machine_code.emit_and_rsp_0xfffffffffffffff0();
                            try machine_code.emit_push_rbp();
                            try machine_code.emit_sub_rsp_8();

                            // Move args into the correct registers for the C ABI.
                            // Soil        C ABI
                            // Vm (rbx) -> arg 1 (rdi)
                            // a (r10)  -> arg 2 (rsi)
                            // b (r11)  -> arg 3 (rdx)
                            // c (r12)  -> arg 4 (rcx)
                            // d (r13)  -> arg 5 (r8)
                            // e (r14)  -> arg 6 (r9)
                            const num_args = signature.params.len;
                            if (num_args >= 1) try machine_code.emit_mov_rdi_rbx();
                            if (num_args >= 2) try machine_code.emit_mov_rsi_r10();
                            if (num_args >= 3) try machine_code.emit_mov_rdx_r11();
                            if (num_args >= 4) try machine_code.emit_mov_rcx_r12();
                            if (num_args >= 5) try machine_code.emit_mov_soil_soil(.sp, .d);
                            if (num_args >= 5) try machine_code.emit_mov_soil_soil(.st, .e);

                            // Call the syscall implementation.
                            try machine_code.emit_call_comptime(@intFromPtr(&fun));

                            // Unalign the stack.
                            try machine_code.emit_add_rsp_8();
                            try machine_code.emit_pop_rsp();

                            // Restore Soil register contents.
                            try machine_code.emit_pop_rbx();
                            try machine_code.emit_pop_rbp();
                            try machine_code.emit_pop_soil(Reg.f);
                            try machine_code.emit_pop_soil(Reg.e);
                            try machine_code.emit_pop_soil(Reg.d);
                            try machine_code.emit_pop_soil(Reg.c);
                            try machine_code.emit_pop_soil(Reg.b);
                            try machine_code.emit_pop_soil(Reg.a);
                            try machine_code.emit_pop_soil(Reg.st);
                            try machine_code.emit_pop_soil(Reg.sp);

                            // Move the return value into the correct registers.
                            if (signature.return_type) |returns| {
                                switch (returns) {
                                    void => {},
                                    i64 => try machine_code.emit_mov_soil_rax(.a),
                                    Impl.TwoValues => {
                                        try machine_code.emit_mov_soil_rax(.a);
                                        try machine_code.emit_mov_soil_rdx(.b);
                                    },
                                    else => @compileError("syscalls can only return void or i64"),
                                }
                            }
                        }
                    }
                }
            },
            0xc0 => { // cmp
                const regs = try self.parse_regs();
                try machine_code.emit_mov_soil_soil(.st, regs.a);
                try machine_code.emit_sub_soil_soil(.st, regs.b);
            },
            0xc1 => { // isequal
                try machine_code.emit_test_r9_r9(); // test r9, r9
                try machine_code.emit_sete_r9b(); // sete r9b
                try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
            },
            0xc2 => { // isless
                try machine_code.emit_shr_r9_63(); // shr r9, 63
            },
            0xc3 => { // isgreater
                try machine_code.emit_test_r9_r9(); // test r9, r9
                try machine_code.emit_setg_r9b(); // setg r9b
                try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
            },
            0xc4 => { // islessequal
                try machine_code.emit_test_r9_r9(); // test r9, r9
                try machine_code.emit_setle_r9b(); // setle r9b
                try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
            },
            0xc5 => { // isgreaterequal
                try machine_code.emit_not_soil(.st); // not r9
                try machine_code.emit_shr_r9_63(); // shr r9, 63
            },
            0xc6 => { // isnotequal
                try machine_code.emit_test_r9_r9(); // test r9, r9
                try machine_code.emit_setne_r9b(); // setne r9
                try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
            },
            0xc7 => { // fcmp
                const regs = try self.parse_regs();
                try machine_code.emit_vmovq_xmm0_soil(regs.a); // vmovq xmm0, <a>
                try machine_code.emit_vmovq_xmm1_soil(regs.b); // vmovq xmm1, <b>
                try machine_code.emit_vsubsd_xmm0_xmm0_xmm1(); // vsubsd xmm0, xmm0, xmm1
                try machine_code.emit_vmovq_soil_xmm0(.st); // vmovq r9, xmm0
            },
            0xc8 => { // fisequal
                try machine_code.emit_shl_r9_1(); // shl r9, 1
                try machine_code.emit_test_r9_r9(); // test r9, r9
                try machine_code.emit_sete_r9b(); // sete r9
                try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
            },
            0xc9 => { // fisless
                try machine_code.emit_vmovq_xmm0_soil(.st); // vmovq xmm0, r9
                try machine_code.emit_vxorpd_xmm1_xmm1_xmm1(); // vxorpd xmm1, xmm1, xmm1
                try machine_code.emit_vucomisd_xmm1_xmm0(); // vucomisd xmm1, xmm0
                try machine_code.emit_seta_r9b(); // seta r9b
                try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
            },
            0xca => { // fisgreater
                try machine_code.emit_vmovq_xmm0_soil(.st); // vmovq xmm0, r9
                try machine_code.emit_vxorpd_xmm1_xmm1_xmm1(); // vxorpd xmm1, xmm1, xmm1
                try machine_code.emit_vucomisd_xmm0_xmm1(); // vucomisd xmm0, xmm1
                try machine_code.emit_seta_r9b(); // seta r9b
                try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
            },
            0xcb => { // fislessequal
                try machine_code.emit_vmovq_xmm0_soil(.st); // vmovq xmm0, r9
                try machine_code.emit_vxorpd_xmm1_xmm1_xmm1(); // vxorpd xmm1, xmm1, xmm1
                try machine_code.emit_vucomisd_xmm1_xmm0(); // vucomisd xmm1, xmm0
                try machine_code.emit_setae_r9b(); // setae r9b
                try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
            },
            0xcc => { // fisgreaterequal
                try machine_code.emit_vmovq_xmm0_soil(.st); // vmovq xmm0, r9
                try machine_code.emit_vxorpd_xmm1_xmm1_xmm1(); // vxorpd xmm1, xmm1, xmm1
                try machine_code.emit_vucomisd_xmm0_xmm1(); // vucomisd xmm0, xmm1
                try machine_code.emit_setae_r9b(); // setae r9b
                try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
            },
            0xcd => { // fisnotequal
                try machine_code.emit_shl_r9_1(); // shl r9, 1
                try machine_code.emit_test_r9_r9(); // test r9, r9
                try machine_code.emit_setne_r9b(); // setne r9b
                try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
            },
            0xce => { // inttofloat
                const reg = try self.parse_reg();
                try machine_code.emit_vcvtsi2sd_xmm0_xmm0_soil(reg); // vcvtsi2sd xmm0, xmm0, <reg>
                try machine_code.emit_vmovq_soil_xmm0(reg); // vmovq <reg>, xmm0
            },
            0xcf => { // floattoint
                const reg = try self.parse_reg();
                try machine_code.emit_vmovq_xmm0_soil(reg); // vmovq xmm0, <reg>
                try machine_code.emit_vcvttsd2si_soil_xmm0(reg); // vcvttsd2si <reg>, xmm0
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
            0xa5 => { // fadd
                const regs = try self.parse_regs();
                try machine_code.emit_vmovq_xmm0_soil(regs.a); // vmovq xmm0, <to>
                try machine_code.emit_vmovq_xmm1_soil(regs.b); // vmovq xmm1, <from>
                try machine_code.emit_vaddsd_xmm0_xmm0_xmm1(); // vaddsd xmm0, xmm0, xmm1
                try machine_code.emit_vmovq_soil_xmm0(regs.a); // vmovq <to>, xmm0
            },
            0xa6 => { // fsub
                const regs = try self.parse_regs();
                try machine_code.emit_vmovq_xmm0_soil(regs.a); // vmovq xmm0, <to>
                try machine_code.emit_vmovq_xmm1_soil(regs.b); // vmovq xmm1, <from>
                try machine_code.emit_vsubsd_xmm0_xmm0_xmm1(); // vsubsd xmm0, xmm0, xmm1
                try machine_code.emit_vmovq_soil_xmm0(regs.a); // vmovq <to>, xmm0
            },
            0xa7 => { // fmul
                const regs = try self.parse_regs();
                try machine_code.emit_vmovq_xmm0_soil(regs.a); // vmovq xmm0, <to>
                try machine_code.emit_vmovq_xmm1_soil(regs.b); // vmovq xmm1, <from>
                try machine_code.emit_vmulsd_xmm0_xmm0_xmm1(); // vmulsd xmm0, xmm0, xmm1
                try machine_code.emit_vmovq_soil_xmm0(regs.a); // vmovq <to>, xmm0
            },
            0xa8 => { // fdiv
                const regs = try self.parse_regs();
                try machine_code.emit_vmovq_xmm0_soil(regs.a); // vmovq xmm0, <to>
                try machine_code.emit_vmovq_xmm1_soil(regs.b); // vmovq xmm1, <from>
                try machine_code.emit_vdivsd_xmm0_xmm0_xmm1(); // vdivsd xmm0, xmm0, xmm1
                try machine_code.emit_vmovq_soil_xmm0(regs.a); // vmovq <to>, xmm0
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

fn equal(comptime T: type, a: []const T, b: []const T) bool {
    if (@sizeOf(T) == 0) return true;

    @compileLog("checking lens");
    if (a.len != b.len) return false;
    if (a.len == 0 or a.ptr == b.ptr) return true;

    @compileLog("checking items");
    for (a, b) |a_elem, b_elem| {
        if (a_elem != b_elem) {
            // std.debug.print(comptime fmt: []const u8, args: anytype);
            const astr = comptime blk: {
                var buf: [20]u8 = undefined;
                break :blk try intToString(a_elem, &buf);
            };
            const bstr = comptime blk: {
                var buf: [20]u8 = undefined;
                break :blk try intToString(b_elem, &buf);
            };
            @compileLog("not equal: " ++ astr ++ " and " ++ bstr);
            return false;
        } else {
            @compileLog("equal");
        }
    }
    return true;
}
fn intToString(comptime int: u32, comptime buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{}", .{int});
}

fn panic_vm(vm: *Vm, stack_pointer: *usize) void {
    std.debug.print("\nOh no! The program panicked.\n", .{});

    var i: usize = 0;
    while (true) : (i += 1) {
        const stack_entry: *usize = @ptrFromInt(@intFromPtr(stack_pointer) + 8 * i);
        if (stack_entry.* == 0) break;
        const size_of_call_instruction = 5;
        const machine_code_absolute = stack_entry.* - size_of_call_instruction;
        if (machine_code_absolute < @intFromPtr(vm.machine_code.ptr)) {
            std.debug.print("{x:10} <Zig code>", .{machine_code_absolute});
            continue;
        }
        const machine_code_offset = machine_code_absolute - @intFromPtr(vm.machine_code.ptr);
        const byte_code_offset = vm.machine_to_byte_code[machine_code_offset];
        const label = search_for_label(vm.labels, byte_code_offset) orelse "<no label>";
        std.debug.print("{x:10} {s}\n", .{ byte_code_offset, label });
    }
    std.process.exit(1);
}

fn search_for_label(labels: []LabelAndOffset, offset: usize) ?[]const u8 {
    var i = labels.len;
    while (i > 0) {
        i -= 1;
        const label = labels[i];
        if (label.offset <= offset) return label.label;
    }
    return null;
}
