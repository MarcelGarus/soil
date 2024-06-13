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

    final tableViewKey = useGlobalKey();
    final verticalController = useScrollController();

    double offsetToY(Word offset) {
      final rowsAbove = state.instructions
          .where((it) => it.$1 < offset)
          .map((it) => _getLabel(it.$1) == null ? 1 : 2)
          .sum;
      final rows = _getLabel(offset) == null ? 1 : 2;
      return (rowsAbove + rows / 2) * _rowHeight;
    }

    final previousProgramCounter = usePrevious(state.vm.programCounter);
    if (previousProgramCounter != state.vm.programCounter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          verticalController.animateTo(
            offsetToY(state.vm.programCounter) -
                tableViewKey.currentContext!.size!.height / 2,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeInOut,
          ),
        );
      });
    }

    final table = TableView.builder(
      key: tableViewKey,
      verticalDetails:
          ScrollableDetails.vertical(controller: verticalController),
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
                  _getLabel(offset) == null ? 0 : _rowHeight,
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
          final label = _getLabel(offset);
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

    return Scrollbar(controller: verticalController, child: table);
  }

  String? _getLabel(Word offset) => state.vm.binary.labels?[offset];
}
