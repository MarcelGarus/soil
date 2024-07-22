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
const Vm = @import("vm.zig");
const LabelAndOffset = Vm.LabelAndOffset;

pub fn compile(alloc: Alloc, binary: []u8) !Vm {
    var vm = Vm{
        .byte_code = &[_]u8{},
        .ip = 0,
        .regs = [_]i64{0} ** 8,
        .memory = try alloc.alloc(u8, Vm.memory_size),
        .call_stack = ArrayList(usize).init(alloc),
        .try_stack = ArrayList(Vm.TryScope).init(alloc),
        .labels = &[_]LabelAndOffset{},
    };
    vm.set_int(.sp, Vm.memory_size);

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
            0 => vm.byte_code = try compiler.eat_amount(section_len),
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
};

fn intToString(comptime int: u32, comptime buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{}", .{int});
}

fn panic_vm(vm: *Vm) void {
    std.debug.print("\nOh no! The program panicked.\n", .{});

    for (vm.call_stack) |stack_entry| {
        const size_of_call_instruction = 5;
        const byte_code_offset = stack_entry - size_of_call_instruction;
        const label = Vm.search_for_label(vm.labels, byte_code_offset) orelse "<no label>";
        std.debug.print("{x:10} {s}\n", .{ byte_code_offset, label });
    }
    std.process.exit(1);
}
