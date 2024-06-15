const std = @import("std");
const Alloc = std.mem.Allocator;

const memory_size = 100000000;

initial_memory: []u8,
machine_code: []align(std.mem.page_size) u8,

pub const LabelAndOffset = struct { label: []u8, offset: usize };

pub const Vm = struct {
    memory: []u8,
};

pub fn run(program: @This(), alloc: Alloc) !void {
    if (program.initial_memory.len > memory_size) return error.MemoryTooSmall;
    var vm = Vm{ .memory = try alloc.alloc(u8, memory_size + 1) };
    @memcpy(vm.memory[0..program.initial_memory.len], program.initial_memory);

    const PROT = std.os.linux.PROT;
    const protection = PROT.READ | PROT.EXEC;
    std.debug.assert(std.os.linux.mprotect(@ptrCast(program.machine_code), program.machine_code.len, protection) == 0);

    // std.debug.print("memory size: {x}\n", .{memory_size});
    // std.debug.print("Vm: {x}\n", .{@intFromPtr(&vm)});
    // std.debug.print("Machine code: {x}\n", .{@intFromPtr(program.machine_code.ptr)});
    // std.debug.print("Mem base: {x}\n", .{@intFromPtr(vm.memory.ptr)});
    std.debug.print("Running compiled machine code.\n", .{});
    actual_run(program, &vm);
}
fn actual_run(program: @This(), vm: *Vm) void {
    const vm_ptr = @intFromPtr(vm);
    const mem_size = memory_size;
    const mem_base = @intFromPtr(vm.memory.ptr);
    const machine_code = @intFromPtr(program.machine_code.ptr);
    asm volatile (
        \\ mov $0, %%r9
        \\ mov $0, %%r10
        \\ mov $0, %%r11
        \\ mov $0, %%r12
        \\ mov $0, %%r13
        \\ mov $0, %%r14
        \\ mov $0, %%r15
        \\ push %%r9
        \\ call *%%rax
        :
        : [machine_code] "{rax}" (machine_code),
          [mem_size] "{r8}" (mem_size),
          [mem_base] "{rbp}" (mem_base),
          [vm_ptr] "{rbx}" (vm_ptr),
        : "memory", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rcx", "rsi", "rdi"
    );
}
