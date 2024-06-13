import 'package:soil_vm/soil_vm.dart';
import 'package:supernova_flutter/supernova_flutter.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import '../main.dart';
import '../vm_state.dart';
import 'registers.dart';

class InstructionsWidget extends HookWidget {
  const InstructionsWidget(this.state, {super.key});

  static const _columnCount = 3;
  static const _rowHeight = 16.0;

  final VMState state;

  @override
  Widget build(BuildContext context) {
    useListenable(state);

    return TableView.builder(
      columnCount: _columnCount,
      columnBuilder: (index) => TableSpan(
        extent: switch (index) {
          0 => const FixedTableSpanExtent(192),
          1 => const FixedTableSpanExtent(256),
          2 => const RemainingSpanExtent(),
          _ => throw StateError('Invalid column index'),
        },
      ),
      rowCount: 2 * state.instructions.length,
      rowBuilder: (index) {
        final (offset, _) = state.instructions[index ~/ 2];
        return index.isEven
            ? TableSpan(
                extent: FixedTableSpanExtent(
                  state.vm.binary.labels?.containsKey(offset) ?? false
                      ? _rowHeight
                      : 0,
                ),
              )
            : TableSpan(
                extent: const FixedTableSpanExtent(_rowHeight),
                backgroundDecoration: offset == state.vm.programCounter
                    ? SpanDecoration(color: Colors.yellow.withOpacity(0.5))
                    : null,
              );
      },
      cellBuilder: (context, vicinity) {
        final (offset, instruction) = state.instructions[vicinity.row ~/ 2];
        if (vicinity.row.isEven) {
          final label = state.vm.binary.labels?[offset];
          return TableViewCell(
            columnMergeStart: 0,
            columnMergeSpan: _columnCount,
            child: label == null ? const SizedBox.shrink() : Text('$label:'),
          );
        }

        return TableViewCell(
          child: switch (vicinity.column) {
            0 => WordWidget(offset),
            1 => Row(
                children: Iterable<Widget>.generate(
                  instruction.lengthInBytes.value,
                  (it) =>
                      ByteWidget(state.vm.binary.byteCode[offset + Word(it)]),
                ).withSeparators(const SizedBox(width: 2)).toList(),
              ),
            2 => Align(
                alignment: Alignment.centerLeft,
                child: InstructionWidget(instruction),
              ),
            _ => throw StateError('Invalid column index'),
          },
        );
      },
    );
  }
}
