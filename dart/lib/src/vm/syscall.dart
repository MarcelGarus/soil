import 'package:supernova/supernova.dart' hide Bytes;
import 'package:supernova/supernova_io.dart' as io;
import 'package:supernova/supernova_io.dart';

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
  DefaultSyscalls({required this.arguments});

  final List<String> arguments;

  // TODO(JonasWanke): Error handling

  @override
  void exit(Word status) {
    logger.info('Exiting with code $status');
    io.exit(status.value);
  }

  @override
  void print(String message) => stdout.write(message);
  @override
  void log(String message) => stderr.write(message);

  final _fileDescriptors = <File?>[null];
  (File, Word) _getFileAndDescriptor(String fileName) {
    final index =
        _fileDescriptors.firstIndexWhereOrNull((it) => it?.path == fileName);
    if (index != null) return (_fileDescriptors[index]!, Word(index));

    final file = File(fileName);
    _fileDescriptors.add(file);
    return (file, Word(_fileDescriptors.length - 1));
  }

  @override
  Word? create(String fileName, Word mode) {
    final (file, fileDescriptor) = _getFileAndDescriptor(fileName);
    try {
      file.createSync();
    } catch (e, st) {
      logger.error('Error during create syscall', e, st);
      return null;
    }
    return fileDescriptor;
  }

  final _openReading = <Word, RandomAccessFile>{};
  @override
  Word? openReading(String fileName, Word flags, Word mode) {
    final (file, fileDescriptor) = _getFileAndDescriptor(fileName);
    try {
      _openReading[fileDescriptor] = file.openSync();
    } catch (e, st) {
      logger.error('Error during open_reading syscall', e, st);
      return null;
    }
    return fileDescriptor;
  }

  final _openWriting = <Word, IOSink>{};
  @override
  Word? openWriting(String fileName, Word flags, Word mode) {
    final (file, fileDescriptor) = _getFileAndDescriptor(fileName);
    try {
      _openWriting[fileDescriptor] = file.openWrite();
    } catch (e, st) {
      logger.error('Error during open_writing syscall', e, st);
      return null;
    }
    return fileDescriptor;
  }

  @override
  Word read(Word fileDescriptor, Bytes buffer) =>
      Word(_openReading[fileDescriptor]!.readIntoSync(buffer.list));

  @override
  Word write(Word fileDescriptor, Bytes buffer) {
    _openWriting[fileDescriptor]!.add(buffer.list);
    return buffer.length;
  }

  @override
  bool close(Word fileDescriptor) {
    try {
      _fileDescriptors[fileDescriptor.value] = null;
      _openReading.remove(fileDescriptor);
      _openWriting.remove(fileDescriptor);
      return true;
    } catch (e, st) {
      logger.error('Error during close syscall', e, st);
      return false;
    }
  }

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
      final byte = stdin.readByteSync();
      if (byte == -1) break;
      buffer[i] = Byte(byte);
    }
    return i;
  }

  @override
  void execute(Bytes binary) => TODO('Implement `execute` syscall.');
}
