import 'package:supernova/supernova.dart' hide Bytes;

import '../bytes.dart';
import '../parser.dart';
import '../soil_binary.dart';
import 'instruction.dart';
import 'syscall.dart';

class VM {
  VM(this.binary, this.syscalls)
      : memory = _createMemory(binary.initialMemory),
        registers = Registers(memorySize);

  static const memorySize = Word(0x1000000);
  static Memory _createMemory(Memory? initialMemory) {
    assert(initialMemory == null || initialMemory.data.length <= memorySize);

    final memory = Bytes.zeros(memorySize);
    if (initialMemory != null) {
      memory.setRange(
        const Word(0),
        initialMemory.data.length,
        initialMemory.data,
      );
    }
    return Memory(memory);
  }

  SoilBinary binary;
  final Syscalls syscalls;

  final Memory memory;
  final Registers registers;
  Word programCounter = const Word(0);
  List<Word> callStack = [];

  void runForever() {
    while (true) {
      runInstruction();
    }
  }

  void runInstruction() {
    final instruction = _decode();
    logger.trace('Decoded instruction: $instruction');
    _execute(instruction);
  }

  Instruction _decode() {
    Register decodeRegister0() {
      return Register
          .values[binary.byteCode[programCounter + const Word(1)].value & 0x07];
    }

    Register decodeRegister1() {
      return Register.values[
          (binary.byteCode[programCounter + const Word(1)].value >> 4) & 0x07];
    }

    final (instruction, programCounterIncrement) =
        switch (binary.byteCode[programCounter]) {
      0x00 => (const Instruction.nop(), 1),
      0xe0 => (const Instruction.panic(), 1),
      0xd0 => (Instruction.move(decodeRegister0(), decodeRegister1()), 2),
      0xd1 => (
          Instruction.movei(
            decodeRegister0(),
            binary.byteCode.getWord(programCounter + const Word(2)),
          ),
          10,
        ),
      0xd2 => (
          Instruction.moveib(
            decodeRegister0(),
            binary.byteCode[programCounter + const Word(2)],
          ),
          3,
        ),
      0xd3 => (Instruction.load(decodeRegister0(), decodeRegister1()), 2),
      0xd4 => (Instruction.loadb(decodeRegister0(), decodeRegister1()), 2),
      0xd5 => (Instruction.store(decodeRegister0(), decodeRegister1()), 2),
      0xd6 => (Instruction.storeb(decodeRegister0(), decodeRegister1()), 2),
      0xd7 => (Instruction.push(decodeRegister0()), 2),
      0xd8 => (Instruction.pop(decodeRegister0()), 2),
      0xf0 => (
          Instruction.jump(
            binary.byteCode.getWord(programCounter + const Word(1)),
          ),
          9,
        ),
      0xf1 => (
          Instruction.cjump(
            binary.byteCode.getWord(programCounter + const Word(1)),
          ),
          9,
        ),
      0xf2 => (
          Instruction.call(
            binary.byteCode.getWord(programCounter + const Word(1)),
          ),
          9,
        ),
      0xf3 => (const Instruction.ret(), 1),
      0xf4 => (
          Instruction.syscall(binary.byteCode[programCounter + const Word(1)]),
          2,
        ),
      0xc0 => (Instruction.cmp(decodeRegister0(), decodeRegister1()), 2),
      0xc1 => (const Instruction.isequal(), 1),
      0xc2 => (const Instruction.isless(), 1),
      0xc3 => (const Instruction.isgreater(), 1),
      0xc4 => (const Instruction.islessequal(), 1),
      0xc5 => (const Instruction.isgreaterequal(), 1),
      0xa0 => (Instruction.add(decodeRegister0(), decodeRegister1()), 2),
      0xa1 => (Instruction.sub(decodeRegister0(), decodeRegister1()), 2),
      0xa2 => (Instruction.mul(decodeRegister0(), decodeRegister1()), 2),
      0xa3 => (Instruction.div(decodeRegister0(), decodeRegister1()), 2),
      0xa4 => (Instruction.rem(decodeRegister0(), decodeRegister1()), 2),
      0xb0 => (Instruction.and(decodeRegister0(), decodeRegister1()), 2),
      0xb1 => (Instruction.or(decodeRegister0(), decodeRegister1()), 2),
      0xb2 => (Instruction.xor(decodeRegister0(), decodeRegister1()), 2),
      0xb3 => (Instruction.not(decodeRegister0()), 2),
      final opcode => throw StateError('Unknown opcode: ${opcode.format()}'),
    };
    programCounter += Word(programCounterIncrement);
    return instruction;
  }

  void _execute(Instruction instruction) {
    instruction.when(
      nop: () {},
      panic: () => throw Exception('Panic instruction'),
      move: (to, from) => registers[to] = registers[from],
      movei: (to, value) => registers[to] = value,
      moveib: (to, value) => registers[to] = value.asWord,
      load: (to, from) => registers[to] = memory.data.getWord(registers[from]),
      loadb: (to, from) => registers[to] = memory.data[registers[from]].asWord,
      store: (to, from) => memory.data.setWord(registers[to], registers[from]),
      storeb: (to, from) =>
          memory.data[registers[to]] = registers[from].lowestByte,
      push: (reg) {
        registers.stackPointer -= const Word(8);
        memory.data.setWord(registers.stackPointer, registers[reg]);
      },
      pop: (reg) {
        registers[reg] = memory.data.getWord(registers.stackPointer);
        registers.stackPointer += const Word(8);
      },
      jump: (to) => programCounter = to,
      cjump: (to) {
        if (registers.status.isNotZero) programCounter = to;
      },
      call: (target) {
        callStack.add(programCounter);
        programCounter = target;
      },
      ret: () => programCounter = callStack.removeLast(),
      syscall: (number) => runSyscall(SyscallInstruction(number)),
      cmp: (left, right) =>
          registers.status = registers[left] - registers[right],
      isequal: () => registers.status =
          registers.status.isZero ? const Word(1) : const Word(0),
      isless: () => registers.status =
          registers.status < const Word(0) ? const Word(1) : const Word(0),
      isgreater: () => registers.status =
          registers.status > const Word(0) ? const Word(1) : const Word(0),
      islessequal: () => registers.status =
          registers.status <= const Word(0) ? const Word(1) : const Word(0),
      isgreaterequal: () => registers.status =
          registers.status >= const Word(0) ? const Word(1) : const Word(0),
      add: (to, from) => registers[to] += registers[from],
      sub: (to, from) => registers[to] -= registers[from],
      mul: (to, from) => registers[to] *= registers[from],
      div: (dividend, divisor) => registers[dividend] ~/= registers[divisor],
      rem: (dividend, divisor) => registers[dividend] =
          registers[dividend].remainder(registers[divisor]),
      and: (to, from) => registers[to] &= registers[from],
      or: (to, from) => registers[to] |= registers[from],
      xor: (to, from) => registers[to] ^= registers[from],
      not: (to) => registers[to] = ~registers[to],
    );
  }

  void runSyscall(SyscallInstruction instruction) {
    Bytes getBytesFrom(Word offset, Word length) =>
        memory.data.getRange(offset, offset + length);
    String getStringFromAB() =>
        getBytesFrom(registers.a, registers.b).decodeToString();
    Bytes getBytesFromAB() => getBytesFrom(registers.a, registers.b);
    Bytes getBytesFromBC() => getBytesFrom(registers.b, registers.c);

    switch (Syscall.fromByte(instruction.number)) {
      case Syscall.exit:
        syscalls.exit(registers.a);
      case Syscall.print:
        syscalls.print(getStringFromAB());
      case Syscall.log:
        syscalls.log(getStringFromAB());
      case Syscall.create:
        registers.a =
            syscalls.create(getStringFromAB(), registers.c) ?? const Word(0);
      case Syscall.openReading:
        registers.a =
            syscalls.openReading(getStringFromAB(), registers.c, registers.d) ??
                const Word(0);
      case Syscall.openWriting:
        registers.a =
            syscalls.openWriting(getStringFromAB(), registers.c, registers.d) ??
                const Word(0);
      case Syscall.read:
        registers.a = syscalls.read(registers.a, getBytesFromBC());
      case Syscall.write:
        registers.a = syscalls.write(registers.a, getBytesFromBC());
      case Syscall.close:
        registers.a =
            syscalls.close(registers.a) ? const Word(1) : const Word(0);
      case Syscall.argc:
        registers.a = syscalls.argc();
      case Syscall.arg:
        registers.a = syscalls.arg(registers.a, getBytesFromBC());
      case Syscall.readInput:
        registers.a = syscalls.readInput(getBytesFromAB());
      case Syscall.execute:
        binary = Parser.parse(getBytesFromAB()).unwrap();

        final initialMemory = binary.initialMemory;
        assert(
          initialMemory == null || initialMemory.data.length <= memorySize,
        );
        memory.data.fill(const Byte(0));
        if (initialMemory != null) {
          memory.data.setRange(
            const Word(0),
            initialMemory.data.length,
            initialMemory.data,
          );
        }

        registers.reset(memorySize);
        programCounter = const Word(0);
        callStack.clear();
    }
  }
}

class Registers {
  Registers(Word memorySize) : stackPointer = memorySize;

  void reset(Word memorySize) {
    stackPointer = memorySize;
    status = const Word(0);
    a = const Word(0);
    b = const Word(0);
    c = const Word(0);
    d = const Word(0);
    e = const Word(0);
    f = const Word(0);
  }

  Word stackPointer;
  Word status = const Word(0);

  // General-Purpose Registers:
  Word a = const Word(0);
  Word b = const Word(0);
  Word c = const Word(0);
  Word d = const Word(0);
  Word e = const Word(0);
  Word f = const Word(0);

  Word operator [](Register register) {
    return switch (register) {
      Register.stackPointer => stackPointer,
      Register.status => status,
      Register.a => a,
      Register.b => b,
      Register.c => c,
      Register.d => d,
      Register.e => e,
      Register.f => f,
    };
  }

  void operator []=(Register register, Word value) {
    switch (register) {
      case Register.stackPointer:
        stackPointer = value;
      case Register.status:
        status = value;
      case Register.a:
        a = value;
      case Register.b:
        b = value;
      case Register.c:
        c = value;
      case Register.d:
        d = value;
      case Register.e:
        e = value;
      case Register.f:
        f = value;
    }
  }
}
