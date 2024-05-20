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

  String format() => '0x${value.toRadixString(16).padLeft(2)}';
}

// ignore: avoid-global-state, avoid-unused-parameters
extension type const Word(int value) implements Object {
  factory Word.min(Word a, Word b) => a < b ? a : b;
  factory Word.max(Word a, Word b) => a > b ? a : b;

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

  String format() => '0x${value.toRadixString(16).padLeft(8)}';
}
