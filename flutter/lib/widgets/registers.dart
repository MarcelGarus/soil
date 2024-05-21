import 'package:soil_vm/soil_vm.dart';
import 'package:supernova_flutter/supernova_flutter.dart';

import '../main.dart';

class RegistersWidget extends StatelessWidget {
  const RegistersWidget(this.vm, {super.key});

  final VM vm;

  @override
  Widget build(BuildContext context) {
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: [
        TableRow(
          children: [
            const Tooltip(message: 'program counter', child: Text('pc: ')),
            WordWidget(vm.programCounter),
          ],
        ),
        for (final register in Register.values)
          TableRow(
            children: [
              Tooltip(
                message: register.toFullString(),
                child: Text('$register: '),
              ),
              WordWidget(vm.registers[register]),
            ],
          ),
      ],
    );
  }
}

class WordSpan extends WidgetSpan {
  WordSpan(Word word)
      : super(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: WordWidget(word),
        );
}

class WordWidget extends StatelessWidget {
  const WordWidget(this.word, {super.key});

  final Word word;

  @override
  Widget build(BuildContext context) {
    final binary = word.format(base: Base.binary);
    final decimal = word.format(base: Base.decimal);
    final hex = word.format();

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
      child: Text(hex, style: monospaceTextStyle),
    );
  }
}
