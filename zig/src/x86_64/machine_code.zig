// A builder for x86_64 machine code. Turns out, the instruction encoding is ... interesting.

const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reg = @import("../byte_code.zig").Reg;
const Self = @This();

buffer: []align(std.mem.page_size) u8,
len: usize,
patches: ArrayList(Patch),

const Patch = struct {
    where: usize,
    target: PatchTarget,
};
const PatchTarget = union(enum) {
    relative: usize,
    absolute: usize,
};

pub fn init(alloc: Alloc) !Self {
    var machine_code = Self{
        .buffer = try allocate_memory_at_a_small_address(10000 * std.mem.page_size),
        .len = 0,
        .patches = ArrayList(Patch).init(alloc),
    };
    if (false) {
        try machine_code.emit_infinite_loop();
    }
    return machine_code;
}

// Well, here the trouble begins. Any old allocator won't work for us because the jmp instruction
// can only jump 2^32 bytes forward or backwards (without resorting to such hacks as memory-indirect
// jumps). Thus, we perform our own mmap to allocate memory at a small address.
fn allocate_memory_at_a_small_address(len: usize) ![]align(std.mem.page_size) u8 {
    var page: usize = @intFromPtr(&allocate_memory_at_a_small_address) / std.mem.page_size;
    while (true) {
        page += 1;
        const address = std.os.linux.mmap(
            @ptrFromInt(page * std.mem.page_size), // hint: small address, please!
            len,
            std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        if (address == 0) return error.OutOfMemory;
        const ptr = @as([*]align(std.mem.page_size) u8, @ptrFromInt(address));

        // std.debug.print("page {}: mmap result is {x}.\n", .{ page, address });
        if (address < std.math.pow(usize, 2, 32)) {
            return ptr[0..len];
        }
        _ = std.os.linux.munmap(ptr, len);
    }
}

inline fn reserve(self: *Self, comptime amount: u8) !void {
    if (self.len + amount > self.buffer.len) return error.OutOfMemory;
    self.len += amount;
}
fn emit_byte(self: *Self, value: u8) !void {
    try self.reserve(1);
    self.buffer[self.len - 1] = value;
}
fn emit_int(self: *Self, value: i32) !void {
    try self.reserve(4);
    std.mem.writeInt(i32, self.buffer[self.len - 4 .. self.len][0..4], value, .little);
}
fn emit_word(self: *Self, value: i64) !void {
    try self.reserve(8);
    std.mem.writeInt(i64, self.buffer[self.len - 8 .. self.len][0..8], value, .little);
}

fn emit_absolute_patch(self: *Self, target: usize) !void {
    try self.patches.append(.{ .where = self.len, .target = .{ .absolute = target } });
    try self.reserve(4);
}
fn emit_relative_patch(self: *Self, target: usize) !void {
    try self.patches.append(.{ .where = self.len, .target = .{ .relative = target } });
    try self.reserve(4);
}
fn emit_relative_comptime(self: *Self, target: usize) !void {
    // Relative targets are relative to the end of the instruction (hence, the + 4).
    const base: i32 = @intCast(@intFromPtr(self.buffer.ptr) + self.len + 4);
    const target_i32: i32 = @intCast(target);
    const relative: i32 = target_i32 - base;
    try self.emit_int(relative);
}

pub fn emit_infinite_loop(self: *Self) !void { // jmp <this jmp>
    try self.emit_byte(0xeb);
    try self.emit_byte(0xfe);
}
pub fn emit_add_soil_soil(self: *Self, a: Reg, b: Reg) !void { // add <a>, <b>
    try self.emit_byte(0x4d);
    try self.emit_byte(0x01);
    try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
}
pub fn emit_add_r8_8(self: *Self) !void { // add r8, 8
    try self.emit_byte(0x49);
    try self.emit_byte(0x83);
    try self.emit_byte(0xc0);
    try self.emit_byte(0x08);
}
pub fn emit_add_rax_8(self: *Self) !void { // add rax, 8
    try self.emit_byte(0x48);
    try self.emit_byte(0x83);
    try self.emit_byte(0xc0);
    try self.emit_byte(0x08);
}
pub fn emit_add_rax_mem_of_rbx_plus_byte(self: *Self, byte: u8) !void { // add rax, [rbx + <byte>]
    try self.emit_byte(0x48);
    try self.emit_byte(0x03);
    try self.emit_byte(0x43);
    try self.emit_byte(byte);
}
pub fn emit_add_rax_rbp(self: *Self) !void { // add rax, rbp
    try self.emit_byte(0x48);
    try self.emit_byte(0x89);
    try self.emit_byte(0xe8);
}
pub fn emit_add_rcx_rax(self: *Self) !void { // add rcx, rax
    try self.emit_byte(0x48);
    try self.emit_byte(0x01);
    try self.emit_byte(0xc1);
}
pub fn emit_add_rsp_8(self: *Self) !void { // add rsp, 8
    try self.emit_byte(0x48);
    try self.emit_byte(0x83);
    try self.emit_byte(0xc4);
    try self.emit_byte(0x08);
}
pub fn emit_and_soil_0xff(self: *Self, a: Reg) !void { // and <a>, 0xff
    try self.emit_byte(0x49);
    try self.emit_byte(0x81);
    try self.emit_byte(0xe0 + a.to_byte());
    try self.emit_byte(0xff);
    try self.emit_byte(0x00);
    try self.emit_byte(0x00);
    try self.emit_byte(0x00);
}
pub fn emit_and_rax_0xff(self: *Self) !void { // and rax, 0xff
    try self.emit_byte(0x48);
    try self.emit_byte(0x25);
    try self.emit_byte(0xff);
    try self.emit_byte(0x00);
    try self.emit_byte(0x00);
    try self.emit_byte(0x00);
}
pub fn emit_and_rsp_0xfffffffffffffff0(self: *Self) !void { // and rsp, 0xfffffffffffffff0
    try self.emit_byte(0x48);
    try self.emit_byte(0x83);
    try self.emit_byte(0xe4);
    try self.emit_byte(0xf0);
}
pub fn emit_and_soil_soil(self: *Self, a: Reg, b: Reg) !void { // and <a>, <b>
    try self.emit_byte(0x4d);
    try self.emit_byte(0x21);
    try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
}
pub fn emit_call(self: *Self, target: usize) !void { // call <target>
    try self.emit_byte(0xe8);
    try self.emit_relative_patch(target);
}
pub fn emit_call_comptime(self: *Self, target: usize) !void { // call <target>
    try self.emit_byte(0xe8);
    try self.emit_relative_comptime(target);
}
pub fn emit_cqo(self: *Self) !void { // cqo
    try self.emit_byte(0x48);
    try self.emit_byte(0x99);
}
pub fn emit_cmp_rcx_0(self: *Self) !void { // cmp rcx, 0
    try self.emit_byte(0x48);
    try self.emit_byte(0x83);
    try self.emit_byte(0xf9);
    try self.emit_byte(0x00);
}
pub fn emit_dec_rcx(self: *Self) !void { // dec rcx
    try self.emit_byte(0x48);
    try self.emit_byte(0xff);
    try self.emit_byte(0xc9);
}
pub fn emit_idiv_soil(self: *Self, a: Reg) !void { // idiv <a>
    try self.emit_byte(0x49);
    try self.emit_byte(0xf7);
    try self.emit_byte(0xf8 + a.to_byte());
}
pub fn emit_imul_rax_24(self: *Self) !void { // imul rax, 24
    try self.emit_byte(0x48);
    try self.emit_byte(0x6b);
    try self.emit_byte(0xc0);
    try self.emit_byte(0x18);
}
pub fn emit_imul_soil_soil(self: *Self, a: Reg, b: Reg) !void { // imul <a>, <b>
    try self.emit_byte(0x4d);
    try self.emit_byte(0x0f);
    try self.emit_byte(0xaf);
    try self.emit_byte(0xc0 + b.to_byte() + 8 * a.to_byte());
}
pub fn emit_inc_rcx(self: *Self) !void { // inc rcx
    try self.emit_byte(0x48);
    try self.emit_byte(0xff);
    try self.emit_byte(0xc1);
}
pub fn emit_jmp(self: *Self, target: usize) !void { // jmp <target>
    try self.emit_byte(0xe9);
    try self.emit_relative_patch(target);
}
pub fn emit_jmp_rax(self: *Self) !void { // jmp rax
    try self.emit_byte(0xff);
    try self.emit_byte(0xe0);
}
pub fn emit_jmp_to_comptime(self: *Self, target: usize) !void { // jmp <target> // target can't be r12 or rax
    try self.emit_byte(0xe9);
    try self.emit_relative_comptime(target);
}
pub fn emit_jne_by_offset(self: *Self, offset: u8) !void { // jne <offset>
    try self.emit_byte(0x75);
    try self.emit_byte(offset);
}
pub fn emit_jnz(self: *Self, target: usize) !void { // jnz <target> // target can't be r12 or r13
    try self.emit_byte(0x0f);
    try self.emit_byte(0x85);
    try self.emit_relative_patch(target);
}
pub fn emit_mov_al_soilb(self: *Self, a: Reg) !void { // mov al, <a>b
    try self.emit_byte(0xb0);
    try self.emit_byte(a.to_byte());
}
pub fn emit_mov_mem_of_rbp_plus_soil_soil(self: *Self, a: Reg, b: Reg) !void { // mov [rbp + <a>], <b>
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
pub fn emit_mov_mem_of_rbp_plus_soil_soilb(self: *Self, a: Reg, b: Reg) !void { // mov [rbp + <a>], <b>b
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
pub fn emit_mov_r8_mem_of_rax(self: *Self) !void { // mov r8, [rax]
    try self.emit_byte(0x4c);
    try self.emit_byte(0x8b);
    try self.emit_byte(0x00);
}
pub fn emit_mov_rax_mem_of_rbx_plus_byte(self: *Self, byte: u8) !void { // mov rax, [rbx + <byte>]
    try self.emit_byte(0x48);
    try self.emit_byte(0x8b);
    try self.emit_byte(0x43);
    try self.emit_byte(byte);
}
pub fn emit_mov_mem_of_rax_r8(self: *Self) !void { // mov [rax], r8
    try self.emit_byte(0x4c);
    try self.emit_byte(0x89);
    try self.emit_byte(0x00);
}
pub fn emit_mov_mem_of_rax_rsp(self: *Self) !void { // mov [rax], rsp
    try self.emit_byte(0x48);
    try self.emit_byte(0x89);
    try self.emit_byte(0x20);
}
pub fn emit_mov_mem_of_rax_absolute_target(self: *Self, target: usize) !void { // mov qword [rax], <target>
    try self.emit_byte(0x48);
    try self.emit_byte(0xc7);
    try self.emit_byte(0x00);
    try self.emit_absolute_patch(target);
}
pub fn emit_mov_mem_of_rbx_plus_byte_rcx(self: *Self, byte: u8) !void { // mov [rbx + <byte>], rcx
    try self.emit_byte(0x48);
    try self.emit_byte(0x89);
    try self.emit_byte(0x4b);
    try self.emit_byte(byte);
}
pub fn emit_mov_rax_rcx(self: *Self) !void { // mov rax, rcx
    try self.emit_byte(0x48);
    try self.emit_byte(0x89);
    try self.emit_byte(0xc8);
}
pub fn emit_mov_rax_soil(self: *Self, a: Reg) !void { // mov rax, <a>
    try self.emit_byte(0x4c);
    try self.emit_byte(0x89);
    try self.emit_byte(0xc0 + 8 * a.to_byte());
}
pub fn emit_mov_rbp_rsp(self: *Self) !void { // mov rbp, rsp
    try self.emit_byte(0x48);
    try self.emit_byte(0x89);
    try self.emit_byte(0xe5);
}
pub fn emit_mov_rcx_mem_of_rbx_plus_byte(self: *Self, byte: u8) !void { // mov rax, [rbx + <byte>]
    try self.emit_byte(0x48);
    try self.emit_byte(0x8b);
    try self.emit_byte(0x4b);
    try self.emit_byte(byte);
}
pub fn emit_mov_rcx_r12(self: *Self) !void { // mov rcx, r12
    try self.emit_byte(0x4c);
    try self.emit_byte(0x89);
    try self.emit_byte(0xe1);
}
pub fn emit_mov_rdi_rbx(self: *Self) !void { // mov rdi, rbx
    try self.emit_byte(0x48);
    try self.emit_byte(0x89);
    try self.emit_byte(0xdf);
}
pub fn emit_mov_rdx_r11(self: *Self) !void { // mov rdx, r11
    try self.emit_byte(0x4c);
    try self.emit_byte(0x89);
    try self.emit_byte(0xda);
}
pub fn emit_mov_rsi_r10(self: *Self) !void { // mov rsi, r10
    try self.emit_byte(0x4c);
    try self.emit_byte(0x89);
    try self.emit_byte(0xd6);
}
pub fn emit_mov_rsi_rsp(self: *Self) !void { // mov rsi, rsp
    try self.emit_byte(0x48);
    try self.emit_byte(0x89);
    try self.emit_byte(0xe6);
}
pub fn emit_mov_rsp_mem_of_rax(self: *Self) !void { // mov rsp, [rax]
    try self.emit_byte(0x48);
    try self.emit_byte(0x8b);
    try self.emit_byte(0x20);
}
pub fn emit_mov_soil_rdx(self: *Self, a: Reg) !void { // mov <a>, rdx
    try self.emit_byte(0x49);
    try self.emit_byte(0x89);
    try self.emit_byte(0xd0 + a.to_byte());
}
pub fn emit_mov_soil_rax(self: *Self, a: Reg) !void { // mov <a>, rax
    try self.emit_byte(0x49);
    try self.emit_byte(0x89);
    try self.emit_byte(0xc0 + a.to_byte());
}
pub fn emit_mov_soil_mem_of_rbp_plus_soil(self: *Self, a: Reg, b: Reg) !void { // mov <a>, [rbp + <b>]
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
pub fn emit_mov_soilb_mem_of_rbp_plus_soil(self: *Self, a: Reg, b: Reg) !void { // mov <a>b, [rbp + <b>]
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
pub fn emit_mov_soil_soil(self: *Self, a: Reg, b: Reg) !void { // mov <a>, <b>
    try self.emit_byte(0x4d);
    try self.emit_byte(0x89);
    try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
}
pub fn emit_mov_soil_word(self: *Self, a: Reg, value: i64) !void { // mov <a>, <value>
    try self.emit_byte(0x49);
    try self.emit_byte(0xb8 + a.to_byte());
    try self.emit_word(value);
}
pub fn emit_mov_soilb_byte(self: *Self, a: Reg, value: u8) !void { // mov <a>b, <value>
    try self.emit_byte(0x41);
    try self.emit_byte(0xb0 + a.to_byte());
    try self.emit_byte(value);
}
pub fn emit_mov_rax_mem_of_rax(self: *Self) !void { // mov rax, [rax]
    try self.emit_byte(0x48);
    try self.emit_byte(0x8b);
    try self.emit_byte(0x00);
}
pub fn emit_nop(self: *Self) !void { // nop
    try self.emit_byte(0x90);
}
pub fn emit_not_soil(self: *Self, a: Reg) !void { // not <a>
    try self.emit_byte(0x49);
    try self.emit_byte(0xf7);
    try self.emit_byte(0xd0 + a.to_byte());
}
pub fn emit_or_soil_soil(self: *Self, a: Reg, b: Reg) !void { // or <a>, <b>
    try self.emit_byte(0x4d);
    try self.emit_byte(0x09);
    try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
}
pub fn emit_pop_rbp(self: *Self) !void { // pop rbp
    try self.emit_byte(0x5d);
}
pub fn emit_pop_rbx(self: *Self) !void { // pop rbx
    try self.emit_byte(0x5b);
}
pub fn emit_pop_rsp(self: *Self) !void { // pop rsp
    try self.emit_byte(0x5c);
}
pub fn emit_pop_soil(self: *Self, a: Reg) !void { // pop <a>
    try self.emit_byte(0x41);
    try self.emit_byte(0x58 + a.to_byte());
}
pub fn emit_push_rbp(self: *Self) !void { // push rbp
    try self.emit_byte(0x55);
}
pub fn emit_push_rbx(self: *Self) !void { // push rbx
    try self.emit_byte(0x53);
}
pub fn emit_push_soil(self: *Self, a: Reg) !void { // push <a>
    try self.emit_byte(0x41);
    try self.emit_byte(0x50 + a.to_byte());
}
pub fn emit_ret(self: *Self) !void { // ret
    try self.emit_byte(0xc3);
}
pub fn emit_shl_r9_1(self: *Self) !void { // shl r9, 1
    try self.emit_byte(0x49);
    try self.emit_byte(0xd1);
    try self.emit_byte(0xe1);
}
pub fn emit_shr_r9_63(self: *Self) !void { // shr r9, 63
    try self.emit_byte(0x49);
    try self.emit_byte(0xc1);
    try self.emit_byte(0xe9);
    try self.emit_byte(0x3f);
}
pub fn emit_seta_r9b(self: *Self) !void { // seta r9b
    try self.emit_byte(0x41);
    try self.emit_byte(0x0f);
    try self.emit_byte(0x97);
    try self.emit_byte(0xc1);
}
pub fn emit_setae_r9b(self: *Self) !void { // setae r9b
    try self.emit_byte(0x41);
    try self.emit_byte(0x0f);
    try self.emit_byte(0x93);
    try self.emit_byte(0xc1);
}
pub fn emit_sete_r9b(self: *Self) !void { // sete r9b
    try self.emit_byte(0x41);
    try self.emit_byte(0x0f);
    try self.emit_byte(0x94);
    try self.emit_byte(0xc1);
}
pub fn emit_setg_r9b(self: *Self) !void { // setg r9b
    try self.emit_byte(0x41);
    try self.emit_byte(0x0f);
    try self.emit_byte(0x9f);
    try self.emit_byte(0xc1);
}
pub fn emit_setle_r9b(self: *Self) !void { // setle r9b
    try self.emit_byte(0x41);
    try self.emit_byte(0x0f);
    try self.emit_byte(0x9e);
    try self.emit_byte(0xc1);
}
pub fn emit_setne_r9b(self: *Self) !void { // setne r9b
    try self.emit_byte(0x41);
    try self.emit_byte(0x0f);
    try self.emit_byte(0x95);
    try self.emit_byte(0xc1);
}
pub fn emit_sub_soil_soil(self: *Self, a: Reg, b: Reg) !void { // sub <a>, <b>
    try self.emit_byte(0x4d);
    try self.emit_byte(0x29);
    try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
}
pub fn emit_sub_r8_8(self: *Self) !void { // sub r8, 8
    try self.emit_byte(0x49);
    try self.emit_byte(0x83);
    try self.emit_byte(0xe8);
    try self.emit_byte(0x08);
}
pub fn emit_sub_rsp_8(self: *Self) !void { // sub rsp, 8
    try self.emit_byte(0x48);
    try self.emit_byte(0x83);
    try self.emit_byte(0xec);
    try self.emit_byte(0x08);
}
pub fn emit_test_r9_r9(self: *Self) !void { // test r9, r9
    try self.emit_byte(0x4d);
    try self.emit_byte(0x85);
    try self.emit_byte(0xc9);
}
pub fn emit_vaddsd_xmm0_xmm0_xmm1(self: *Self) !void { // vaddsd xmm0, xmm0, xmm1
    try self.emit_byte(0xc5);
    try self.emit_byte(0xfb);
    try self.emit_byte(0x58);
    try self.emit_byte(0xc1);
}
pub fn emit_vcvtsi2sd_xmm0_xmm0_soil(self: *Self, a: Reg) !void { // vcvtsi2sd xmm0, xmm0, <a>
    try self.emit_byte(0xc4);
    try self.emit_byte(0xc1);
    try self.emit_byte(0xfb);
    try self.emit_byte(0x2a);
    try self.emit_byte(0xc0 + a.to_byte());
}
pub fn emit_vcvttsd2si_soil_xmm0(self: *Self, a: Reg) !void { // vcvttsd2si <a>, xmm0
    try self.emit_byte(0xc4);
    try self.emit_byte(0x61);
    try self.emit_byte(0xfb);
    try self.emit_byte(0x2c);
    try self.emit_byte(0xc0 + 8 * a.to_byte());
}
pub fn emit_vdivsd_xmm0_xmm0_xmm1(self: *Self) !void { // vdivsd xmm0, xmm0, xmm1
    try self.emit_byte(0xc5);
    try self.emit_byte(0xfb);
    try self.emit_byte(0x5e);
    try self.emit_byte(0xc1);
}
pub fn emit_vmovq_soil_xmm0(self: *Self, a: Reg) !void { // vmovq <a>, xmm0
    try self.emit_byte(0xc4);
    try self.emit_byte(0xc1);
    try self.emit_byte(0xf9);
    try self.emit_byte(0x7e);
    try self.emit_byte(0xc0 + a.to_byte());
}
pub fn emit_vmovq_xmm0_soil(self: *Self, a: Reg) !void { // vmovq xmm0, <a>
    try self.emit_byte(0xc4);
    try self.emit_byte(0xc1);
    try self.emit_byte(0xf9);
    try self.emit_byte(0x6e);
    try self.emit_byte(0xc0 + a.to_byte());
}
pub fn emit_vmovq_xmm1_soil(self: *Self, a: Reg) !void { // vmovq xmm1, <a>
    try self.emit_byte(0xc4);
    try self.emit_byte(0xc1);
    try self.emit_byte(0xf9);
    try self.emit_byte(0x6e);
    try self.emit_byte(0xc8 + a.to_byte());
}
pub fn emit_vmulsd_xmm0_xmm0_xmm1(self: *Self) !void { // vmulsd xmm0, xmm0, xmm1
    try self.emit_byte(0xc5);
    try self.emit_byte(0xfb);
    try self.emit_byte(0x59);
    try self.emit_byte(0xc1);
}
pub fn emit_vsubsd_xmm0_xmm0_xmm1(self: *Self) !void { // vsubsd xmm0, xmm0, xmm1
    try self.emit_byte(0xc5);
    try self.emit_byte(0xfb);
    try self.emit_byte(0x5c);
    try self.emit_byte(0xc1);
}
pub fn emit_vucomisd_xmm0_xmm1(self: *Self) !void { // vucomisd xmm0, xmm1
    try self.emit_byte(0xc5);
    try self.emit_byte(0xf9);
    try self.emit_byte(0x2e);
    try self.emit_byte(0xc1);
}
pub fn emit_vucomisd_xmm1_xmm0(self: *Self) !void { // vucomisd xmm1, xmm0
    try self.emit_byte(0xc5);
    try self.emit_byte(0xf9);
    try self.emit_byte(0x2e);
    try self.emit_byte(0xc8);
}
pub fn emit_vxorpd_xmm1_xmm1_xmm1(self: *Self) !void { // vxorpd xmm1, xmm1, xmm1
    try self.emit_byte(0xc5);
    try self.emit_byte(0xf1);
    try self.emit_byte(0x57);
    try self.emit_byte(0xc9);
}
pub fn emit_xor_rdx_rdx(self: *Self) !void { // xor rdx, rdx
    try self.emit_byte(0x48);
    try self.emit_byte(0x31);
    try self.emit_byte(0xd2);
}
pub fn emit_xor_soil_soil(self: *Self, a: Reg, b: Reg) !void { // xor <a>, <b>
    try self.emit_byte(0x4d);
    try self.emit_byte(0x31);
    try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
}
