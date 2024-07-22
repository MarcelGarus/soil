const std = @import("std");

pub const Reg = enum {
    sp,
    st,
    a,
    b,
    c,
    d,
    e,
    f,

    pub fn parse(byte: u8) !Reg {
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

    pub fn to_byte(self: Reg) u8 {
        return @as(u8, @intFromEnum(self));
    }

    pub fn format(self: Reg, fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}", .{@tagName(self)});
    }
};
pub const Regs = struct { a: Reg, b: Reg };
pub const RegAndWord = struct { reg: Reg, word: i64 };
pub const RegAndByte = struct { reg: Reg, byte: u8 };
pub const Instruction = union(enum) {
    nop,
    panic,
    trystart: usize,
    tryend,
    move: Regs,
    movei: RegAndWord,
    moveib: RegAndByte,
    load: Regs,
    loadb: Regs,
    store: Regs,
    storeb: Regs,
    push: Reg,
    pop: Reg,
    jump: usize,
    cjump: usize,
    call: usize,
    ret,
    syscall: u8,
    cmp: Regs,
    isequal,
    isless,
    isgreater,
    islessequal,
    isgreaterequal,
    isnotequal,
    fcmp: Regs,
    fisequal,
    fisless,
    fisgreater,
    fislessequal,
    fisgreaterequal,
    fisnotequal,
    inttofloat: Reg,
    floattoint: Reg,
    add: Regs,
    sub: Regs,
    mul: Regs,
    div: Regs,
    rem: Regs,
    fadd: Regs,
    fsub: Regs,
    fmul: Regs,
    fdiv: Regs,
    and_: Regs,
    or_: Regs,
    xor: Regs,
    not: Reg,

    pub fn format(self: Instruction, fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        const info = @typeInfo(Instruction).Union;
        inline for (info.fields) |field| {
            if (info.tag_type) |tag_type| {
                if (self == @field(tag_type, field.name)) {
                    try writer.print("{s}", .{field.name});
                    const payload = @field(self, field.name);
                    switch (field.type) {
                        void => {},
                        u8 => try writer.print(" {}", .{payload}),
                        usize => try writer.print(" {}", .{payload}),
                        Reg => try writer.print(" {}", .{payload}),
                        Regs => try writer.print(" {} {}", .{ payload.a, payload.b }),
                        RegAndWord => try writer.print(" {} {}", .{ payload.reg, payload.word }),
                        RegAndByte => try writer.print(" {} {}", .{ payload.reg, payload.byte }),
                        else => unreachable,
                    }
                }
            }
        }
    }
};
