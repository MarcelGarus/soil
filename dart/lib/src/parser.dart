import 'dart:convert';
import 'dart:typed_data';

import 'package:supernova/supernova.dart';

import 'soil_binary.dart';

part 'parser.freezed.dart';

class Parser {
  Parser._(this.bytes);

  static Result<SoilBinary, String> parse(Uint8List bytes) =>
      Parser._(bytes)._parse();

  final Uint8List bytes;
  int offset = 0;

  bool get isAtEnd => offset >= bytes.length;

  Result<SoilBinary, String> _parse() {
    return _parseHeader().andThen((_) {
      String? name;
      String? description;
      Memory? initialMemory;
      List<Label>? labels;
      Uint8List? byteCode;

      while (true) {
        final sectionResult = _parseSection();
        if (sectionResult.isErr()) return Result.err(sectionResult.unwrapErr());
        if (sectionResult.unwrap().isNone()) break;
        final section = sectionResult.unwrap().unwrap();

        switch (section.type) {
          case 0:
            if (byteCode != null) {
              return const Result.err('Multiple byte code sections');
            }
            byteCode = section.content;
          case 1:
            if (initialMemory != null) {
              return const Result.err('Multiple initial memory sections');
            }
            initialMemory = Memory(section.content);
          case 2:
            if (name != null) return const Result.err('Multiple name sections');
            name = utf8.decode(section.content);
          case 3:
            // TODO(JonasWanke): Parse labels
            break;
          case 4:
            if (description != null) {
              return const Result.err('Multiple description sections');
            }
            description = utf8.decode(section.content);
          default:
            return Result.err('Unknown section type: ${section.type}');
        }
      }
      if (byteCode == null) return const Result.err('No byte code section');
      return Result.ok(
        SoilBinary(
          name: name,
          description: description,
          initialMemory: initialMemory,
          labels: labels,
          byteCode: byteCode,
        ),
      );
    });
  }

  static final _expectedMagicBytes = 'soil'.toUtf8();
  Result<Unit, String> _parseHeader() {
    return _consumeBytes(4).andThen((magicBytes) {
      if (!const DeepCollectionEquality()
          .equals(magicBytes, _expectedMagicBytes)) {
        return Result.err('Invalid magic bytes: $magicBytes');
      }
      return const Result.ok(unit);
    });
  }

  Result<Option<_Section>, String> _parseSection() {
    if (isAtEnd) return const Result.ok(Option.none());

    return _consumeByte()
        .andAlso(
          (_) => _consumeBytes(8).andThen(
            (length) => _consumeBytes(
              length.buffer.asByteData().getUint64(0, Endian.little),
            ),
          ),
        )
        .map((it) => Option.some(_Section(type: it.$1, content: it.$2)));
  }

  Result<int, String> _consumeByte() {
    if (isAtEnd) return const Result.err('Unexpected end of file');

    return Result.ok(bytes[offset++]);
  }

  Result<Uint8List, String> _consumeBytes(int length) {
    final end = offset + length;
    if (end > bytes.length) return const Result.err('Unexpected end of file');

    final result = bytes.sublist(offset, end);
    offset = end;
    return Result.ok(result);
  }
}

@freezed
class _Section with _$Section {
  const factory _Section({
    required int type,
    required Uint8List content,
  }) = __Section;
}

extension<T extends Object, E extends Object> on Result<T, E> {
  Result<(T, T1), E> andAlso<T1 extends Object>(Mapper<T, Result<T1, E>> op) =>
      andThen((t) => op(t).map((t1) => (t, t1)));
}
