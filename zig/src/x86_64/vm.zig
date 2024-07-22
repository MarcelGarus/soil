const std = @import("std");
const Alloc = std.mem.Allocator;
const File = @import("../file.zig");
const options = @import("root").vm_options;

byte_code: []const u8,
machine_code: []align(std.mem.page_size) u8,
machine_code_ptr: [*]u8,
byte_to_machine_code: []usize,
machine_to_byte_code: []usize,
memory: []u8,
labels: File.Labels,
try_stack: []TryScope,
try_stack_len: usize,

pub const TryScope = packed struct {
    rsp: usize,
    sp: usize,
    catch_: usize, // machine code offset
};

pub const LabelAndOffset = struct { label: []u8, offset: usize };

pub fn run(vm: *@This()) !void {
    const PROT = std.os.linux.PROT;
    const protection = PROT.READ | PROT.EXEC;
    std.debug.assert(std.os.linux.mprotect(@ptrCast(vm.machine_code), vm.machine_code.len, protection) == 0);
    actual_run(vm);
}
fn actual_run(vm: *@This()) void {
    const vm_ptr = @intFromPtr(vm);
    const mem_size = options.memory_size;
    const mem_base = @intFromPtr(vm.memory.ptr);
    const machine_code = @intFromPtr(vm.machine_code.ptr);
    asm volatile (
        \\ mov $0, %%r9
        \\ mov $0, %%r10
        \\ mov $0, %%r11
        \\ mov $0, %%r12
        \\ mov $0, %%r13
        \\ mov $0, %%r14
        \\ mov $0, %%r15
        \\ push %%r9
        \\ jmp *%%rax
        :
        : [machine_code] "{rax}" (machine_code),
          [mem_size] "{r8}" (mem_size),
          [mem_base] "{rbp}" (mem_base),
          [vm_ptr] "{rbx}" (vm_ptr),
        : "memory", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rcx", "rsi", "rdi"
    );
    std.process.exit(0);
}
