const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Impl = @import("../impl.zig");
const ByteCode = @import("byte_code.zig");
const Reg = ByteCode.Reg;
const Regs = ByteCode.Regs;
const Instruction = ByteCode.Instruction;
const RegAndWord = ByteCode.RegAndWord;
const RegAndByte = ByteCode.RegAndByte;

pub const trace_calls = false;
pub const trace_regs = false;
pub const memory_size = 2000000000;

byte_code: []u8,
ip: usize,
regs: [8]i64,
memory: []u8,
call_stack: ArrayList(usize),
try_stack: ArrayList(TryScope),
labels: []LabelAndOffset,

pub const TryScope = packed struct {
    call_stack_len: usize,
    sp: i64,
    catch_: usize, // machine code offset
};

pub const LabelAndOffset = struct { label: []u8, offset: usize };

const Self = @This();

fn eat_byte(vm: *Self) !u8 {
    const byte = vm.byte_code[vm.ip];
    vm.ip += 1;
    return byte;
}
fn eat_word(vm: *Self) !i64 {
    const word = std.mem.readInt(i64, vm.byte_code[vm.ip..][0..8], .little);
    vm.ip += 8;
    return word;
}
fn eat_regs(vm: *Self) !Regs {
    const byte = try vm.eat_byte();
    return .{ .a = try Reg.parse(byte & 0xf), .b = try Reg.parse(byte >> 4) };
}
fn eat_reg(vm: *Self) !Reg {
    return try Reg.parse(try vm.eat_byte());
}
fn eat_reg_and_word(vm: *Self) !RegAndWord {
    return .{ .reg = try vm.eat_reg(), .word = try vm.eat_word() };
}
fn eat_reg_and_byte(vm: *Self) !RegAndByte {
    return .{ .reg = try vm.eat_reg(), .byte = try vm.eat_byte() };
}

fn eat_instruction(vm: *Self) !Instruction {
    const opcode = try vm.eat_byte();
    return switch (opcode) {
        0x00 => .nop,
        0xe0 => .panic,
        0xe1 => .{ .trystart = @intCast(try vm.eat_word()) },
        0xe2 => .tryend,
        0xd0 => .{ .move = try vm.eat_regs() },
        0xd1 => .{ .movei = try vm.eat_reg_and_word() },
        0xd2 => .{ .moveib = try vm.eat_reg_and_byte() },
        0xd3 => .{ .load = try vm.eat_regs() },
        0xd4 => .{ .loadb = try vm.eat_regs() },
        0xd5 => .{ .store = try vm.eat_regs() },
        0xd6 => .{ .storeb = try vm.eat_regs() },
        0xd7 => .{ .push = try vm.eat_reg() },
        0xd8 => .{ .pop = try vm.eat_reg() },
        0xf0 => .{ .jump = @intCast(try vm.eat_word()) },
        0xf1 => .{ .cjump = @intCast(try vm.eat_word()) },
        0xf2 => .{ .call = @intCast(try vm.eat_word()) },
        0xf3 => .ret,
        0xf4 => .{ .syscall = try vm.eat_byte() },
        0xc0 => .{ .cmp = try vm.eat_regs() },
        0xc1 => .isequal,
        0xc2 => .isless,
        0xc3 => .isgreater,
        0xc4 => .islessequal,
        0xc5 => .isgreaterequal,
        0xc6 => .isnotequal,
        0xc7 => .{ .fcmp = try vm.eat_regs() },
        0xc8 => .fisequal,
        0xc9 => .fisless,
        0xca => .fisgreater,
        0xcb => .fislessequal,
        0xcc => .fisgreaterequal,
        0xcd => .fisnotequal,
        0xce => .{ .inttofloat = try vm.eat_reg() },
        0xcf => .{ .floattoint = try vm.eat_reg() },
        0xa0 => .{ .add = try vm.eat_regs() },
        0xa1 => .{ .sub = try vm.eat_regs() },
        0xa2 => .{ .mul = try vm.eat_regs() },
        0xa3 => .{ .div = try vm.eat_regs() },
        0xa4 => .{ .rem = try vm.eat_regs() },
        0xa5 => .{ .fadd = try vm.eat_regs() },
        0xa6 => .{ .fsub = try vm.eat_regs() },
        0xa7 => .{ .fmul = try vm.eat_regs() },
        0xa8 => .{ .fdiv = try vm.eat_regs() },
        0xb0 => .{ .and_ = try vm.eat_regs() },
        0xb1 => .{ .or_ = try vm.eat_regs() },
        0xb2 => .{ .xor = try vm.eat_regs() },
        0xb3 => .{ .not = try vm.eat_reg() },
        else => return error.UnknownOpcode,
    };
}

pub fn set_int(vm: *Self, reg: Reg, int: i64) void {
    vm.regs[reg.to_byte()] = int;
}
pub fn get_int(vm: *Self, reg: Reg) i64 {
    return vm.regs[reg.to_byte()];
}
pub fn set_float(vm: *Self, reg: Reg, float: f64) void {
    vm.regs[reg.to_byte()] = @bitCast(float);
}
pub fn get_float(vm: *Self, reg: Reg) f64 {
    return @bitCast(vm.regs[reg.to_byte()]);
}

pub fn write_mem_word(vm: *Self, where: usize, word: i64) !void {
    if (where + 8 > memory_size) return error.InvalidWrite;
    std.mem.writeInt(i64, vm.memory[where..][0..8], word, .little);
}
pub fn read_mem_word(vm: *Self, where: usize) !i64 {
    if (where + 8 > memory_size) return error.InvalidRead;
    return std.mem.readInt(i64, vm.memory[where..][0..8], .little);
}
pub fn write_mem_byte(vm: *Self, where: usize, byte: u8) !void {
    if (where + 1 > memory_size) return error.InvalidWrite;
    vm.memory[where] = byte;
}
pub fn read_mem_byte(vm: *Self, where: usize) !i64 {
    if (where + 1 > memory_size) return error.InvalidRead;
    return vm.memory[where];
}

fn run_single(vm: *Self, Syscalls: type) !void {
    const instruction = try vm.eat_instruction();
    if (trace_regs) {
        for (vm.call_stack.items) |_| std.debug.print(" ", .{});
        std.debug.print(
            "{}\t",
            .{
                instruction,
            },
        );
    }
    switch (instruction) {
        .nop => {},
        .panic => if (vm.try_stack.items.len > 0) {
            const try_ = vm.try_stack.pop();
            vm.call_stack.items.len = try_.call_stack_len;
            vm.set_int(.sp, try_.sp);
            vm.ip = try_.catch_;
        } else {
            for (vm.call_stack.items) |pos| {
                std.debug.print("{s}\n", .{search_for_label(vm.labels, pos) orelse "<no label>"});
            }
            unreachable;
            // return error.Panicked;
        },
        .trystart => |catch_| try vm.try_stack.append(.{
            .call_stack_len = vm.call_stack.items.len,
            .sp = vm.get_int(.sp),
            .catch_ = catch_,
        }),
        .tryend => _ = vm.try_stack.pop(),
        .move => |regs| vm.set_int(regs.a, vm.get_int(regs.b)),
        .movei => |args| vm.set_int(args.reg, args.word),
        .moveib => |args| vm.set_int(args.reg, @intCast(args.byte)),
        .load => |regs| vm.set_int(regs.a, try vm.read_mem_word(@intCast(vm.get_int(regs.b)))),
        .loadb => |regs| vm.set_int(regs.a, @intCast(try vm.read_mem_byte(@intCast(vm.get_int(regs.b))))),
        .store => |regs| try vm.write_mem_word(@intCast(vm.get_int(regs.a)), vm.get_int(regs.b)),
        .storeb => |regs| {
            const unsigned: u64 = @bitCast(vm.get_int(regs.b));
            try vm.write_mem_byte(@intCast(vm.get_int(regs.a)), @truncate(unsigned));
        },
        .push => |reg| {
            const new_sp = vm.get_int(.sp) - 8;
            vm.set_int(.sp, new_sp);
            try vm.write_mem_word(@intCast(new_sp), vm.get_int(reg));
        },
        .pop => |reg| {
            const old_sp = vm.get_int(.sp);
            vm.set_int(.sp, old_sp + 8);
            vm.set_int(reg, try vm.read_mem_word(@intCast(old_sp)));
        },
        .jump => |target| vm.ip = @intCast(target),
        .cjump => |target| {
            if (vm.get_int(.st) != 0)
                vm.ip = @intCast(target);
        },
        .call => |target| {
            const return_target = vm.ip;
            try vm.call_stack.append(return_target);
            vm.ip = target;

            if (trace_calls) {
                for (vm.call_stack.items) |_| std.debug.print(" ", .{});
                if (search_for_label(vm.labels, target)) |label| {
                    std.debug.print("{s}\n", .{label});
                } else {
                    std.debug.print("<no label>\n", .{});
                }
            }
        },
        .ret => vm.ip = vm.call_stack.pop(),
        .syscall => |number| {
            // Syscalls are implemented in Zig.
            inline for (0..256) |n| {
                if (number == n) {
                    const name = comptime Syscalls.name_by_number(n);
                    const fun_exists = name != null and @hasDecl(Syscalls, name.?);
                    if (!fun_exists) {
                        return error.SyscallDoesntExist;
                    } else {
                        const fun = @field(Syscalls, name.?);
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
                                    if (param_type != *Self)
                                        @compileError(name.? ++ " syscall's first arg is not *Vm, but " ++ @typeName(param_type) ++ ".");
                                } else {
                                    if (param_type != i64)
                                        @compileError(name.? ++ " syscall's args must be i64 (the register contents), but an argument is a " ++ @typeName(param_type) ++ ".");
                                }
                            }
                        }

                        const result = switch (signature.params.len) {
                            1 => fun(vm),
                            2 => fun(vm, vm.get_int(.a)),
                            3 => fun(vm, vm.get_int(.a), vm.get_int(.b)),
                            4 => fun(vm, vm.get_int(.a), vm.get_int(.b), vm.get_int(.c)),
                            else => @compileError("handle syscalls with more params"),
                        };

                        // Move the return value into the correct registers.
                        switch (@TypeOf(result)) {
                            void => {},
                            i64 => vm.set_int(.a, result),
                            Impl.TwoValues => {
                                vm.set_int(.a, result.a);
                                vm.set_int(.b, result.b);
                            },
                            else => @compileError("syscalls can only return void or i64 or TwoValues"),
                        }
                    }
                }
            }
        },
        .cmp => |regs| vm.set_int(.st, vm.get_int(regs.a) - vm.get_int(regs.b)),
        .isequal => vm.set_int(.st, if (vm.get_int(.st) == 0) 1 else 0),
        .isless => vm.set_int(.st, if (vm.get_int(.st) < 0) 1 else 0),
        .isgreater => vm.set_int(.st, if (vm.get_int(.st) > 0) 1 else 0),
        .islessequal => vm.set_int(.st, if (vm.get_int(.st) <= 0) 1 else 0),
        .isgreaterequal => vm.set_int(.st, if (vm.get_int(.st) >= 0) 1 else 0),
        .isnotequal => vm.set_int(.st, if (vm.get_int(.st) != 0) 1 else 0),
        .fcmp => |regs| vm.set_float(.st, vm.get_float(regs.a) - vm.get_float(regs.b)),
        .fisequal => vm.set_int(.st, if (vm.get_float(.st) == 0.0) 1 else 0),
        .fisless => vm.set_int(.st, if (vm.get_float(.st) < 0.0) 1 else 0),
        .fisgreater => vm.set_int(.st, if (vm.get_float(.st) > 0.0) 1 else 0),
        .fislessequal => vm.set_int(.st, if (vm.get_float(.st) <= 0.0) 1 else 0),
        .fisgreaterequal => vm.set_int(.st, if (vm.get_float(.st) >= 0.0) 1 else 0),
        .fisnotequal => vm.set_int(.st, if (vm.get_float(.st) != 0.0) 1 else 0),
        .inttofloat => |reg| vm.set_float(reg, @floatFromInt(vm.get_int(reg))),
        .floattoint => |reg| vm.set_int(reg, @intFromFloat(@trunc(vm.get_float(reg)))),
        .add => |regs| vm.set_int(regs.a, vm.get_int(regs.a) +% vm.get_int(regs.b)),
        .sub => |regs| vm.set_int(regs.a, vm.get_int(regs.a) -% vm.get_int(regs.b)),
        .mul => |regs| vm.set_int(regs.a, vm.get_int(regs.a) *% vm.get_int(regs.b)),
        .div => |regs| {
            if (vm.get_int(regs.b) == 0) return error.DivByZero;
            vm.set_int(regs.a, @divTrunc(vm.get_int(regs.a), vm.get_int(regs.b)));
        },
        .rem => |regs| {
            if (vm.get_int(regs.b) == 0) return error.DivByZero;
            vm.set_int(regs.a, @rem(vm.get_int(regs.a), vm.get_int(regs.b)));
        },
        .fadd => |regs| vm.set_float(regs.a, vm.get_float(regs.a) + vm.get_float(regs.b)),
        .fsub => |regs| vm.set_float(regs.a, vm.get_float(regs.a) - vm.get_float(regs.b)),
        .fmul => |regs| vm.set_float(regs.a, vm.get_float(regs.a) * vm.get_float(regs.b)),
        .fdiv => |regs| {
            if (vm.get_float(regs.b) == 0.0) return error.FdivByZero;
            vm.set_float(regs.a, vm.get_float(regs.a) / vm.get_float(regs.b));
        },
        .and_ => |regs| vm.set_int(regs.a, vm.get_int(regs.a) & vm.get_int(regs.b)),
        .or_ => |regs| vm.set_int(regs.a, vm.get_int(regs.a) | vm.get_int(regs.b)),
        .xor => |regs| vm.set_int(regs.a, vm.get_int(regs.a) ^ vm.get_int(regs.b)),
        .not => |reg| vm.set_int(reg, ~vm.get_int(reg)),
    }
    if (trace_regs) {
        std.debug.print("ip = {}, sp = {}, st = {}, a = {}, b = {}, c = {}, d = {}, e = {}, f = {}\n", .{
            vm.ip,
            vm.get_int(.sp),
            vm.get_int(.st),
            vm.get_int(.a),
            vm.get_int(.b),
            vm.get_int(.c),
            vm.get_int(.d),
            vm.get_int(.e),
            vm.get_int(.f),
        });
    }
}

pub fn run(vm: *Self, Syscalls: type) !void {
    while (true) try vm.run_single(Syscalls);
    std.process.exit(0);
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
