const builtin = @import("builtin");
const std = @import("std");
const Alloc = std.mem.Allocator;

const use_interpreter_override = false;

pub const Vm = Impl().Vm;
pub const run = Impl().run;

fn Impl() type {
    const Interpreter = struct {
        const Vm = usize;
        fn run(_: Alloc, _: []u8, _: type) !void {
            std.log.err("Interpreter not implemented", .{});
            std.process.exit(1);
        }
    };

    if (use_interpreter_override)
        return Interpreter;

    switch (builtin.cpu.arch) {
        .x86_64 => {
            const compile = @import("x86_64/compiler.zig").compile;
            const TheVm = @import("x86_64/vm.zig");
            return struct {
                const Vm = TheVm;
                fn run(alloc: Alloc, binary: []u8, Syscalls: type) !void {
                    var vm = try compile(alloc, binary, Syscalls);
                    try vm.run();
                }
            };
        },
        else => return Interpreter,
    }
}
