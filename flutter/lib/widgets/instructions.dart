import 'package:soil_vm/soil_vm.dart';
import 'package:supernova_flutter/supernova_flutter.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import '../main.dart';
import '../vm_state.dart';
import 'registers.dart';

class InstructionsWidget extends StatelessWidget {
  const InstructionsWidget(this.state, {super.key});

  final VMState state;

  @override
  Widget build(BuildContext context) {
    return TableView.builder(
      columnCount: 3,
      columnBuilder: (index) => TableSpan(
        extent: switch (index) {
          0 => const FixedTableSpanExtent(192),
          1 => const FixedTableSpanExtent(256),
          2 => const RemainingSpanExtent(),
          _ => throw StateError('Invalid column index'),
        },
      ),
      rowCount: state.instructions.length,
      rowBuilder: (index) => const TableSpan(extent: FixedTableSpanExtent(16)),
      cellBuilder: (context, vicinity) {
        final (offset, instruction) = state.instructions[vicinity.row];
        return TableViewCell(
          child: switch (vicinity.column) {
            0 => WordWidget(offset),
            1 => Row(
                children: Iterable<Widget>.generate(
                  instruction.lengthInBytes.value,
                  (it) =>
                      ByteWidget(state.vm.binary.byteCode[offset + Word(it)]),
                ).withSeparators(const SizedBox(width: 4)).toList(),
              ),
            2 => InstructionWidget(instruction),
            _ => throw StateError('Invalid column index'),
          },
        );
      },
    );
  }
}
