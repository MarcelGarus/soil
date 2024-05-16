import 'package:supernova/supernova.dart';

import '../bytes.dart';

part 'instruction.freezed.dart';

@freezed
class Instruction with _$Instruction {
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

  @override
  String toString() {
    return when(
      nop: () => 'nop',
      panic: () => 'panic',
      move: (to, from) => 'move $to $from',
      movei: (to, value) => 'movei $to $value',
      moveib: (to, value) => 'moveib $to $value',
      load: (to, from) => 'load $to $from',
      loadb: (to, from) => 'loadb $to $from',
      store: (to, from) => 'store $to $from',
      storeb: (to, from) => 'storeb $to $from',
      push: (reg) => 'push $reg',
      pop: (reg) => 'pop $reg',
      jump: (to) => 'jump $to',
      cjump: (to) => 'cjump $to',
      call: (target) => 'call $target',
      ret: () => 'ret',
      syscall: (number) => 'syscall $number',
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
}
