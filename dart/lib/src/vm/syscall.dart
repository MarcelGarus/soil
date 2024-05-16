import 'package:supernova/supernova.dart' hide Bytes;
import 'package:supernova/supernova_io.dart' as io;

import '../bytes.dart';

enum Syscall {
  exit,
  print,
  log,
  create,
  openReading,
  openWriting,
  read,
  write,
  close,
  argc,
  arg,
  readInput,
  execute;

  const Syscall();
  factory Syscall.fromByte(Byte byte) => values[byte.value];
}

abstract interface class Syscalls {
  const Syscalls();
  void exit(Word status);
  void print(String message);
  void log(String message);
  Word? create(String fileName, Word mode);
  Word? openReading(String fileName, Word flags, Word mode);
  Word? openWriting(String fileName, Word flags, Word mode);
  Word read(Word fileDescriptor, Bytes buffer);
  Word write(Word fileDescriptor, Bytes buffer);
  bool close(Word fileDescriptor);
  Word argc();
  Word arg(Word argIndex, Bytes buffer);
  Word readInput(Bytes buffer);
  void execute(Bytes binary);
}

class DefaultSyscalls implements Syscalls {
  const DefaultSyscalls({required this.arguments});

  final List<String> arguments;

  @override
  void exit(Word status) {
    logger.info('Exiting with code $status');
    io.exit(status.value);
  }

  @override
  void print(String message) => io.stdout.write(message);
  @override
  void log(String message) => io.stderr.write(message);

  @override
  Word? create(String fileName, Word mode) =>
      TODO('Implement `create` syscall.');
  @override
  Word? openReading(String fileName, Word flags, Word mode) =>
      TODO('Implement `open_reading` syscall.');
  @override
  Word? openWriting(String fileName, Word flags, Word mode) =>
      TODO('Implement `open_writing` syscall.');
  @override
  Word read(Word fileDescriptor, Bytes buffer) =>
      TODO('Implement `read` syscall.');
  @override
  Word write(Word fileDescriptor, Bytes buffer) =>
      TODO('Implement `write` syscall.');
  @override
  bool close(Word fileDescriptor) => TODO('Implement `close` syscall.');

  @override
  Word argc() => Word(arguments.length);
  @override
  Word arg(Word argIndex, Bytes buffer) {
    final argument = Bytes.fromString(arguments[argIndex.value]);
    final length = Word.min(buffer.length, argument.length);
    buffer.setRange(const Word(0), length, argument);
    return length;
  }

  @override
  Word readInput(Bytes buffer) {
    var i = const Word(0);
    for (; i < buffer.length; i += const Word(1)) {
      final byte = io.stdin.readByteSync();
      if (byte == -1) break;
      buffer[i] = Byte(byte);
    }
    return i;
  }

  @override
  void execute(Bytes binary) => TODO('Implement `execute` syscall.');
}
