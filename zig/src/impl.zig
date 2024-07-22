const builtin = @import("builtin");
const std = @import("std");
const Alloc = std.mem.Allocator;

const use_interpreter_override = true;

// Used by syscalls to return two values.
pub const TwoValues = extern struct { a: i64, b: i64 };

pub const Vm = Impl().Vm;
pub const run = Impl().run;

fn Impl() type {
    const Interpreter = struct {
        const compile = @import("interpreter/compiler.zig").compile;
        const Vm = @import("interpreter/vm.zig");
        fn run(alloc: Alloc, binary: []u8, Syscalls: type) !void {
            std.debug.print("compiling.\n", .{});
            var vm = try compile(alloc, binary);
            try vm.run(Syscalls);
        }
    };

    if (use_interpreter_override)
        return Interpreter;

    switch (builtin.cpu.arch) {
        .x86_64 => {
            const compile = @import("x86_64/compiler.zig").compile;
            return struct {
                const Vm = @import("x86_64/vm.zig");
                fn run(alloc: Alloc, binary: []u8, Syscalls: type) !void {
                    var vm = try compile(alloc, binary, Syscalls);
                    try vm.run();
                }
            };
        },
        else => return Interpreter,
    }
}
