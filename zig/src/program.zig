const std = @import("std");
const Alloc = std.mem.Allocator;

const memory_size = 1000000000;

initial_memory: []u8,
machine_code: []align(std.mem.page_size) u8,

pub const LabelAndOffset = struct { label: []u8, offset: usize };

pub fn run(program: @This(), alloc: Alloc) !void {
    if (program.initial_memory.len > memory_size) return error.MemoryTooSmall;
    const memory = try alloc.alloc(u8, memory_size + 1);
    @memcpy(memory[0..program.initial_memory.len], program.initial_memory);

    const PROT = std.os.linux.PROT;
    const protection = PROT.READ | PROT.EXEC;
    std.debug.assert(std.os.linux.mprotect(@ptrCast(program.machine_code), program.machine_code.len, protection) == 0);

    std.debug.print("Machine code is at {x}.\n", .{program.machine_code});

    const mem_size = memory_size;
    const mem_base = program.initial_memory;
    const machine_code = program.machine_code;
    asm volatile (
        \\ mov $0, %%r9
        \\ mov $0, %%r10
        \\ mov $0, %%r11
        \\ mov $0, %%r12
        \\ mov $0, %%r13
        \\ mov $0, %%r14
        \\ mov $0, %%r15
        \\ call *%%rax
        : [ret] "=rax" (-> void),
        : [mem_size] "r8" (mem_size),
          [mem_base] "rbp" (mem_base),
          [machine_code] "rax" (machine_code),
        : "memory", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rax", "rbx", "rcx", "rdx", "rsi", "rdi"
    );
    //   ; When we dump the stack at a panic, we know we reached to root of the VM
    //   ; calls when we see this label on the call stack.
    //   label_after_call_to_jit:
    //   exit 0
}
