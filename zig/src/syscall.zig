const std = @import("std");
const Vm = @import("root.zig").Vm;

// Syscalls that want to return values in registers can use these types.
pub const ZeroValues = void;
pub const OneValue = i64;
pub const TwoValues = extern struct { a: i64, b: i64 };

fn name_by_number(number: u8) ?[]const u8 {
    return switch (number) {
        0 => "exit",
        1 => "print",
        2 => "log",
        3 => "create",
        4 => "open_reading",
        5 => "open_writing",
        6 => "read",
        7 => "write",
        8 => "close",
        9 => "argc",
        10 => "arg",
        11 => "read_input",
        12 => "execute",
        13 => "ui_dimensions",
        14 => "ui_render",
        15 => "get_key_pressed",
        16 => "instant_now",
        else => null,
    };
}

pub fn check_struct(Syscalls: type) void {
    switch (@typeInfo(Syscalls)) {
        .Struct => {},
        else => @compileError("Syscall struct has to be a struct."),
    }

    // All syscalls need to have good signatures.
    for (0..256) |number| {
        const option_name = name_by_number(number);
        if (option_name == null) continue; // unknown syscall, that's fine
        const name = option_name.?;
        if (!@hasDecl(Syscalls, name)) continue; // not implemented, that's fine
        check_syscall_signature(Syscalls, name);
    }

    // The syscall struct should contain a not_implemented function that takes
    // a *Vm.
    const not_implemented = "not_implemented";
    if (!@hasDecl(Syscalls, not_implemented))
        @compileError("The Syscall struct doesn't contain a not_implemented function.");
    check_syscall_signature(Syscalls, not_implemented);
}

pub fn check_syscall_signature(Syscalls: type, name: []const u8) void {
    const signature = switch (@typeInfo(@TypeOf(@field(Syscalls, name)))) {
        .Fn => |f| f,
        else => return,
    };

    if (signature.is_generic)
        @compileError("Syscall " ++ name ++ " is generic.");
    if (signature.is_var_args)
        @compileError("Syscall " ++ name ++ " uses var args.");
    if (signature.calling_convention != .C)
        @compileError("Syscall " ++ name ++ " doesn't use the C calling convention. All hail the C calling convention!");

    inline for (signature.params, 0..) |param, i| {
        if (param.type) |param_type| {
            if (i == 0 and param_type != *Vm)
                @compileError("The first argument of syscall " ++ name ++ " is not a *Vm, but " ++ @typeName(param_type) ++ ".");
            if (i > 0 and param_type != i64)
                @compileError("All except the first syscall argument must be i64 (the content of a register). For the " ++ name ++ " syscall, an argument is " ++ @typeName(param_type) ++ ".");
        }
    }
    const return_value = signature.return_type orelse @compileError("The return value of the " ++ name ++ " syscalls is not known at compile-time.");

    // Move the return value into the correct registers.
    switch (return_value) {
        ZeroValues => {},
        OneValue => {},
        TwoValues => {},
        else => @compileError("The syscall " ++ name ++ " doesn't return ZeroValues, OneValue, or TwoValues"),
    }
}

pub fn by_number(Syscalls: type, comptime n: u8) TypeOfSyscall(Syscalls, n) {
    const name = name_by_number(n) orelse return Syscalls.not_implemented;
    if (!@hasDecl(Syscalls, name)) return Syscalls.not_implemented;
    return @field(Syscalls, name);
}

fn TypeOfSyscall(Syscalls: type, comptime n: u8) type {
    const name = name_by_number(n) orelse return @TypeOf(Syscalls.not_implemented);
    if (!@hasDecl(Syscalls, name)) return @TypeOf(Syscalls.not_implemented);
    return @TypeOf(@field(Syscalls, name));
}
