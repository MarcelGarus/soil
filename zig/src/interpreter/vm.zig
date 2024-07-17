const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const memory_size = 2000000000;

byte_code: []u8,
ip: usize,
regs: [8]i64,
memory: []u8,
call_stack: ArrayList(usize),
try_stack: ArrayList(TryScope),
labels: []LabelAndOffset,

pub const REG_SP = 0;
pub const REG_ST = 1;
pub const REG_A = 2;
pub const REG_B = 3;
pub const REG_C = 4;
pub const REG_D = 5;
pub const REG_E = 6;
pub const REG_F = 7;

pub const TryScope = packed struct {
    rsp: usize,
    sp: usize,
    catch_: usize, // machine code offset
};

pub const LabelAndOffset = struct { label: []u8, offset: usize };

pub fn run(vm: *@This()) !void {
    while (true) {
        vm.run_single();
    }
    std.process.exit(0);
}

fn eat_byte(vm: *This) u8 {
    const byte = vm.byte_code[vm.ip];
    vm.ip += 1;
    return byte;
}
fn eat_word(vm: *This) u8 {
    const word = std.mem.readInt(i64, vm.byte_code[vm.ip..][0..8], .little);
    vm.ip += 8;
    return word;
}
fn eat_regs(vm: *This) struct { a: u8, b: u8 } {
    const byte = vm.eat_byte();
    return .{ .a = byte & 0xf, .b = byte >> 4 };
}
fn eat_reg(vm: *This) u8 {
    return vm.eat_regs().a;
}

fn run_single(vm: *@This()) !void {
    var opcode = vm.eat_byte();
    switch (opcode) {
        0x00 => {}, // nop
    0xe0 => { // panic
      if (vm.try_stack.items.len > 0) {
        const try_ = vm.try_stack.pop();
        vm.call_stack.items.len = try_.call_stack_len;
        vm.ip = try_.catch_;
      } else {
        dump_and_panic("panicked"); return;
      }
    },
    0xe1 => { // trystart
        const catch_ = vm.eat_word();
        try vm.try_stack.append(.{
            .catch_ = catch_,
            .call_stack_len = vm.call_stack.len,
            .sp = vm.regs[REG_SP],
        });
    },
    0xe2 => vm.try_stack.pop(), // tryend
    0xd0 => { // move
        const regs = vm.eat_regs();
        vm.regs[regs.a] = vm.regs[regs.b];
    },
    0xd1 => { // movei
        const reg = vm.eat_reg();
        vm.regs[reg] = @intCast(vm.eat_word());
    },
    0xd2 => { // moveib
        const reg = vm.eat_reg();
        vm.regs[reg] = @intCast(vm.eat_byte());
    },
    0xd3 => { // load
        const regs = vm.eat_regs();
        if (regs.b >= memory_size) dump_and_panic("invalid load");
        vm.regs[regs.a] = std.mem.readInt(i64, vm.memory[vm.regs[regs.b]..][0..8], .little);
    },
    0xd4 => { // loadb
        const regs = vm.eat_regs();
        if (regs.b >= memory_size) dump_and_panic("invalid load");
        vm.regs[regs.a] = @intCast(vm.memory[vm.regs[regs.b]..][0..8]);
    },
    0xd5 => { // store
      if (REG1 >= MEMORY_SIZE) dump_and_panic("invalid store");
      if (REG1 == 0x4b40) dump_and_panic("writing to needle\n");
      *(Word*)(mem + REG1) = REG2; ip += 2; break;
    }
    0xd6 => { // storeb
      if (REG1 >= MEMORY_SIZE) dump_and_panic("invalid storeb");
      if (REG1 >= 0x4b40 && REG1 < 0x4b48) dump_and_panic("writing to needle\n");
      mem[REG1] = REG2; ip += 2; break;
    }
    0xd7 => SP -= 8; *(Word*)(mem + SP) = REG1; ip += 2; break; // push
    0xd8 => REG1 = *(Word*)(mem + SP); SP += 8; ip += 2; break; // pop
    0xf0 => ip = *(Word*)(byte_code + ip + 1); break; // jump
    0xf1 => { // cjump
      if (ST != 0) ip = *(Word*)(byte_code + ip + 1); else ip += 9; break;
    }
    0xf2 => { // call
      if (TRACE_CALLS) {
        for (int i = 0; i < call_stack_len; i++)
          eprintf(" ");
        LabelAndPos lap = find_label(*(Word*)(byte_code + ip + 1));
        for (int i = 0; i < lap.len; i++) eprintf("%c", lap.label[i]);
        if (TRACE_CALL_ARGS) {
          for (int i = call_stack_len + lap.len; i < 50; i++) eprintf(" ");
          for (int i = SP; i < MEMORY_SIZE && i < SP + 40; i++) {
            if (i % 8 == 0) eprintf(" |");
            eprintf(" %02x", mem[i]);
          }
        }
        eprintf("\n");
      }

      Word return_target = ip + 9;
      call_stack[call_stack_len] = return_target; call_stack_len++;
      ip = *(Word*)(byte_code + ip + 1); break;
    }
    0xf3 => { // ret
      call_stack_len--;
      ip = call_stack[call_stack_len];
      break;
    }
    0xf4 => ip += 2; syscall_handlers[byte_code[ip - 1]](); break; // syscall
    0xc0 => ST = REG1 - REG2; ip += 2; break; // cmp
    0xc1 => ST = ST == 0 ? 1 : 0; ip += 1; break; // isequal
    0xc2 => ST = ST < 0 ? 1 : 0; ip += 1; break; // isless
    0xc3 => ST = ST > 0 ? 1 : 0; ip += 1; break; // isgreater
    0xc4 => ST = ST <= 0 ? 1 : 0; ip += 1; break; // islessequal
    0xc5 => ST = ST >= 0 ? 1 : 0; ip += 1; break; // isgreaterequal
    0xc6 => ST = ST != 0 ? 1 : 0; ip += 1; break; // isnotequal
    0xc7 => { // fcmp
      fi fi1 = {.i = REG1};
      fi fi2 = {.i = REG2};
      fi res = {.f = fi1.f - fi2.f};
      ST = res.i; ip += 2; break;
    }
    0xc8 => { // fisequal
      fi fi = {.i = ST};
      ST = fi.f == 0.0 ? 1 : 0; ip += 1; break;
    }
    0xc9 => { // fisless
      fi fi = {.i = ST};
      ST = fi.f < 0.0 ? 1 : 0; ip += 1; break;
    }
    0xca => { // fisgreater
      fi fi = {.i = ST};
      ST = fi.f > 0.0 ? 1 : 0; ip += 1; break;
    }
    0xcb => { // fislessqual
      fi fi = {.i = ST};
      ST = fi.f <= 0.0 ? 1 : 0; ip += 1; break;
    }
    0xcc => { // fisgreaterequal
      fi fi = {.i = ST};
      ST = fi.f >= 0.0 ? 1 : 0; ip += 1; break;
    }
    0xcd => { // fisnotequal
      fi fi = {.i = ST};
      ST = fi.f != 0.0 ? 1 : 0; ip += 1; break;
    }
    0xce => { // inttofloat
      fi fi = {.f = (double)REG1};
      REG1 = fi.i; ip += 2; break;
    }
    0xcf => { // floattoint
      fi fi = {.i = REG1};
      REG1 = (int64_t)fi.f; ip += 2; break;
    }
    0xa0 => REG1 += REG2; ip += 2; break; // add
    0xa1 => REG1 -= REG2; ip += 2; break; // sub
    0xa2 => REG1 *= REG2; ip += 2; break; // mul
    0xa3 => {                             // div
      if (REG2 == 0) dump_and_panic("div by zero");
      REG1 /= REG2; ip += 2; break;
    }
    0xa4 => { // rem
      if (REG2 == 0) dump_and_panic("rem by zero");
      REG1 %= REG2; ip += 2; break;
    }
    0xa5 => {  // fadd
      fi fi1 = {.i = REG1};
      fi fi2 = {.i = REG2};
      fi res = {.f = fi1.f + fi2.f};
      REG1 = res.i; ip += 2; break;
    }
    0xa6 => {  // fsub
      fi fi1 = {.i = REG1};
      fi fi2 = {.i = REG2};
      fi res = {.f = fi1.f - fi2.f};
      REG1 = res.i; ip += 2; break;
    }
    0xa7 => {  // fmul
      fi fi1 = {.i = REG1};
      fi fi2 = {.i = REG2};
      fi res = {.f = fi1.f * fi2.f};
      REG1 = res.i; ip += 2; break;
    }
    0xa8 => {  // fdiv
      fi fi1 = {.i = REG1};
      fi fi2 = {.i = REG2};
      if (fi2.f == 0.0) dump_and_panic("fdiv by zero");
      fi res = {.f = fi1.f / fi2.f};
      REG1 = res.i; ip += 2; break;
    }
    0xb0 => REG1 &= REG2; ip += 2; break; // and
    0xb1 => REG1 |= REG2; ip += 2; break; // or
    0xb2 => REG1 ^= REG2; ip += 2; break; // xor
    0xb3 => REG1 = ~REG1; ip += 2; break; // not
    default: dump_and_panic("invalid instruction %dx", opcode); return;
    }
}
