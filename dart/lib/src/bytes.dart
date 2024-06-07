import 'dart:convert';
import 'dart:typed_data';

extension type Bytes(Uint8List list) implements Object {
  Bytes.zeros(Word length) : list = Uint8List(length.value);
  factory Bytes.fromString(String string) =>
      Bytes(Uint8List.fromList(utf8.encode(string)));

  Byte operator [](Word index) => Byte(list[index.value]);
  void operator []=(Word index, Byte value) => list[index.value] = value.value;

  Word getWord(Word index) =>
      Word(list.buffer.asByteData().getUint64(index.value, Endian.little));
  void setWord(Word index, Word value) {
    list.buffer.asByteData().setUint64(index.value, value.value, Endian.little);
  }

  Word get length => Word(list.length);
  bool get isEmpty => list.isEmpty;
  bool get isNotEmpty => list.isNotEmpty;

  Bytes getRange(Word start, [Word? end]) =>
      Bytes(list.sublist(start.value, end?.value));
  void setRange(Word start, Word end, Bytes bytes) =>
      list.setRange(start.value, end.value, bytes.list);
  void fill(Byte value) => fillRange(const Word(0), length, value);
  void fillRange(Word start, Word end, Byte value) =>
      list.fillRange(start.value, end.value, value.value);

  String decodeToString() => utf8.decode(list);
}

// ignore: avoid-global-state, avoid-unused-parameters
extension type const Byte._(int value) implements Object {
  const Byte(this.value) : assert(0 <= value && value <= 0xFF);

  factory Byte.min(Byte a, Byte b) => a < b ? a : b;
  factory Byte.max(Byte a, Byte b) => a > b ? a : b;

  static const bits = Byte(8);

  Byte operator &(Byte other) => Byte(value & other.value);
  Byte operator |(Byte other) => Byte(value | other.value);
  Byte operator ^(Byte other) => Byte(value ^ other.value);
  Byte operator ~() => Byte((~value) & 0xFF);

  Byte operator >>(int amount) => Byte(value >> amount);

  bool operator >(Byte other) => value > other.value;
  bool operator >=(Byte other) => value >= other.value;
  bool operator <(Byte other) => value < other.value;
  bool operator <=(Byte other) => value <= other.value;

  Word get asWord => Word(value);

  String format({
    Base base = Base.hex,
    bool includePrefix = true,
    bool shouldPad = true,
  }) {
    return _format(
      base,
      value,
      bits.value,
      includePrefix: includePrefix,
      shouldPad: shouldPad,
    );
  }
}

// ignore: avoid-global-state, avoid-unused-parameters
extension type const Word(int value) implements Object {
  factory Word.min(Word a, Word b) => a < b ? a : b;
  factory Word.max(Word a, Word b) => a > b ? a : b;

  static const bits = Byte(64);

  Word operator +(Word other) => Word(value + other.value);
  Word operator -(Word other) => Word(value - other.value);
  Word operator *(Word other) => Word(value * other.value);
  Word operator ~/(Word other) => Word(value ~/ other.value);
  Word remainder(Word other) => Word(value.remainder(other.value));

  Word operator &(Word other) => Word(value & other.value);
  Word operator |(Word other) => Word(value | other.value);
  Word operator ^(Word other) => Word(value ^ other.value);
  Word operator ~() => Word(~value);

  bool operator >(Word other) => value > other.value;
  bool operator >=(Word other) => value >= other.value;
  bool operator <(Word other) => value < other.value;
  bool operator <=(Word other) => value <= other.value;

  bool get isZero => value == 0;
  bool get isNotZero => value != 0;

  Byte get lowestByte => Byte(value & 0xFF);

  String format({
    Base base = Base.hex,
    bool includePrefix = true,
    bool shouldPad = true,
  }) {
    return _format(
      base,
      value,
      bits.value,
      includePrefix: includePrefix,
      shouldPad: shouldPad,
    );
  }
}

enum Base { binary, decimal, hex }

// These stringifications support grouping digits and, unlike the built-in
// formatters from Dart, treat values as unsigned numbers.
String _format(
  Base base,
  int value,
  int bits, {
  required bool includePrefix,
  required bool shouldPad,
}) {
  final buffer = StringBuffer();
  switch (base) {
    case Base.binary:
      if (includePrefix) buffer.write('0b');
      var hadDigits = false;
      for (var i = bits - 1; i >= 0; i--) {
        final bitIsZero = (value & (1 << i)) == 0;
        if (!shouldPad && !hadDigits && bitIsZero) continue;

        buffer.write(bitIsZero ? '0' : '1');
        hadDigits = true;
        if (i % 8 == 0) buffer.write('\u{202F}');
      }
    case Base.decimal:
      // TODO(JonasWanke): format as unsigned
      final string = value.toString();
      for (var i = 0; i < string.length; i++) {
        buffer.write(string[i]);
        if ((string.length - i - 1) % 3 == 0) buffer.write('\u{202F}');
      }
    case Base.hex:
      if (includePrefix) buffer.write('0x');
      var hadDigits = false;
      for (var i = 0; i < bits ~/ 4; i++) {
        final partValue = value >> (bits - (i + 1) * 4) & 0xF;
        if (!shouldPad && !hadDigits && partValue == 0) continue;

        final part = switch (partValue) {
          0x0 => '0',
          0x1 => '1',
          0x2 => '2',
          0x3 => '3',
          0x4 => '4',
          0x5 => '5',
          0x6 => '6',
          0x7 => '7',
          0x8 => '8',
          0x9 => '9',
          0xA => 'A',
          0xB => 'B',
          0xC => 'C',
          0xD => 'D',
          0xE => 'E',
          0xF => 'F',
          _ => throw StateError('Invalid hex digit'),
        };
        buffer.write(part);
        hadDigits = true;
        if (i.isOdd) buffer.write('\u{202F}');
      }
  }
  return buffer.toString();
}
