// This project is a JIT-compiler for Soil binaries. Upon start, it parses the binary and compiles
// the byte code into x86_64 machine code instructions. It then jumps to those instructions. That
// causes the CPU hardware to directly execute the (translated) code written in Soil, without the
// overhead of an interpreter.

const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const rl = @import("raylib");
const Instant = std.time.Instant;
const soil = @import("root.zig");
const Syscall = soil.Syscall;
const Vm = soil.Vm;

pub const vm_options = .{
    .trace_calls = false,
    .trace_registers = false,
    .memory_size = 2000000000,
    .use_interpreter_override = false,
};
const trace_syscalls = false;
const ui_options = .{
    .size = .{ .width = 720, .height = 360 },
    .scale = 2.0,
};

pub const std_options = .{ .log_scope_levels = &[_]std.log.ScopeLevel{
    .{ .scope = .syscall, .level = if (trace_syscalls) .info else .warn },
} };
const syscall_log = std.log.scoped(.syscall);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    try init_program_start_instant();
    try init_process_args(alloc);

    var args = std.process.args();
    _ = args.next() orelse return error.NoProgramName;
    const binary_path = args.next() orelse return error.NoSoilBinary;
    var rest = ArrayList([]const u8).init(alloc);
    while (args.next()) |arg| try rest.append(arg);

    const binary = try std.fs.cwd().readFileAlloc(alloc, binary_path, 1000000000);
    try soil.run(binary, alloc, Syscalls);
}

var program_start_instant: ?Instant = undefined;
fn init_program_start_instant() !void {
    program_start_instant = try Instant.now();
}

var process_args: ArrayList([]const u8) = undefined;
fn init_process_args(alloc: Alloc) !void {
    process_args = ArrayList([]const u8).init(alloc);
    var args_iter = std.process.args();
    _ = args_iter.skip(); // Skip the first arg, which is just the soil invocation.
    while (true) {
        try process_args.append(args_iter.next() orelse break);
    }
}

var ui_inited = false;
fn init_ui() void {
    if (ui_inited) return;
    ui_inited = true;
    rl.initWindow(
        ui_options.size.width * ui_options.scale,
        ui_options.size.height * ui_options.scale,
        "Soil VM",
    );
    rl.setTargetFPS(60);
}

const Syscalls = struct {
    pub fn not_implemented(_: *Vm) callconv(.C) Syscall.ZeroValues {
        std.debug.print("Syscall not implemented", .{});
        std.process.exit(1);
    }

    pub fn exit(_: *Vm, status: i64) callconv(.C) Syscall.ZeroValues {
        syscall_log.info("exit({})\n", .{status});
        if (ui_inited)
            rl.closeWindow();
        std.process.exit(@intCast(status));
    }

    pub fn print(vm: *Vm, msg_data: i64, msg_len: i64) callconv(.C) Syscall.ZeroValues {
        syscall_log.info("print({x}, {})", .{ msg_data, msg_len });
        const msg = vm.memory[@intCast(msg_data)..][0..@intCast(msg_len)];
        std.io.getStdOut().writer().print("{s}", .{msg}) catch {};
    }

    pub fn log(vm: *Vm, msg_data: i64, msg_len: i64) callconv(.C) Syscall.ZeroValues {
        syscall_log.info("log({x}, {})", .{ msg_data, msg_len });
        const msg = vm.memory[@intCast(msg_data)..][0..@intCast(msg_len)];
        std.io.getStdErr().writer().print("{s}", .{msg}) catch {};
    }

    pub fn create(vm: *Vm, filename_data: i64, filename_len: i64, mode: i64) callconv(.C) Syscall.OneValue {
        syscall_log.info("create({x}, {}, {o})", .{ filename_data, filename_len, mode });
        const filename = vm.memory[@intCast(filename_data)..][0..@intCast(filename_len)];
        const flags = .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true };
        const fd = std.os.linux.open(&(toCPath(filename) catch unreachable), flags, @intCast(mode));
        return @bitCast(fd);
    }

    pub fn open_reading(vm: *Vm, filename_data: i64, filename_len: i64) callconv(.C) Syscall.OneValue {
        syscall_log.info("open_reading({x}, {})", .{ filename_data, filename_len });
        const filename = vm.memory[@intCast(filename_data)..][0..@intCast(filename_len)];
        const flags = .{ .ACCMODE = .RDONLY };
        const fd = std.os.linux.open(&(toCPath(filename) catch unreachable), flags, 0);
        return @bitCast(fd);
    }

    pub fn open_writing(vm: *Vm, filename_data: i64, filename_len: i64) callconv(.C) Syscall.OneValue {
        syscall_log.info("open_writing({x}, {})", .{ filename_data, filename_len });
        const filename = vm.memory[@intCast(filename_data)..][0..@intCast(filename_len)];
        const flags = .{ .ACCMODE = .WRONLY, .TRUNC = true, .CREAT = true };
        const fd = std.os.linux.open(&(toCPath(filename) catch unreachable), flags, 0o666);
        return @bitCast(fd);
    }

    pub fn read(vm: *Vm, file_descriptor: i64, buffer_data: i64, buffer_len: i64) callconv(.C) Syscall.OneValue {
        syscall_log.info("read({}, {x}, {})", .{ file_descriptor, buffer_data, buffer_len });
        const fd: i32 = @intCast(file_descriptor);
        const len = std.os.linux.read(fd, vm.memory[@intCast(buffer_data)..].ptr, @intCast(buffer_len));
        return @bitCast(len);
    }

    pub fn write(vm: *Vm, file_descriptor: i64, buffer_data: i64, buffer_len: i64) callconv(.C) Syscall.OneValue {
        syscall_log.info("write({}, {x}, {})", .{ file_descriptor, buffer_data, buffer_len });
        const fd: i32 = @intCast(file_descriptor);
        const len = std.os.linux.write(fd, vm.memory[@intCast(buffer_data)..].ptr, @intCast(buffer_len));
        return @bitCast(len);
    }

    pub fn close(_: *Vm, file_descriptor: i64) callconv(.C) Syscall.OneValue {
        syscall_log.info("close({})", .{file_descriptor});
        const fd: i32 = @intCast(file_descriptor);
        return @bitCast(std.os.linux.close(fd));
    }

    pub fn argc(_: *Vm) callconv(.C) Syscall.OneValue {
        syscall_log.info("argc()\n", .{});
        return @intCast(process_args.items.len);
    }

    pub fn arg(vm: *Vm, index: i64, buffer_data: i64, buffer_len: i64) callconv(.C) Syscall.OneValue {
        syscall_log.info("arg({}, {x}, {})", .{ index, buffer_data, buffer_len });
        const unsigned_index: usize = @intCast(index);
        const the_arg = process_args.items[unsigned_index];
        const unsigned_buffer_len: usize = @intCast(buffer_len);
        const len: usize = @min(unsigned_buffer_len, the_arg.len);
        @memcpy(vm.memory[@intCast(buffer_data)..][0..len], the_arg[0..len]);
        return @intCast(len);
    }

    pub fn read_input(vm: *Vm, buffer_data: i64, buffer_len: i64) callconv(.C) Syscall.OneValue {
        syscall_log.info("read_input({x}, {})", .{ buffer_data, buffer_len });
        const len = std.io.getStdIn().reader().read(vm.memory[@intCast(buffer_data)..][0..@intCast(buffer_len)]) catch {
            std.log.err("Couldn't read from input.\n", .{});
            std.process.exit(1);
        };
        return @intCast(len);
    }

    pub fn execute(vm: *Vm, binary_data: i64, binary_len: i64) callconv(.C) Syscall.ZeroValues {
        syscall_log.info("execute({x}, {})", .{ binary_data, binary_len });

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const alloc = gpa.allocator();
        const binary = vm.memory[@intCast(binary_data)..][0..@intCast(binary_len)];
        soil.run(binary, alloc, Syscalls) catch |err| {
            std.log.err("Run failed: {}\n", .{err});
            std.process.exit(1);
        };
    }

    pub fn ui_dimensions(_: *Vm) callconv(.C) Syscall.TwoValues {
        syscall_log.info("ui_dimensions()", .{});
        init_ui();
        return .{ .a = ui_options.size.width, .b = ui_options.size.height };
    }

    pub fn ui_render(vm: *Vm, buffer_data: i64, buffer_width: i64, buffer_height: i64) callconv(.C) Syscall.ZeroValues {
        syscall_log.info("ui_render({}, {}, {})", .{ buffer_data, buffer_width, buffer_height });
        init_ui();

        const data: usize = @intCast(buffer_data);
        const width: usize = @intCast(buffer_width);
        const height: usize = @intCast(buffer_height);

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.white);

        var image = rl.Image.genColor(ui_options.size.width, ui_options.size.height, rl.Color.black);
        for (0..width) |x| {
            for (0..height) |y| {
                const r = vm.memory[data + 3 * (y * width + x) + 0];
                const g = vm.memory[data + 3 * (y * width + x) + 1];
                const b = vm.memory[data + 3 * (y * width + x) + 2];
                rl.imageDrawPixel(&image, @intCast(x), @intCast(y), .{ .r = r, .g = g, .b = b, .a = 255 });
            }
        }
        const texture = rl.loadTextureFromImage(image);
        rl.drawTextureEx(texture, .{ .x = 0, .y = 0 }, 0, ui_options.scale, rl.Color.white);
    }

    pub fn get_key_pressed(_: *Vm) callconv(.C) Syscall.OneValue {
        syscall_log.info("get_key_pressed()", .{});
        init_ui();

        return @intFromEnum(rl.getKeyPressed());
    }

    pub fn instant_now(_: *Vm) callconv(.C) Syscall.OneValue {
        syscall_log.info("instant_now()", .{});

        const now = Instant.now() catch |e| {
            std.log.err("Couldn't get instant: {}\n", .{e});
            std.process.exit(1);
        };
        const nanos_since_start = Instant.since(now, program_start_instant.?);
        return @intCast(nanos_since_start);
    }

    pub fn read_dir(vm: *Vm, dir_path_data: i64, dir_path_len: i64, out_data: i64, out_len: i64) callconv(.C) Syscall.OneValue {
        syscall_log.info("read_dir({}, {}, {}, {})", .{ dir_path_data, dir_path_len, out_data, out_len });

        const dir_path = vm.memory[@intCast(dir_path_data)..][0..@intCast(dir_path_len)];
        const dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return -1;

        var cursor: usize = @intCast(out_data);
        var it = dir.iterate();
        while (it.next() catch return -2) |entry| {
            const kind_byte: u8 = switch (entry.kind) {
                .file => 1,
                .directory => 2,
                else => 0,
            };
            vm.memory[cursor] = kind_byte;
            cursor += 1;
            std.mem.writeInt(i64, vm.memory[cursor..][0..8], @intCast(entry.name.len), .little);
            cursor += 8;
            std.mem.copyForwards(u8, vm.memory[cursor..entry.name.len], entry.name); // forwards or backwards doesn't matter if slices don't overlap
            cursor += entry.name.len;
        }
        return @as(i64, @intCast(cursor)) - out_data;
    }
};

const PATH_MAX = std.os.linux.PATH_MAX;
pub fn toCPath(str: []const u8) ![PATH_MAX:0]u8 {
    var with_null: [PATH_MAX:0]u8 = undefined;
    @memcpy(with_null[0..str.len], str);
    with_null[str.len] = 0;
    return with_null;
}
