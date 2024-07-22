const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ByteCode = @import("byte_code.zig");
const File = @import("file.zig");

fn parse_amount(input: *[]const u8, n: usize) ![]const u8 {
    if (input.len < n) return error.EndOfInput;
    const cut: []const u8 = input.*[0..n];
    input.* = input.*[n..];
    return cut;
}

fn parse_byte(input: *[]const u8) !u8 {
    return (try parse_amount(input, 1))[0];
}

fn parse_word(input: *[]const u8) !i64 {
    return std.mem.readInt(i64, (try parse_amount(input, 8))[0..8], .little);
}

fn parse_usize(input: *[]const u8) !usize {
    return @intCast(try parse_word(input));
}

fn parse_magic_byte(input: *[]const u8, expected: u8) !void {
    if (try parse_byte(input) != expected) return error.MagicBytesMismatch;
}

fn parse_labels(input: *[]const u8, alloc: Alloc) !File.Labels {
    const count: usize = @intCast(try parse_word(input));
    var labels_to_offset = ArrayList(File.LabelAndOffset).init(alloc);
    for (0..count) |_| {
        const offset: usize = try parse_usize(input);
        const label_len: usize = try parse_usize(input);
        const label = try parse_amount(input, label_len);
        try labels_to_offset.append(.{ .offset = offset, .label = label });
    }
    return .{ .labels = labels_to_offset.items };
}

pub fn parse_file(input: []const u8, alloc: Alloc) !File {
    var file = File{
        .name = &[_]u8{},
        .description = &[_]u8{},
        .byte_code = &[_]u8{},
        .initial_memory = &[_]u8{},
        .labels = File.Labels.init(),
    };

    var rest = input;
    try parse_magic_byte(&rest, 's');
    try parse_magic_byte(&rest, 'o');
    try parse_magic_byte(&rest, 'i');
    try parse_magic_byte(&rest, 'l');

    while (true) {
        const section_type = parse_byte(&rest) catch |err| switch (err) {
            error.EndOfInput => break,
            else => return err,
        };
        const section_len = try parse_usize(&rest);
        var section = try parse_amount(&rest, section_len);
        switch (section_type) {
            0 => file.byte_code = section,
            1 => file.initial_memory = section,
            2 => file.name = section,
            3 => file.labels = try parse_labels(&section, alloc),
            4 => file.description = section,
            else => {},
        }
    }

    return file;
}

fn parse_reg(input: *[]const u8) !ByteCode.Reg {
    return @enumFromInt(try parse_byte(input));
}

fn parse_regs(input: *[]const u8) !ByteCode.Regs {
    const byte = try parse_byte(input);
    return .{
        .a = @enumFromInt(byte & 0xf),
        .b = @enumFromInt(byte >> 4),
    };
}

fn parse_reg_and_word(input: *[]const u8) !ByteCode.RegAndWord {
    return .{ .reg = try parse_reg(input), .word = try parse_word(input) };
}

fn parse_reg_and_byte(input: *[]const u8) !ByteCode.RegAndByte {
    return .{ .reg = try parse_reg(input), .byte = try parse_byte(input) };
}

pub fn parse_instruction(input: *[]const u8) !ByteCode.Instruction {
    const opcode = try parse_byte(input);
    return switch (opcode) {
        0x00 => .nop,
        0xe0 => .panic,
        0xe1 => .{ .trystart = try parse_usize(input) },
        0xe2 => .tryend,
        0xd0 => .{ .move = try parse_regs(input) },
        0xd1 => .{ .movei = try parse_reg_and_word(input) },
        0xd2 => .{ .moveib = try parse_reg_and_byte(input) },
        0xd3 => .{ .load = try parse_regs(input) },
        0xd4 => .{ .loadb = try parse_regs(input) },
        0xd5 => .{ .store = try parse_regs(input) },
        0xd6 => .{ .storeb = try parse_regs(input) },
        0xd7 => .{ .push = try parse_reg(input) },
        0xd8 => .{ .pop = try parse_reg(input) },
        0xf0 => .{ .jump = try parse_usize(input) },
        0xf1 => .{ .cjump = try parse_usize(input) },
        0xf2 => .{ .call = try parse_usize(input) },
        0xf3 => .ret,
        0xf4 => .{ .syscall = try parse_byte(input) },
        0xc0 => .{ .cmp = try parse_regs(input) },
        0xc1 => .isequal,
        0xc2 => .isless,
        0xc3 => .isgreater,
        0xc4 => .islessequal,
        0xc5 => .isgreaterequal,
        0xc6 => .isnotequal,
        0xc7 => .{ .fcmp = try parse_regs(input) },
        0xc8 => .fisequal,
        0xc9 => .fisless,
        0xca => .fisgreater,
        0xcb => .fislessequal,
        0xcc => .fisgreaterequal,
        0xcd => .fisnotequal,
        0xce => .{ .inttofloat = try parse_reg(input) },
        0xcf => .{ .floattoint = try parse_reg(input) },
        0xa0 => .{ .add = try parse_regs(input) },
        0xa1 => .{ .sub = try parse_regs(input) },
        0xa2 => .{ .mul = try parse_regs(input) },
        0xa3 => .{ .div = try parse_regs(input) },
        0xa4 => .{ .rem = try parse_regs(input) },
        0xa5 => .{ .fadd = try parse_regs(input) },
        0xa6 => .{ .fsub = try parse_regs(input) },
        0xa7 => .{ .fmul = try parse_regs(input) },
        0xa8 => .{ .fdiv = try parse_regs(input) },
        0xb0 => .{ .and_ = try parse_regs(input) },
        0xb1 => .{ .or_ = try parse_regs(input) },
        0xb2 => .{ .xor = try parse_regs(input) },
        0xb3 => .{ .not = try parse_reg(input) },
        else => return error.UnknownOpcode,
    };
}
