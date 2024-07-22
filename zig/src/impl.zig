const builtin = @import("builtin");
const std = @import("std");
const Alloc = std.mem.Allocator;
const File = @import("file.zig");
const options = @import("root").vm_options;

pub const Vm = Impl().Vm;
pub const run = Impl().run;

fn Impl() type {
    const Interpreter = struct {
        const TheVm = @import("interpreter/vm.zig");
        const Vm = TheVm;
        fn run(alloc: Alloc, file: File, Syscalls: type) !void {
            var vm = try TheVm.init(alloc, file);
            try vm.run(Syscalls);
        }
    };

    if (options.use_interpreter_override or options.trace_calls or options.trace_registers)
        return Interpreter;

    switch (builtin.cpu.arch) {
        .x86_64 => {
            const compile = @import("x86_64/compiler.zig").compile;
            return struct {
                const Vm = @import("x86_64/vm.zig");
                fn run(alloc: Alloc, file: File, Syscalls: type) !void {
                    var vm = try compile(alloc, file, Syscalls);
                    try vm.run();
                }
            };
        },
        else => return Interpreter,
    }
}
