import 'dart:convert';
import 'dart:typed_data';

extension type Bytes(Uint8List list) implements Object {
  Byte operator [](Word index) => Byte(list[index.value]);
  void operator []=(Word index, Byte value) => list[index.value] = value.value;

  Word getWord(Word index) =>
      Word(list.buffer.asByteData().getUint64(index.value, Endian.little));
  void setWord(Word index, Word value) {
    list.buffer.asByteData().setUint64(index.value, value.value, Endian.little);
  }

  Word get length => Word(list.length);

  Bytes sublist(Word start, [Word? end]) =>
      Bytes(list.sublist(start.value, end?.value));

  String decodeToString() => utf8.decode(list);
}

// ignore: avoid-global-state, avoid-unused-parameters
extension type const Byte._(int value) implements Object {
  const Byte(this.value) : assert(0 <= value && value < 0xFF);

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
