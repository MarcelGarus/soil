import 'package:supernova/supernova.dart' hide Bytes;

import '../bytes.dart';
import '../parser.dart';
import '../soil_binary.dart';
import 'instruction.dart';
import 'syscall.dart';

part 'vm.freezed.dart';

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

  VMStatus _status = const RunningVMStatus();
  VMStatus get status => _status;

  VMResult runForever() {
    while (status.isRunning) {
      runInstruction();
    }
    return status.toResult();
  }

  void runInstructions(int limit) {
    for (var i = 0; i < limit; i++) {
      if (!status.isRunning) return;
      runInstruction();
    }
  }

  void runInstruction() {
    assert(status.isRunning);

    final instructionResult = _decode();
    if (instructionResult.isErr()) {
      _status = VMStatus.error(instructionResult.unwrapErr());
      return;
    }
    final instruction = instructionResult.unwrap();
    logger.trace('Decoded instruction: $instruction');

    _execute(instruction);
  }

  Result<Instruction, String> _decode() {
    Register decodeRegister0() {
      final registerIndex =
          binary.byteCode[programCounter + const Word(1)].value & 0x07;
      return Register.values[registerIndex];
    }

    Register decodeRegister1() {
      final registerIndex =
          (binary.byteCode[programCounter + const Word(1)].value >> 4) & 0x07;
      return Register.values[registerIndex];
    }

    // ignore: omit_local_variable_types
    final Result<(Instruction, int), String> decodeResult =
        switch (binary.byteCode[programCounter]) {
      const Byte(0x00) => const Result.ok((Instruction.nop(), 1)),
      const Byte(0xe0) => const Result.ok((Instruction.panic(), 1)),
      const Byte(0xd0) => Result.ok(
          (
            Instruction.move(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xd1) => Result.ok(
          (
            Instruction.movei(
              decodeRegister0(),
              binary.byteCode.getWord(programCounter + const Word(2)),
            ),
            10,
          ),
        ),
      const Byte(0xd2) => Result.ok(
          (
            Instruction.moveib(
              decodeRegister0(),
              binary.byteCode[programCounter + const Word(2)],
            ),
            3,
          ),
        ),
      const Byte(0xd3) => Result.ok(
          (
            Instruction.load(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xd4) => Result.ok(
          (
            Instruction.loadb(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xd5) => Result.ok(
          (
            Instruction.store(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xd6) => Result.ok(
          (
            Instruction.storeb(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xd7) => Result.ok((Instruction.push(decodeRegister0()), 2)),
      const Byte(0xd8) => Result.ok((Instruction.pop(decodeRegister0()), 2)),
      const Byte(0xf0) => Result.ok(
          (
            Instruction.jump(
              binary.byteCode.getWord(programCounter + const Word(1)),
            ),
            9,
          ),
        ),
      const Byte(0xf1) => Result.ok(
          (
            Instruction.cjump(
              binary.byteCode.getWord(programCounter + const Word(1)),
            ),
            9,
          ),
        ),
      const Byte(0xf2) => Result.ok(
          (
            Instruction.call(
              binary.byteCode.getWord(programCounter + const Word(1)),
            ),
            9,
          ),
        ),
      const Byte(0xf3) => const Result.ok((Instruction.ret(), 1)),
      const Byte(0xf4) => Result.ok(
          (
            Instruction.syscall(
              binary.byteCode[programCounter + const Word(1)],
            ),
            2,
          ),
        ),
      const Byte(0xc0) => Result.ok(
          (
            Instruction.cmp(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xc1) => const Result.ok((Instruction.isequal(), 1)),
      const Byte(0xc2) => const Result.ok((Instruction.isless(), 1)),
      const Byte(0xc3) => const Result.ok((Instruction.isgreater(), 1)),
      const Byte(0xc4) => const Result.ok((Instruction.islessequal(), 1)),
      const Byte(0xc5) => const Result.ok((Instruction.isgreaterequal(), 1)),
      const Byte(0xa0) => Result.ok(
          (
            Instruction.add(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xa1) => Result.ok(
          (
            Instruction.sub(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xa2) => Result.ok(
          (
            Instruction.mul(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xa3) => Result.ok(
          (
            Instruction.div(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xa4) => Result.ok(
          (
            Instruction.rem(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xb0) => Result.ok(
          (
            Instruction.and(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xb1) => Result.ok(
          (
            Instruction.or(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xb2) => Result.ok(
          (
            Instruction.xor(decodeRegister0(), decodeRegister1()),
            2,
          ),
        ),
      const Byte(0xb3) => Result.ok((Instruction.not(decodeRegister0()), 2)),
      // ignore: pattern_never_matches_value_type
      final opcode => Result.err(
          'Unknown opcode at ${programCounter.format()}: ${opcode.format()}',
        ),
    };
    if (decodeResult.isErr()) {
      return Result.err(decodeResult.unwrapErr());
    }
    final (instruction, programCounterIncrement) = decodeResult.unwrap();

    programCounter += Word(programCounterIncrement);
    return Result.ok(instruction);
  }

  void _execute(Instruction instruction) {
    instruction.when(
      nop: () {},
      panic: () => _status = const VMStatus.panicked(),
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
        _status = VMStatus.exited(registers.a);
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
      case Syscall.uiDimensions:
        final size = syscalls.uiDimensions();
        registers.a = size.width;
        registers.b = size.height;
      case Syscall.uiRender:
        final offset = registers.a;
        final size = UiSize(registers.b, registers.c);
        syscalls.uiRender(
          memory.data.getRange(offset, offset + size.area * const Word(3)),
          size,
        );
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

@freezed
class VMStatus with _$VMStatus {
  const factory VMStatus.running() = RunningVMStatus;
  const factory VMStatus.exited(Word exitCode) = ExitedVMStatus;
  const factory VMStatus.panicked() = PanickedVMStatus;
  const factory VMStatus.error(String message) = ErrorVMStatus;
  const VMStatus._();

  bool get isRunning => this is RunningVMStatus;

  VMResult toResult() {
    return when(
      running: () => throw StateError('VM is still running'),
      exited: VMResult.exited,
      panicked: VMResult.panicked,
      error: VMResult.error,
    );
  }

  @override
  String toString() {
    return when(
      running: () => 'Running',
      exited: (exitCode) => 'Exited with code $exitCode',
      panicked: () => 'Panicked',
      error: (message) => 'Error: $message',
    );
  }
}

@freezed
class VMResult with _$VMResult {
  const factory VMResult.exited(Word exitCode) = ExitedVMResult;
  const factory VMResult.panicked() = PanickedVMResult;
  const factory VMResult.error(String message) = ErrorVMResult;
  const VMResult._();
}
