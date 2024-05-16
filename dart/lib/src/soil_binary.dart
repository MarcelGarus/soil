import 'dart:typed_data';

import 'package:supernova/supernova.dart';

part 'soil_binary.freezed.dart';

@freezed
class SoilBinary with _$SoilBinary {
  const factory SoilBinary({
    required String? name,
    required String? description,
    required Memory? initialMemory,
    required List<Label>? labels,
    required Uint8List byteCode,
  }) = _SoilBinary;
}

@freezed
class Memory with _$Memory {
  const factory Memory(Uint8List data) = _Memory;
}

@freezed
class Label with _$Label {
  const factory Label({
    required int offset,
    required String label,
  }) = _Label;
}

@freezed
class Instruction with _$Instruction {
  const factory Instruction.nop() = NopInstruction;
}
