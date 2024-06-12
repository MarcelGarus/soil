// This project is a JIT-compiler for Soil binaries. Upon start, it parses the binary and compiles
// the byte code into x86_64 machine code instructions. It then jumps to those instructions. That
// causes the CPU hardware to directly execute the (translated) code written in Soil, without the
// overhead of an interpreter.

const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const compile = @import("compiler.zig").compile;
const MachineCode = @import("machine_code.zig");
const Program = @import("program.zig");
const Reg = @import("reg.zig").Reg;

pub fn load_binary(alloc: Alloc, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(alloc, path, 1000000000);
}

pub fn main() !void {
    std.debug.print("Soil VM.\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var args = std.process.args();
    _ = args.next() orelse return error.NoProgramName;
    const binary_path = args.next() orelse return error.NoSoilBinary;
    var rest = ArrayList([]const u8).init(alloc);
    while (args.next()) |arg| {
        try rest.append(arg);
    }

    const binary = try load_binary(alloc, binary_path);
    const program = try compile(alloc, binary, Syscalls);
    try program.run(alloc);
}

const Syscalls = struct {
    pub fn exit(status: usize) void {
        std.debug.print("syscall: exit\n", .{});
        _ = status;
    }
    pub fn print(msg_data: usize, msg_len: usize) void {
        std.debug.print("syscall: print\n", .{});
        _ = msg_data;
        _ = msg_len;
    }
    pub fn log(msg_data: usize, msg_len: usize) void {
        std.debug.print("syscall: log\n", .{});
        _ = msg_data;
        _ = msg_len;
    }
    pub fn create(filename_data: usize, filename_len: usize, mode: usize) usize {
        std.debug.print("syscall: create\n", .{});
        _ = filename_data;
        _ = filename_len;
        _ = mode;
    }
    pub fn open_reading(filename_data: usize, filename_len: usize, flags: usize, mode: usize) usize {
        std.debug.print("syscall: open_reading\n", .{});
        _ = filename_data;
        _ = filename_len;
        _ = flags;
        _ = mode;
    }
    pub fn open_writing(filename_data: usize, filename_len: usize, flags: usize, mode: usize) usize {
        std.debug.print("syscall: open_writing\n", .{});
        _ = filename_data;
        _ = filename_len;
        _ = flags;
        _ = mode;
    }
    pub fn read(file_descriptor: usize, buffer_data: usize, buffer_len: usize) usize {
        std.debug.print("syscall: read\n", .{});
        _ = file_descriptor;
        _ = buffer_data;
        _ = buffer_len;
    }
    pub fn write(file_descriptor: usize, buffer_data: usize, buffer_len: usize) usize {
        std.debug.print("syscall: write\n", .{});
        _ = file_descriptor;
        _ = buffer_data;
        _ = buffer_len;
    }
    pub fn close(file_descriptor: usize) usize {
        std.debug.print("syscall: close\n", .{});
        _ = file_descriptor;
    }
    pub fn argc() usize {
        std.debug.print("syscall: argc\n", .{});
    }
    pub fn arg(index: usize, buffer_data: usize, buffer_len: usize) usize {
        std.debug.print("syscall: arg\n", .{});
        _ = index;
        _ = buffer_data;
        _ = buffer_len;
    }
    pub fn read_input(buffer_data: usize, buffer_len: usize) usize {
        std.debug.print("syscall: read_input\n", .{});
        _ = buffer_data;
        _ = buffer_len;
    }
    pub fn execute(binary_data: usize, binary_len: usize) void {
        std.debug.print("syscall: execute\n", .{});
        _ = binary_data;
        _ = binary_len;
    }
    pub fn ui_dimensions() struct { usize, usize } {
        std.debug.print("syscall: ui_dimensions\n", .{});
    }
    pub fn ui_render(buffer_data: usize, buffer_width: usize, buffer_height: usize) void {
        std.debug.print("syscall: ui_render\n", .{});
        _ = buffer_data;
        _ = buffer_width;
        _ = buffer_height;
    }

    // .exit:
    //   mov rax, 60   ; exit syscall
    //   mov dil, r10b ; status code (from the a register)
    //   syscall

    // .print:
    //   push_syscall_clobbers
    //   mov rax, 1 ; write syscall
    //   mov rdi, 1 ; stdout
    //   lea rsi, [rbp + r10] ; pointer to string (from the a register)
    //   mov rdx, r11 ; length of the string (from the b register)
    //   syscall
    //   pop_syscall_clobbers
    //   ret

    // .log:
    //   push_syscall_clobbers
    //   mov rax, 1 ; write syscall
    //   mov rdi, 2 ; stderr
    //   lea rsi, [rbp + r10] ; pointer to message (from the a register)
    //   mov rdx, r11 ; length of the message (from the b register)
    //   syscall
    //   pop_syscall_clobbers
    //   ret

    // .create:
    //   ; make the filename null-terminated, saving the previous end byte in bl
    //   mov rcx, rbp
    //   add rcx, r10
    //   add rcx, r11
    //   mov bl, [rcx]
    //   mov [rcx], byte 0
    //   push_syscall_clobbers
    //   mov rax, 2            ; open syscall
    //   lea rdi, [r10 + rbp]  ; filename
    //   mov rsi, 01102o       ; flags: RDWR|CREAT|TRUNC
    //   mov rdx, 0777o        ; mode: everyone has access for rwx
    //   syscall
    //   mov r10, rax
    //   pop_syscall_clobbers
    //   mov [rcx], bl ; restore end replaced by null-byte
    //   ret

    // .open_reading:
    //   ; make the filename null-terminated, saving the previous end byte in bl
    //   mov rcx, rbp
    //   add rcx, r10
    //   add rcx, r11
    //   mov bl, [rcx]
    //   mov [rcx], byte 0
    //   push_syscall_clobbers
    //   mov rax, 2            ; open syscall
    //   lea rdi, [r10 + rbp]  ; filename
    //   mov rsi, 0            ; flags: RDONLY
    //   mov rdx, 0            ; mode: ignored anyways because we don't create a file
    //   syscall
    //   mov r10, rax
    //   pop_syscall_clobbers
    //   mov [rcx], bl ; restore end replaced by null-byte
    //   ret

    // .open_writing:
    //   ; make the filename null-terminated, saving the previous end byte in bl
    //   mov rcx, rbp
    //   add rcx, r10
    //   add rcx, r11
    //   mov bl, [rcx]
    //   mov [rcx], byte 0
    //   push_syscall_clobbers
    //   mov rax, 2            ; open syscall
    //   lea rdi, [r10 + rbp]  ; filename
    //   mov rsi, 1101o        ; flags: RDWR | CREAT | TRUNC
    //   mov rdx, 664o         ; rw-rw-r--
    //   syscall
    //   mov r10, rax
    //   pop_syscall_clobbers
    //   mov [rcx], bl ; restore end replaced by null-byte
    //   ret

    // .read:
    //   push_syscall_clobbers
    //   mov rax, 0            ; read
    //   mov rdi, r10          ; file descriptor
    //   lea rsi, [r11 + rbp]  ; buffer.data
    //   mov rdx, r12          ; buffer.len
    //   syscall
    //   mov r10, rax
    //   pop_syscall_clobbers
    //   ret

    // .write:
    //   push_syscall_clobbers
    //   mov rax, 1            ; write
    //   mov rdi, r10          ; file descriptor
    //   lea rsi, [r11 + rbp]  ; buffer.data
    //   mov rdx, r12          ; buffer.len
    //   syscall
    //   mov r10, rax
    //   pop_syscall_clobbers
    //   ret

    // .close:
    //   push_syscall_clobbers
    //   mov rax, 3 ; close
    //   mov rdi, r10 ; file descriptor
    //   syscall
    //   ; TODO: assert that this worked
    //   pop_syscall_clobbers
    //   ret

    // .argc:
    //   mov r10, [saved_argc]
    //   dec r10
    //   ret

    // .arg:
    //   ; jmp .arg
    //   ; TODO: check that the index is valid
    //   ; mov rax, [saved_argc]
    //   ; cmp r10, rax
    //   ; jge .invalid_stuff
    //   mov rax, r10
    //   cmp rax, 0
    //   je .load_arg
    //   inc rax
    // .load_arg:
    //   ; base pointer of the string given to us by the OS
    //   imul rax, 8
    //   add rax, [saved_argv]
    //   mov rax, [rax]
    //   ; index
    //   mov rcx, 0
    //   ; TODO: check that the buffer is completely in the VM memory
    // .copy_arg_loop:
    //   cmp rcx, r12 ; we filled the entire buffer
    //   je .done_copying_arg
    //   mov rsi, rax
    //   add rsi, rcx
    //   mov dl, [rsi]
    //   cmp dl, 0 ; we reached the end of the string (terminating null-byte)
    //   je .done_copying_arg
    //   mov rdi, r11
    //   add rdi, rbp
    //   add rdi, rcx
    //   mov [rdi], dl
    //   inc rcx
    //   jmp .copy_arg_loop
    // .done_copying_arg:
    //   ; jmp .done_copying_arg
    //   mov r10, rcx
    //   ret

    // .read_input:
    //   push_syscall_clobbers
    //   mov rax, 0            ; read
    //   mov rdi, 0            ; stdin
    //   lea rsi, [r10 + rbp]  ; buffer.data
    //   mov rdx, r11          ; buffer.len
    //   syscall
    //   mov r10, rax
    //   pop_syscall_clobbers
    //   ret

    // .execute:
    //   ; jmp .execute
    //   mov rax, r11 ; binary.len
    //   call malloc
    //   mov [binary], rax
    //   mov [binary.len], r11
    //   add r10, rbp
    // .copy_binary:
    //   cmp r11, 0
    //   je .clear_stack
    //   mov bl, [r10]
    //   mov [rax], bl
    //   inc r10
    //   inc rax
    //   dec r11
    //   jmp .copy_binary
    // .clear_stack:
    //   pop rax
    //   cmp rax, label_after_call_to_jit
    //   je .done_clearing_the_stack
    //   jmp .clear_stack
    // .done_clearing_the_stack:
    //   call compile_binary
    //   jmp run
};
