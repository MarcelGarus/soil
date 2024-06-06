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

    final instructionResult = decodeNextInstruction();
    if (instructionResult.isErr()) {
      _status = VMStatus.error(instructionResult.unwrapErr());
      return;
    }
    final instruction = instructionResult.unwrap();
    programCounter += instruction.lengthInBytes.asWord;
    // logger.trace('Decoded instruction: $instruction');

    _execute(instruction);
  }

  Result<Instruction, String> decodeNextInstruction() =>
      Instruction.decode(binary.byteCode, programCounter);

  void _execute(Instruction instruction) {
    switch (instruction) {
      case NopInstruction():
        break;
      case PanicInstruction():
        _status = const VMStatus.panicked();
      case MoveInstruction(:final to, :final from):
        registers[to] = registers[from];
      case MoveiInstruction(:final to, :final value):
        registers[to] = value;
      case MoveibInstruction(:final to, :final value):
        registers[to] = value.asWord;
      case LoadInstruction(:final to, :final from):
        registers[to] = memory.data.getWord(registers[from]);
      case LoadbInstruction(:final to, :final from):
        registers[to] = memory.data[registers[from]].asWord;
      case StoreInstruction(:final to, :final from):
        memory.data.setWord(registers[to], registers[from]);
      case StorebInstruction(:final to, :final from):
        memory.data[registers[to]] = registers[from].lowestByte;
      case PushInstruction(:final reg):
        registers.stackPointer -= const Word(8);
        memory.data.setWord(registers.stackPointer, registers[reg]);
      case PopInstruction(:final reg):
        registers[reg] = memory.data.getWord(registers.stackPointer);
        registers.stackPointer += const Word(8);
      case JumpInstruction(:final to):
        programCounter = to;
      case CjumpInstruction(:final to):
        if (registers.status.isNotZero) programCounter = to;
      case CallInstruction(:final target):
        callStack.add(programCounter);
        programCounter = target;
      case RetInstruction():
        programCounter = callStack.removeLast();
      case SyscallInstruction(:final number):
        runSyscall(SyscallInstruction(number));
      case CmpInstruction(:final left, :final right):
        registers.status = registers[left] - registers[right];
      case IsequalInstruction():
        registers.status =
            registers.status.isZero ? const Word(1) : const Word(0);
      case IslessInstruction():
        registers.status =
            registers.status < const Word(0) ? const Word(1) : const Word(0);
      case IsgreaterInstruction():
        registers.status =
            registers.status > const Word(0) ? const Word(1) : const Word(0);
      case IslessequalInstruction():
        registers.status =
            registers.status <= const Word(0) ? const Word(1) : const Word(0);
      case IsgreaterequalInstruction():
        registers.status =
            registers.status >= const Word(0) ? const Word(1) : const Word(0);
      case AddInstruction(:final to, :final from):
        registers[to] += registers[from];
      case SubInstruction(:final to, :final from):
        registers[to] -= registers[from];
      case MulInstruction(:final to, :final from):
        registers[to] *= registers[from];
      case DivInstruction(:final dividend, :final divisor):
        registers[dividend] ~/= registers[divisor];
      case RemInstruction(:final dividend, :final divisor):
        registers[dividend] = registers[dividend].remainder(registers[divisor]);
      case AndInstruction(:final to, :final from):
        registers[to] &= registers[from];
      case OrInstruction(:final to, :final from):
        registers[to] |= registers[from];
      case XorInstruction(:final to, :final from):
        registers[to] ^= registers[from];
      case NotInstruction(:final to):
        registers[to] = ~registers[to];
    }
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
