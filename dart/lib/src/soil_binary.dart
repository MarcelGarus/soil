import 'package:supernova/supernova.dart' hide Bytes;

import 'bytes.dart';

part 'soil_binary.freezed.dart';

@freezed
class SoilBinary with _$SoilBinary {
  const factory SoilBinary({
    required String? name,
    required String? description,
    required Memory? initialMemory,
    required Map<Word, String>? labels,
    required Bytes byteCode,
  }) = _SoilBinary;
}

@freezed
class Memory with _$Memory {
  const factory Memory(Bytes data) = _Memory;
}
