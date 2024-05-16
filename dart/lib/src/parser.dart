import 'package:supernova/supernova.dart' hide Bytes;

import 'bytes.dart';
import 'soil_binary.dart';

part 'parser.freezed.dart';

class Parser {
  Parser._(this.bytes);

  static Result<SoilBinary, String> parse(Bytes bytes) =>
      Parser._(bytes)._parse();

  final Bytes bytes;

  Word offset = const Word(0);
  bool get isAtEnd => offset >= bytes.length;

  Result<SoilBinary, String> _parse() {
    return _parseHeader().andThen((_) {
      String? name;
      String? description;
      Memory? initialMemory;
      Map<Word, String>? labels;
      Bytes? byteCode;

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
            name = section.content.decodeToString();
          case 3:
            if (labels != null) {
              return const Result.err('Multiple label sections');
            }
            offset = section.contentStartOffset;
            final labelsResult = _parseLabels();
            if (labelsResult.isErr()) {
              return Result.err(labelsResult.unwrapErr());
            }
            labels = labelsResult.unwrap();
          case 4:
            if (description != null) {
              return const Result.err('Multiple description sections');
            }
            description = section.content.decodeToString();
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
    return _consumeBytes(const Word(4)).andThen((magicBytes) {
      if (!const DeepCollectionEquality()
          .equals(magicBytes, _expectedMagicBytes)) {
        return Result.err('Invalid magic bytes: $magicBytes');
      }
      return const Result.ok(unit);
    });
  }

  Result<Option<_Section>, String> _parseSection() {
    if (isAtEnd) return const Result.ok(Option.none());

    return _consumeByte().andAlso((_) => _consumeLengthPrefixedBytes()).map(
          (it) => Option.some(
            _Section(
              type: it.$1,
              contentStartOffset: offset - it.$2.length,
              content: it.$2,
            ),
          ),
        );
  }

  Result<Map<Word, String>, String> _parseLabels() {
    return _consumeWord().andThen((labelCount) {
      final labels = <Word, String>{};
      for (var i = 0; i < labelCount.value; i++) {
        final labelResult = _parseLabel();
        if (labelResult.isErr()) return Result.err(labelResult.unwrapErr());
        final label = labelResult.unwrap();

        if (labels.containsKey(label.offset)) {
          return Result.err('Duplicate label for offset ${label.offset}');
        }
        labels[label.offset] = label.label;
      }
      return Result.ok(labels);
    });
  }

  Result<({Word offset, String label}), String> _parseLabel() {
    return _consumeWord()
        .andAlso((_) => _consumeLengthPrefixedBytes())
        .map((it) => (offset: it.$1, label: it.$2.decodeToString()));
  }

  Result<Byte, String> _consumeByte() {
    if (isAtEnd) return const Result.err('Unexpected end of file');

    final byte = bytes[offset];
    offset += const Word(1);
    return Result.ok(byte);
  }

  Result<Word, String> _consumeWord() {
    return _consumeBytes(const Word(8)).map((it) => it.getWord(const Word(0)));
  }

  Result<Bytes, String> _consumeLengthPrefixedBytes() =>
      _consumeWord().andThen(_consumeBytes);

  Result<Bytes, String> _consumeBytes(Word length) {
    final end = offset + length;
    if (end > bytes.length) return const Result.err('Unexpected end of file');

    final result = bytes.getRange(offset, end);
    offset = end;
    return Result.ok(result);
  }
}

@freezed
class _Section with _$Section {
  const factory _Section({
    required Byte type,
    required Word contentStartOffset,
    required Bytes content,
  }) = __Section;
}

extension<T extends Object, E extends Object> on Result<T, E> {
  Result<(T, T1), E> andAlso<T1 extends Object>(Mapper<T, Result<T1, E>> op) =>
      andThen((t) => op(t).map((t1) => (t, t1)));
}
