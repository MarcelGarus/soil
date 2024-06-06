import 'package:supernova/supernova.dart' hide Bytes;

import '../bytes.dart';

part 'instruction.freezed.dart';

@freezed
sealed class Instruction with _$Instruction {
  const factory Instruction.nop() = NopInstruction;
  const factory Instruction.panic() = PanicInstruction;
  const factory Instruction.move(Register to, Register from) = MoveInstruction;
  const factory Instruction.movei(Register to, Word value) = MoveiInstruction;
  const factory Instruction.moveib(Register to, Byte value) = MoveibInstruction;
  const factory Instruction.load(Register to, Register from) = LoadInstruction;
  const factory Instruction.loadb(Register to, Register from) =
      LoadbInstruction;
  const factory Instruction.store(Register to, Register from) =
      StoreInstruction;
  const factory Instruction.storeb(Register to, Register from) =
      StorebInstruction;
  const factory Instruction.push(Register reg) = PushInstruction;
  const factory Instruction.pop(Register reg) = PopInstruction;
  const factory Instruction.jump(Word to) = JumpInstruction;
  const factory Instruction.cjump(Word to) = CjumpInstruction;
  const factory Instruction.call(Word target) = CallInstruction;
  const factory Instruction.ret() = RetInstruction;
  const factory Instruction.syscall(Byte number) = SyscallInstruction;
  const factory Instruction.cmp(Register left, Register right) = CmpInstruction;
  const factory Instruction.isequal() = IsequalInstruction;
  const factory Instruction.isless() = IslessInstruction;
  const factory Instruction.isgreater() = IsgreaterInstruction;
  const factory Instruction.islessequal() = IslessequalInstruction;
  const factory Instruction.isgreaterequal() = IsgreaterequalInstruction;
  const factory Instruction.add(Register to, Register from) = AddInstruction;
  const factory Instruction.sub(Register to, Register from) = SubInstruction;
  const factory Instruction.mul(Register to, Register from) = MulInstruction;
  const factory Instruction.div(Register dividend, Register divisor) =
      DivInstruction;
  const factory Instruction.rem(Register dividend, Register divisor) =
      RemInstruction;
  const factory Instruction.and(Register to, Register from) = AndInstruction;
  const factory Instruction.or(Register to, Register from) = OrInstruction;
  const factory Instruction.xor(Register to, Register from) = XorInstruction;
  const factory Instruction.not(Register to) = NotInstruction;
  const Instruction._();

  static Result<Instruction, String> decode(Bytes byteCode, Word offset) {
    Register decodeRegister0() {
      final registerIndex = byteCode[offset + const Word(1)].value & 0x07;
      return Register.values[registerIndex];
    }

    Register decodeRegister1() {
      final registerIndex =
          (byteCode[offset + const Word(1)].value >> 4) & 0x07;
      return Register.values[registerIndex];
    }

    return switch (byteCode[offset]) {
      const Byte(0x00) => const Result.ok(Instruction.nop()),
      const Byte(0xe0) => const Result.ok(Instruction.panic()),
      const Byte(0xd0) =>
        Result.ok(Instruction.move(decodeRegister0(), decodeRegister1())),
      const Byte(0xd1) => Result.ok(
          Instruction.movei(
            decodeRegister0(),
            byteCode.getWord(offset + const Word(2)),
          ),
        ),
      const Byte(0xd2) => Result.ok(
          Instruction.moveib(
            decodeRegister0(),
            byteCode[offset + const Word(2)],
          ),
        ),
      const Byte(0xd3) =>
        Result.ok(Instruction.load(decodeRegister0(), decodeRegister1())),
      const Byte(0xd4) =>
        Result.ok(Instruction.loadb(decodeRegister0(), decodeRegister1())),
      const Byte(0xd5) =>
        Result.ok(Instruction.store(decodeRegister0(), decodeRegister1())),
      const Byte(0xd6) =>
        Result.ok(Instruction.storeb(decodeRegister0(), decodeRegister1())),
      const Byte(0xd7) => Result.ok(Instruction.push(decodeRegister0())),
      const Byte(0xd8) => Result.ok(Instruction.pop(decodeRegister0())),
      const Byte(0xf0) =>
        Result.ok(Instruction.jump(byteCode.getWord(offset + const Word(1)))),
      const Byte(0xf1) =>
        Result.ok(Instruction.cjump(byteCode.getWord(offset + const Word(1)))),
      const Byte(0xf2) =>
        Result.ok(Instruction.call(byteCode.getWord(offset + const Word(1)))),
      const Byte(0xf3) => const Result.ok(Instruction.ret()),
      const Byte(0xf4) =>
        Result.ok(Instruction.syscall(byteCode[offset + const Word(1)])),
      const Byte(0xc0) =>
        Result.ok(Instruction.cmp(decodeRegister0(), decodeRegister1())),
      const Byte(0xc1) => const Result.ok(Instruction.isequal()),
      const Byte(0xc2) => const Result.ok(Instruction.isless()),
      const Byte(0xc3) => const Result.ok(Instruction.isgreater()),
      const Byte(0xc4) => const Result.ok(Instruction.islessequal()),
      const Byte(0xc5) => const Result.ok(Instruction.isgreaterequal()),
      const Byte(0xa0) =>
        Result.ok(Instruction.add(decodeRegister0(), decodeRegister1())),
      const Byte(0xa1) =>
        Result.ok(Instruction.sub(decodeRegister0(), decodeRegister1())),
      const Byte(0xa2) =>
        Result.ok(Instruction.mul(decodeRegister0(), decodeRegister1())),
      const Byte(0xa3) =>
        Result.ok(Instruction.div(decodeRegister0(), decodeRegister1())),
      const Byte(0xa4) =>
        Result.ok(Instruction.rem(decodeRegister0(), decodeRegister1())),
      const Byte(0xb0) =>
        Result.ok(Instruction.and(decodeRegister0(), decodeRegister1())),
      const Byte(0xb1) =>
        Result.ok(Instruction.or(decodeRegister0(), decodeRegister1())),
      const Byte(0xb2) =>
        Result.ok(Instruction.xor(decodeRegister0(), decodeRegister1())),
      const Byte(0xb3) => Result.ok(Instruction.not(decodeRegister0())),
      // ignore: pattern_never_matches_value_type
      final opcode =>
        Result.err('Unknown opcode at ${offset.format()}: ${opcode.format()}'),
    };
  }

  Byte get lengthInBytes {
    return map(
      nop: (_) => const Byte(1),
      panic: (_) => const Byte(1),
      move: (_) => const Byte(2),
      movei: (_) => const Byte(10),
      moveib: (_) => const Byte(3),
      load: (_) => const Byte(2),
      loadb: (_) => const Byte(2),
      store: (_) => const Byte(2),
      storeb: (_) => const Byte(2),
      push: (_) => const Byte(2),
      pop: (_) => const Byte(2),
      jump: (_) => const Byte(9),
      cjump: (_) => const Byte(9),
      call: (_) => const Byte(9),
      ret: (_) => const Byte(1),
      syscall: (_) => const Byte(2),
      cmp: (_) => const Byte(2),
      isequal: (_) => const Byte(1),
      isless: (_) => const Byte(1),
      isgreater: (_) => const Byte(1),
      islessequal: (_) => const Byte(1),
      isgreaterequal: (_) => const Byte(1),
      add: (_) => const Byte(2),
      sub: (_) => const Byte(2),
      mul: (_) => const Byte(2),
      div: (_) => const Byte(2),
      rem: (_) => const Byte(2),
      and: (_) => const Byte(2),
      or: (_) => const Byte(2),
      xor: (_) => const Byte(2),
      not: (_) => const Byte(2),
    );
  }

  @override
  String toString({Base base = Base.hex}) {
    return when(
      nop: () => 'nop',
      panic: () => 'panic',
      move: (to, from) => 'move $to $from',
      movei: (to, value) =>
          'movei $to ${value.format(base: base, shouldPad: false)}',
      moveib: (to, value) =>
          'moveib $to ${value.format(base: base, shouldPad: false)}',
      load: (to, from) => 'load $to $from',
      loadb: (to, from) => 'loadb $to $from',
      store: (to, from) => 'store $to $from',
      storeb: (to, from) => 'storeb $to $from',
      push: (reg) => 'push $reg',
      pop: (reg) => 'pop $reg',
      jump: (to) => 'jump ${to.format(base: base, shouldPad: false)}',
      cjump: (to) => 'cjump ${to.format(base: base, shouldPad: false)}',
      call: (target) => 'call ${target.format(base: base, shouldPad: false)}',
      ret: () => 'ret',
      syscall: (number) =>
          'syscall ${number.format(base: base, shouldPad: false)}',
      cmp: (left, right) => 'cmp $left $right',
      isequal: () => 'isequal',
      isless: () => 'isless',
      isgreater: () => 'isgreater',
      islessequal: () => 'islessequal',
      isgreaterequal: () => 'isgreaterequal',
      add: (to, from) => 'add $to $from',
      sub: (to, from) => 'sub $to $from',
      mul: (to, from) => 'mul $to $from',
      div: (dividend, divisor) => 'div $dividend $divisor',
      rem: (dividend, divisor) => 'rem $dividend $divisor',
      and: (to, from) => 'and $to $from',
      or: (to, from) => 'or $to $from',
      xor: (to, from) => 'xor $to $from',
      not: (to) => 'not $to',
    );
  }
}

enum Register {
  stackPointer,
  status,
  a,
  b,
  c,
  d,
  e,
  f;

  @override
  String toString() {
    return switch (this) {
      Register.stackPointer => 'sp',
      Register.status => 'st',
      Register.a => 'a',
      Register.b => 'b',
      Register.c => 'c',
      Register.d => 'd',
      Register.e => 'e',
      Register.f => 'f',
    };
  }

  String toFullString() {
    return switch (this) {
      Register.stackPointer => 'stack pointer',
      Register.status => 'status register',
      Register.a => 'general-purpose register a',
      Register.b => 'general-purpose register b',
      Register.c => 'general-purpose register c',
      Register.d => 'general-purpose register d',
      Register.e => 'general-purpose register e',
      Register.f => 'general-purpose register f',
    };
  }
}
