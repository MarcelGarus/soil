// .soil files contain the byte code, initial memory, debug information, etc.
// Here, we parse the binary into program. In particular, we compile the byte
// code into x86_64 machine code.
//
// In the generated code, Soil registers are mapped to x86_64 registers:
//
// Soil | x86_64
// -----|-------
// sp   | r8
// st   | r9
// a    | r10
// b    | r11
// c    | r12
// d    | r13
// e    | r14
// f    | r15
//      | rbp: Base address of the memory.
//
// While parsing sections, we always keep the following information in registers:
// - r8: cursor through the binary
// - r9: end of the binary

const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MachineCode = @import("machine_code.zig");
const Vm = @import("vm.zig");
const LabelAndOffset = Vm.LabelAndOffset;
const Reg = @import("reg.zig").Reg;

pub fn compile(alloc: Alloc, binary: []u8, syscalls: type) !Vm {
    var vm = Vm{
        .byte_code = &[_]u8{},
        .ip = 0,
        .regs = [_]u8{0} ** 8,
        .memory = try alloc.alloc(u8, Vm.memory_size),
        .call_stack = ArrayList(usize).init(alloc),
        .try_stack = ArrayList(Vm.TryScope).init(alloc),
        .labels = &[_]LabelAndOffset{},
    };

    var compiler = Compiler{
        .alloc = alloc,
        .input = binary,
        .cursor = 0,
    };
    if (try compiler.eat_byte() != 's') return error.MagicBytesMismatch;
    if (try compiler.eat_byte() != 'o') return error.MagicBytesMismatch;
    if (try compiler.eat_byte() != 'i') return error.MagicBytesMismatch;
    if (try compiler.eat_byte() != 'l') return error.MagicBytesMismatch;

    while (true) {
        const section_type = compiler.eat_byte() catch break;
        const section_len: usize = @intCast(try compiler.eat_word());
        switch (section_type) {
            0 => {
                const byte_code = compiler.input[compiler.cursor..][0..section_len];
                const compiled = try compiler.compile_byte_code(section_len, syscalls);
                vm.byte_code = byte_code;
                vm.machine_code = compiled.machine_code;
                vm.machine_code_ptr = compiled.machine_code.ptr;
                vm.byte_to_machine_code = compiled.byte_to_machine_code;
                vm.machine_to_byte_code = compiled.machine_to_byte_code;
            },
            1 => @memcpy(vm.memory[0..section_len], try compiler.eat_amount(section_len)),
            3 => vm.labels = try compiler.parse_labels(),
            else => compiler.cursor += section_len, // skip section
        }
    }

    return vm;
}

const Compiler = struct {
    alloc: Alloc,
    input: []u8,
    cursor: usize,

    pub fn eat_amount(self: *Compiler, amount: usize) ![]u8 {
        if (self.cursor >= self.input.len - amount + 1) return error.End;
        const consumed = self.input[self.cursor..(self.cursor + amount)];
        self.cursor += amount;
        return consumed;
    }
    pub fn eat_byte(self: *Compiler) !u8 {
        return (try self.eat_amount(1))[0];
    }
    pub fn eat_word(self: *Compiler) !i64 {
        return std.mem.readInt(i64, (try Compiler.eat_amount(self, 8))[0..8], .little);
    }

    fn parse_labels(self: *Compiler) ![]LabelAndOffset {
        const count: usize = @intCast(try self.eat_word());
        var labels_to_offset = ArrayList(LabelAndOffset).init(self.alloc);
        for (0..count) |_| {
            const offset: usize = @intCast(try self.eat_word());
            const label_len: usize = @intCast(try self.eat_word());
            const label = try self.eat_amount(label_len);
            try labels_to_offset.append(.{ .offset = offset, .label = label });
        }
        return labels_to_offset.items;
    }

    fn compile_byte_code(self: *Compiler, len: usize, syscalls: type) !CompiledCode {
        const byte_code_base = self.cursor;
        const end = byte_code_base + len;

        var machine_code = try MachineCode.init(self.alloc);

        // Mappings between offsets.
        var byte_to_machine_code = ArrayList(usize).init(self.alloc);
        var machine_to_byte_code = ArrayList(usize).init(self.alloc);

        while (self.cursor < end) {
            const byte_code_offset = self.cursor - byte_code_base;
            const machine_code_offset = machine_code.len;

            try self.compile_instruction(&machine_code, syscalls);

            const byte_code_offset_after = self.cursor - byte_code_base;
            const machine_code_offset_after = machine_code.len;

            while (byte_to_machine_code.items.len < byte_code_offset_after)
                try byte_to_machine_code.append(machine_code_offset);
            while (machine_to_byte_code.items.len < machine_code_offset_after)
                try machine_to_byte_code.append(byte_code_offset);
        }

        for (machine_code.patches.items) |patch| {
            switch (patch.target) {
                .absolute => |ab| {
                    var target: i32 = @intCast(byte_to_machine_code.items[ab]);
                    target += @intCast(@intFromPtr(machine_code.buffer.ptr));
                    std.mem.writeInt(i32, machine_code.buffer[patch.where..][0..4], target, .little);
                },
                .relative => |rel| {
                    const base: i32 = @intCast(patch.where + 4); // relative to the end of the jump/call instruction
                    const target: i32 = @intCast(byte_to_machine_code.items[rel]);
                    const relative = target - base;
                    std.mem.writeInt(i32, machine_code.buffer[patch.where..][0..4], relative, .little);
                },
            }
        }

        return .{
            .machine_code = machine_code.buffer[0..machine_code.len],
            .byte_to_machine_code = byte_to_machine_code.items,
            .machine_to_byte_code = machine_to_byte_code.items,
        };
    }
};

fn equal(comptime T: type, a: []const T, b: []const T) bool {
    if (@sizeOf(T) == 0) return true;

    @compileLog("checking lens");
    if (a.len != b.len) return false;
    if (a.len == 0 or a.ptr == b.ptr) return true;

    @compileLog("checking items");
    for (a, b) |a_elem, b_elem| {
        if (a_elem != b_elem) {
            // std.debug.print(comptime fmt: []const u8, args: anytype);
            const astr = comptime blk: {
                var buf: [20]u8 = undefined;
                break :blk try intToString(a_elem, &buf);
            };
            const bstr = comptime blk: {
                var buf: [20]u8 = undefined;
                break :blk try intToString(b_elem, &buf);
            };
            @compileLog("not equal: " ++ astr ++ " and " ++ bstr);
            return false;
        } else {
            @compileLog("equal");
        }
    }
    return true;
}
fn intToString(comptime int: u32, comptime buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{}", .{int});
}

fn panic_vm(vm: *Vm, stack_pointer: *usize) void {
    std.debug.print("\nOh no! The program panicked.\n", .{});

    var i: usize = 0;
    while (true) : (i += 1) {
        const stack_entry: *usize = @ptrFromInt(@intFromPtr(stack_pointer) + 8 * i);
        if (stack_entry.* == 0) break;
        const size_of_call_instruction = 5;
        const machine_code_absolute = stack_entry.* - size_of_call_instruction;
        if (machine_code_absolute < @intFromPtr(vm.machine_code.ptr)) {
            std.debug.print("{x:10} <Zig code>", .{machine_code_absolute});
            continue;
        }
        const machine_code_offset = machine_code_absolute - @intFromPtr(vm.machine_code.ptr);
        const byte_code_offset = vm.machine_to_byte_code[machine_code_offset];
        const label = search_for_label(vm.labels, byte_code_offset) orelse "<no label>";
        std.debug.print("{x:10} {s}\n", .{ byte_code_offset, label });
    }
    std.process.exit(1);
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
