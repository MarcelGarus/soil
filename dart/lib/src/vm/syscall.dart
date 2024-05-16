import 'package:supernova/supernova.dart' hide Bytes;
import 'package:supernova/supernova_io.dart' as io;

import '../bytes.dart';

part 'syscall.freezed.dart';

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

@freezed
class Syscalls with _$Syscalls {
  const factory Syscalls({
    required void Function(Word status) exit,
    required void Function(String message) print,
    required void Function(String message) log,
    required Word? Function(String fileName, Word mode) create,
    required Word? Function(String fileName, Word flags, Word mode) openReading,
    required Word? Function(String fileName, Word flags, Word mode) openWriting,
    required Word Function(Word fileDescriptor, Bytes buffer) read,
    required Word Function(Word fileDescriptor, Bytes buffer) write,
    required bool Function(Word fileDescriptor) close,
    required Word Function() argc,
    required Word Function(Word argIndex, Bytes buffer) arg,
    required Word Function(Bytes buffer) readInput,
    required void Function(Bytes binary) execute,
  }) = _Syscalls;

  factory Syscalls.io({required List<String> arguments}) {
    return Syscalls(
      exit: (status) {
        logger.info('Exiting with code $status');
        io.exit(status.value);
      },
      print: io.stdout.write,
      log: io.stderr.write,
      create: (fileName, mode) => TODO('Implement `create` syscall.'),
      openReading: (fileName, flags, mode) =>
          TODO('Implement `open_reading` syscall.'),
      openWriting: (fileName, flags, mode) =>
          TODO('Implement `open_writing` syscall.'),
      read: (fileDescriptor, buffer) => TODO('Implement `read` syscall.'),
      write: (fileDescriptor, buffer) => TODO('Implement `write` syscall.'),
      close: (fileDescriptor) => TODO('Implement `close` syscall.'),
      argc: () => Word(arguments.length),
      arg: (argIndex, buffer) => TODO('Implement `arg` syscall.'),
      readInput: (buffer) {
        var i = const Word(0);
        for (; i < buffer.length; i += const Word(1)) {
          final byte = io.stdin.readByteSync();
          if (byte == -1) break;
          buffer[i] = Byte(byte);
        }
        return i;
      },
      execute: (binary) => TODO('Implement `execute` syscall.'),
    );
  }
}
