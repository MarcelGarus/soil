import 'package:google_fonts/google_fonts.dart';
import 'package:soil_vm/soil_vm.dart';
import 'package:supernova_flutter/supernova_flutter.dart';

class RegistersWidget extends StatelessWidget {
  const RegistersWidget(this.registers, {super.key});

  final Registers registers;

  @override
  Widget build(BuildContext context) {
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: [
        for (final register in Register.values)
          TableRow(
            children: [
              Tooltip(
                message: register.toFullString(),
                child: Text('$register: '),
              ),
              WordWidget(registers[register]),
            ],
          ),
      ],
    );
  }
}

class WordWidget extends StatelessWidget {
  const WordWidget(this.value, {super.key});

  static final monospaceTextStyle = GoogleFonts.firaCode();

  final Word value;

  @override
  Widget build(BuildContext context) {
    final binary = _format(2, padLength: Word.bits.value, groupSize: 8);
    final decimal = _format(10, groupSize: 3);
    final hex = _format(16, padLength: Word.bits.value ~/ 4, groupSize: 2);

    return Tooltip(
      richMessage: TextSpan(
        children: [
          const TextSpan(text: 'Binary: '),
          TextSpan(text: binary, style: monospaceTextStyle),
          const TextSpan(text: '\nDecimal: '),
          TextSpan(text: decimal, style: monospaceTextStyle),
          const TextSpan(text: '\nHex: '),
          TextSpan(text: hex, style: monospaceTextStyle),
        ],
      ),
      textAlign: TextAlign.end,
      child: Text('0x$hex', style: monospaceTextStyle),
    );
  }

  String _format(int base, {int padLength = 1, required int groupSize}) {
    final string = value.value.toRadixString(base).padLeft(padLength, '0');
    return string.characters.reversed
        .windowed(groupSize, step: groupSize, partialWindows: true)
        .map((it) => it.join().reversed)
        .reversed
        .join('\u{202F}');
  }
}
