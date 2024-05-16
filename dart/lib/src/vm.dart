import 'dart:io';
import 'dart:typed_data';

import 'package:supernova/supernova.dart' hide Bytes;

import 'bytes.dart';
import 'instruction.dart';
import 'soil_binary.dart';

class VM {
  VM(this.binary)
      : memory = _createMemory(binary.initialMemory),
        registers = Registers(memorySize);

  static const memorySize = Word(0x1000000);
  static Memory _createMemory(Memory? initialMemory) {
    assert(initialMemory == null || initialMemory.data.length <= memorySize);

    final memory = Uint8List(memorySize.value);
    if (initialMemory != null) {
      memory.setRange(
        0,
        initialMemory.data.length.value,
        initialMemory.data.list,
      );
    }
    return Memory(Bytes(memory));
  }

  final SoilBinary binary;
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
    switch (Syscall.fromByte(instruction.number)) {
      case Syscall.exit:
        logger.info('Exiting with code ${registers.a.value}');
        exit(registers.a.value);
      case Syscall.print:
        final message = memory.data
            .sublist(registers.a, registers.a + registers.b)
            .decodeToString();
        stdout.write(message);
      case Syscall.log:
        final message = memory.data
            .sublist(registers.a, registers.a + registers.b)
            .decodeToString();
        stderr.write(message);
      case Syscall.create:
        TODO('Implement `create` syscall.');
      case Syscall.openReading:
        TODO('Implement `open_reading` syscall.');
      case Syscall.openWriting:
        TODO('Implement `open_writing` syscall.');
      case Syscall.read:
        TODO('Implement `read` syscall.');
      case Syscall.write:
        TODO('Implement `write` syscall.');
      case Syscall.close:
        TODO('Implement `close` syscall.');
      case Syscall.argc:
        TODO('Implement `argc` syscall.');
      case Syscall.arg:
        TODO('Implement `arg` syscall.');
      case Syscall.readInput:
        for (var i = 0; i < registers.b.value; i++) {
          final byte = stdin.readByteSync();
          if (byte == -1) break;
          memory.data[registers.a + Word(i)] = Byte(byte);
        }
      case Syscall.execute:
        TODO('Implement `execute` syscall.');
    }
  }
}

class Registers {
  Registers(Word memorySize) : stackPointer = memorySize;

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
