// A builder for x86_64 machine code. Turns out, the instruction encoding is ... interesting.

const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reg = @import("reg.zig").Reg;
const Self = @This();

buffer: []align(std.mem.page_size) u8,
len: usize,
patches: ArrayList(Patch),

const Patch = struct {
    where: usize,
    target: usize,
};

pub fn init(alloc: Alloc) !Self {
    return Self{
        .buffer = try alloc.allocWithOptions(u8, 100000000, std.mem.page_size, null),
        .len = 0,
        .patches = ArrayList(Patch).init(alloc),
    };
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

fn emit_relative_patch(self: *Self, target: usize) !void {
    try self.patches.append(.{ .where = self.buffer.len, .target = target });
    try self.reserve(4);
}
fn emit_relative_comptime(self: *Self, target: usize) !void {
    // Relative targets are relative to the end of the instruction (hence, the + 4).
    const base: i32 = @intCast(@intFromPtr(&self.buffer) + self.len + 4);
    const target_i32: i32 = @intCast(target);
    const relative: i32 = target_i32 - base;
    try self.emit_int(relative);
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
pub fn emit_add_rax_rbp(self: *Self) !void { // add rax, rbp
    try self.emit_byte(0x48);
    try self.emit_byte(0x89);
    try self.emit_byte(0xe8);
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
pub fn emit_and_r9_0xff(self: *Self) !void { // and r9, 0xff
    try self.emit_byte(0x49);
    try self.emit_byte(0x81);
    try self.emit_byte(0xe1);
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
pub fn emit_idiv_soil(self: *Self, a: Reg) !void { // idiv <a>
    try self.emit_byte(0x49);
    try self.emit_byte(0xf7);
    try self.emit_byte(0xf8 + a.to_byte());
}
pub fn emit_imul_soil_soil(self: *Self, a: Reg, b: Reg) !void { // and <a>, <b>
    try self.emit_byte(0x4d);
    try self.emit_byte(0x0f);
    try self.emit_byte(0xaf);
    try self.emit_byte(0xc0 + b.to_byte() * 8 * a.to_byte());
}
pub fn emit_jmp(self: *Self, target: usize) !void { // jmp <target>
    try self.emit_byte(0xe);
    try self.emit_relative_patch(target);
}
pub fn emit_jmp_to_comptime(self: *Self, target: usize) !void { // jmp <target> // target can't be r12 or rax
    try self.emit_byte(0xe9);
    try self.emit_relative_comptime(target);
}
pub fn emit_jnz(self: *Self, target: usize) !void { // jnz <target> // target can't be r12 or r13
    try self.emit_byte(0x0f);
    try self.emit_byte(0x85);
    try self.emit_relative_patch(target);
}
pub fn emit_mov_al_byte(self: *Self, a: Reg) !void { // move al, <a>
    try self.emit_byte(0xb0);
    try self.emit_byte(a.to_byte());
}
pub fn emit_mov_rax_soil(self: *Self, a: Reg) !void { // mov rax, <a>
    try self.emit_byte(0x4c);
    try self.emit_byte(0x89);
    try self.emit_byte(0xc0 + 8 * a.to_byte());
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
pub fn emit_not_r9(self: *Self) !void { // not r9
    try self.emit_byte(0x49);
    try self.emit_byte(0xf7);
    try self.emit_byte(0xd1);
}
pub fn emit_not_soil(self: *Self, a: Reg) !void { // not a
    try self.emit_byte(0x49);
    try self.emit_byte(0xf7);
    try self.emit_byte(0xd0 + a.to_byte());
}
pub fn emit_or_soil_soil(self: *Self, a: Reg, b: Reg) !void { // or <a>, <b>
    try self.emit_byte(0x4d);
    try self.emit_byte(0x09);
    try self.emit_byte(0xc0 + a.to_byte() + 8 * b.to_byte());
}
pub fn emit_push(self: *Self, a: Reg) !void { // push <a>
    try self.emit_byte(0x41);
    try self.emit_byte(0x50 + a.to_byte());
}
pub fn emit_pop(self: *Self, a: Reg) !void { // pop <a>
    try self.emit_byte(0x41);
    try self.emit_byte(0x58 + a.to_byte());
}
pub fn emit_ret(self: *Self) !void { // ret
    try self.emit_byte(0xc3);
}
pub fn emit_shr_r9_63(self: *Self) !void { // shr r9, 63
    try self.emit_byte(0x49);
    try self.emit_byte(0xc1);
    try self.emit_byte(0xe9);
    try self.emit_byte(0x3f);
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
pub fn emit_test_r9_r9(self: *Self) !void { // test r9, r9
    try self.emit_byte(0x4d);
    try self.emit_byte(0x85);
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
