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
    final binary = value.formatBinary();
    final decimal = value.formatDecimal();
    final hex = value.formatHex();

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
}
