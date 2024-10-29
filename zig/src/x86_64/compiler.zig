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
//      | rbx: Pointer to Vm struct.

const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MachineCode = @import("machine_code.zig");
const Vm = @import("vm.zig");
const File = @import("../file.zig");
const ByteCode = @import("../byte_code.zig");
const parse_instruction = @import("../parsing.zig").parse_instruction;
const Syscall = @import("../syscall.zig");
const options = @import("root").vm_options;

const Self = @This();

pub fn compile(alloc: Alloc, file: File, syscalls: type) !Vm {
    const compiled = try compile_byte_code(file.byte_code, alloc, syscalls);

    const memory = try alloc.alloc(u8, options.memory_size);
    @memcpy(memory[0..file.initial_memory.len], file.initial_memory);

    return .{
        .byte_code = file.byte_code,
        .machine_code = compiled.machine_code,
        .machine_code_ptr = compiled.machine_code.ptr,
        .byte_to_machine_code = compiled.byte_to_machine_code,
        .machine_to_byte_code = compiled.machine_to_byte_code,
        .memory = memory,
        .try_stack = try alloc.alloc(Vm.TryScope, 1024),
        .try_stack_len = 0,
        .labels = file.labels,
    };
}

const CompiledCode = struct {
    machine_code: []align(std.mem.page_size) u8,
    byte_to_machine_code: []usize,
    machine_to_byte_code: []usize,
};
fn compile_byte_code(input: []const u8, alloc: Alloc, syscalls: type) !CompiledCode {
    var machine_code = try MachineCode.init(alloc);

    // Mappings between offsets.
    var byte_to_machine_code = ArrayList(usize).init(alloc);
    var machine_to_byte_code = ArrayList(usize).init(alloc);

    var rest = input;
    while (rest.len > 0) {
        const byte_code_offset = input.len - rest.len;
        const machine_code_offset = machine_code.len;

        const instruction = try parse_instruction(&rest);
        try compile_to_machine_code(instruction, &machine_code, syscalls);

        const byte_code_offset_after = input.len - rest.len;
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
fn compile_to_machine_code(instruction: ByteCode.Instruction, machine_code: *MachineCode, syscalls: type) !void {
    switch (instruction) {
        .nop => {},
        .panic => {
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
        .trystart => |catch_| {
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
        .tryend => {
            try machine_code.emit_mov_rcx_mem_of_rbx_plus_byte(@offsetOf(Vm, "try_stack_len")); // mov rcx, [rbx + ...] // load try_stack_len
            try machine_code.emit_dec_rcx(); // dec rcx
            try machine_code.emit_mov_mem_of_rbx_plus_byte_rcx(@offsetOf(Vm, "try_stack_len")); // mov [rbx + ...], rcx // store try_stack_len
        },
        .move => |regs| {
            try machine_code.emit_mov_soil_soil(regs.a, regs.b); // mov <to>, <from>
        },
        .movei => |args| {
            try machine_code.emit_mov_soil_word(args.reg, args.word); // mov <to>, <value>
        },
        .moveib => |args| {
            try machine_code.emit_xor_soil_soil(args.reg, args.reg); // xor <to>, <to>
            try machine_code.emit_mov_soilb_byte(args.reg, args.byte); // mov <to>b, <value>
        },
        .load => |regs| {
            try machine_code.emit_mov_soil_mem_of_rbp_plus_soil(regs.a, regs.b); // mov <to>, [rbp + <from>]
        },
        .loadb => |regs| {
            try machine_code.emit_mov_soilb_mem_of_rbp_plus_soil(regs.a, regs.b); // mov <to>b, [rbp + <from>]
            try machine_code.emit_and_soil_0xff(regs.a); // and <to>, 0ffh
        },
        .store => |regs| {
            try machine_code.emit_mov_mem_of_rbp_plus_soil_soil(regs.a, regs.b); // mov <to>, [rbp + <from>]
        },
        .storeb => |regs| {
            try machine_code.emit_mov_mem_of_rbp_plus_soil_soilb(regs.a, regs.b); // mov <to>, [rbp + <from>]
        },
        .push => |reg| {
            try machine_code.emit_sub_r8_8(); // sub r8, 8
            try machine_code.emit_mov_mem_of_rbp_plus_soil_soil(.sp, reg); // mov [rbp + r8], <from>
        },
        .pop => |reg| {
            try machine_code.emit_mov_soil_mem_of_rbp_plus_soil(reg, .sp); // mov <to>, [rbp + r8]
            try machine_code.emit_add_r8_8(); // add r8, 8
        },
        .jump => |target| {
            try machine_code.emit_jmp(target); // jmp <target>
        },
        .cjump => |target| {
            try machine_code.emit_test_r9_r9(); // test r9, r9
            try machine_code.emit_jnz(target); // jnz <target>
        },
        .call => |target| {
            try machine_code.emit_call(target); // call <target>
        },
        .ret => {
            try machine_code.emit_ret(); // ret
        },
        .syscall => |number| {
            // Syscalls are implemented in Zig.
            @setEvalBranchQuota(2000000);
            switch (number) {
                inline else => |n| {
                    const fun = Syscall.by_number(syscalls, n);

                    // Save all the Soil register contents on the stack.
                    try machine_code.emit_push_soil(.sp);
                    try machine_code.emit_push_soil(.st);
                    try machine_code.emit_push_soil(.a);
                    try machine_code.emit_push_soil(.b);
                    try machine_code.emit_push_soil(.c);
                    try machine_code.emit_push_soil(.d);
                    try machine_code.emit_push_soil(.e);
                    try machine_code.emit_push_soil(.f);
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
                    const signature = @typeInfo(@TypeOf(fun)).Fn;
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
                    try machine_code.emit_pop_soil(.f);
                    try machine_code.emit_pop_soil(.e);
                    try machine_code.emit_pop_soil(.d);
                    try machine_code.emit_pop_soil(.c);
                    try machine_code.emit_pop_soil(.b);
                    try machine_code.emit_pop_soil(.a);
                    try machine_code.emit_pop_soil(.st);
                    try machine_code.emit_pop_soil(.sp);

                    // Move the return value into the correct registers.
                    switch (signature.return_type.?) {
                        Syscall.ZeroValues => {},
                        Syscall.OneValue => try machine_code.emit_mov_soil_rax(.a),
                        Syscall.TwoValues => {
                            try machine_code.emit_mov_soil_rax(.a);
                            try machine_code.emit_mov_soil_rdx(.b);
                        },
                        else => unreachable,
                    }
                },
            }
        },
        .cmp => |regs| {
            try machine_code.emit_mov_soil_soil(.st, regs.a);
            try machine_code.emit_sub_soil_soil(.st, regs.b);
        },
        .isequal => {
            try machine_code.emit_test_r9_r9(); // test r9, r9
            try machine_code.emit_sete_r9b(); // sete r9b
            try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
        },
        .isless => {
            try machine_code.emit_shr_r9_63(); // shr r9, 63
        },
        .isgreater => {
            try machine_code.emit_test_r9_r9(); // test r9, r9
            try machine_code.emit_setg_r9b(); // setg r9b
            try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
        },
        .islessequal => {
            try machine_code.emit_test_r9_r9(); // test r9, r9
            try machine_code.emit_setle_r9b(); // setle r9b
            try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
        },
        .isgreaterequal => {
            try machine_code.emit_not_soil(.st); // not r9
            try machine_code.emit_shr_r9_63(); // shr r9, 63
        },
        .isnotequal => {
            try machine_code.emit_test_r9_r9(); // test r9, r9
            try machine_code.emit_setne_r9b(); // setne r9
            try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
        },
        .fcmp => |regs| {
            try machine_code.emit_vmovq_xmm0_soil(regs.a); // vmovq xmm0, <a>
            try machine_code.emit_vmovq_xmm1_soil(regs.b); // vmovq xmm1, <b>
            try machine_code.emit_vsubsd_xmm0_xmm0_xmm1(); // vsubsd xmm0, xmm0, xmm1
            try machine_code.emit_vmovq_soil_xmm0(.st); // vmovq r9, xmm0
        },
        .fisequal => {
            try machine_code.emit_shl_r9_1(); // shl r9, 1
            try machine_code.emit_test_r9_r9(); // test r9, r9
            try machine_code.emit_sete_r9b(); // sete r9
            try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
        },
        .fisless => {
            try machine_code.emit_vmovq_xmm0_soil(.st); // vmovq xmm0, r9
            try machine_code.emit_vxorpd_xmm1_xmm1_xmm1(); // vxorpd xmm1, xmm1, xmm1
            try machine_code.emit_vucomisd_xmm1_xmm0(); // vucomisd xmm1, xmm0
            try machine_code.emit_seta_r9b(); // seta r9b
            try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
        },
        .fisgreater => {
            try machine_code.emit_vmovq_xmm0_soil(.st); // vmovq xmm0, r9
            try machine_code.emit_vxorpd_xmm1_xmm1_xmm1(); // vxorpd xmm1, xmm1, xmm1
            try machine_code.emit_vucomisd_xmm0_xmm1(); // vucomisd xmm0, xmm1
            try machine_code.emit_seta_r9b(); // seta r9b
            try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
        },
        .fislessequal => {
            try machine_code.emit_vmovq_xmm0_soil(.st); // vmovq xmm0, r9
            try machine_code.emit_vxorpd_xmm1_xmm1_xmm1(); // vxorpd xmm1, xmm1, xmm1
            try machine_code.emit_vucomisd_xmm1_xmm0(); // vucomisd xmm1, xmm0
            try machine_code.emit_setae_r9b(); // setae r9b
            try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
        },
        .fisgreaterequal => {
            try machine_code.emit_vmovq_xmm0_soil(.st); // vmovq xmm0, r9
            try machine_code.emit_vxorpd_xmm1_xmm1_xmm1(); // vxorpd xmm1, xmm1, xmm1
            try machine_code.emit_vucomisd_xmm0_xmm1(); // vucomisd xmm0, xmm1
            try machine_code.emit_setae_r9b(); // setae r9b
            try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
        },
        .fisnotequal => {
            try machine_code.emit_shl_r9_1(); // shl r9, 1
            try machine_code.emit_test_r9_r9(); // test r9, r9
            try machine_code.emit_setne_r9b(); // setne r9b
            try machine_code.emit_and_soil_0xff(.st); // and r9, 0fh
        },
        .inttofloat => |reg| {
            try machine_code.emit_vcvtsi2sd_xmm0_xmm0_soil(reg); // vcvtsi2sd xmm0, xmm0, <reg>
            try machine_code.emit_vmovq_soil_xmm0(reg); // vmovq <reg>, xmm0
        },
        .floattoint => |reg| {
            try machine_code.emit_vmovq_xmm0_soil(reg); // vmovq xmm0, <reg>
            try machine_code.emit_vcvttsd2si_soil_xmm0(reg); // vcvttsd2si <reg>, xmm0
        },
        .add => |regs| {
            try machine_code.emit_add_soil_soil(regs.a, regs.b); // add <to>, <from>
        },
        .sub => |regs| {
            try machine_code.emit_sub_soil_soil(regs.a, regs.b); // sub <to>, <from>
        },
        .mul => |regs| {
            try machine_code.emit_imul_soil_soil(regs.a, regs.b); // imul <to>, <from>
        },
        .div => |regs| {
            // idiv implicitly divides rdx:rax by the operand. rax -> quotient
            try machine_code.emit_mov_rax_soil(regs.a); // mov rax, <to>
            try machine_code.emit_cdq(); // cdq
            try machine_code.emit_movsxd_rdx_edx(); // movsxd rdx, rax
            try machine_code.emit_idiv_soil(regs.b); // idiv <from>
            try machine_code.emit_mov_soil_rax(regs.a); // mov <to>, rax
        },
        .rem => |regs| {
            // idiv implicitly divides rdx:rax by the operand. rdx -> remainder
            try machine_code.emit_xor_rdx_rdx(); // xor rdx, rdx
            try machine_code.emit_mov_rax_soil(regs.a); // mov rax, <to>
            try machine_code.emit_idiv_soil(regs.b); // idiv <from>
            try machine_code.emit_mov_soil_rdx(regs.a); // mov <to>, rdx
        },
        .fadd => |regs| {
            try machine_code.emit_vmovq_xmm0_soil(regs.a); // vmovq xmm0, <to>
            try machine_code.emit_vmovq_xmm1_soil(regs.b); // vmovq xmm1, <from>
            try machine_code.emit_vaddsd_xmm0_xmm0_xmm1(); // vaddsd xmm0, xmm0, xmm1
            try machine_code.emit_vmovq_soil_xmm0(regs.a); // vmovq <to>, xmm0
        },
        .fsub => |regs| {
            try machine_code.emit_vmovq_xmm0_soil(regs.a); // vmovq xmm0, <to>
            try machine_code.emit_vmovq_xmm1_soil(regs.b); // vmovq xmm1, <from>
            try machine_code.emit_vsubsd_xmm0_xmm0_xmm1(); // vsubsd xmm0, xmm0, xmm1
            try machine_code.emit_vmovq_soil_xmm0(regs.a); // vmovq <to>, xmm0
        },
        .fmul => |regs| {
            try machine_code.emit_vmovq_xmm0_soil(regs.a); // vmovq xmm0, <to>
            try machine_code.emit_vmovq_xmm1_soil(regs.b); // vmovq xmm1, <from>
            try machine_code.emit_vmulsd_xmm0_xmm0_xmm1(); // vmulsd xmm0, xmm0, xmm1
            try machine_code.emit_vmovq_soil_xmm0(regs.a); // vmovq <to>, xmm0
        },
        .fdiv => |regs| {
            try machine_code.emit_vmovq_xmm0_soil(regs.a); // vmovq xmm0, <to>
            try machine_code.emit_vmovq_xmm1_soil(regs.b); // vmovq xmm1, <from>
            try machine_code.emit_vdivsd_xmm0_xmm0_xmm1(); // vdivsd xmm0, xmm0, xmm1
            try machine_code.emit_vmovq_soil_xmm0(regs.a); // vmovq <to>, xmm0
        },
        .and_ => |regs| {
            try machine_code.emit_and_soil_soil(regs.a, regs.b); // and <to>, <from>
        },
        .or_ => |regs| {
            try machine_code.emit_or_soil_soil(regs.a, regs.b); // or <to>, <from>
        },
        .xor => |regs| {
            try machine_code.emit_xor_soil_soil(regs.a, regs.b); // xor <to>, <from>
        },
        .not => |reg| {
            try machine_code.emit_not_soil(reg); // and <to>, <from>
        },
    }
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
        const label = vm.labels.find_for_offset(byte_code_offset) orelse "<no label>";
        std.debug.print("{x:10} {s}\n", .{ byte_code_offset, label });
    }
    std.process.exit(1);
}
