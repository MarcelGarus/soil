import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:soil_vm/soil_vm.dart';
import 'package:supernova_flutter/supernova_flutter.dart' hide Bytes;

import 'vm_state.dart';
import 'widgets/registers.dart';
import 'widgets/toolbar.dart';

final monospaceTextStyle = GoogleFonts.firaCode();

Future<void> main() async {
  await initSupernova(shouldInitializeTimeMachine: false);

  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: VMPage(),
    );
  }
}

class VMPage extends HookWidget {
  const VMPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = useState<VMState?>(null);

    final file = useState<PlatformFile?>(null);
    final error = useState<String?>(null);

    void handleFileSelected(PlatformFile selectedFile) {
      file.value = selectedFile;

      final binaryResult = Parser.parse(Bytes(selectedFile.bytes!));
      if (binaryResult.isErr()) {
        error.value = binaryResult.unwrapErr();
        return;
      }
      state.value = VMState(binaryResult.unwrap());
      error.value = null;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Soil VM')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _FileSelection(
              file: file.value,
              onFileSelected: handleFileSelected,
            ),
            if (error.value != null) ...[
              const SizedBox(height: 16),
              Text(
                error.value!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (state.value != null) ...[
              const SizedBox(height: 16),
              Expanded(child: _VMWidget(state.value!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _FileSelection extends HookWidget {
  const _FileSelection({required this.file, required this.onFileSelected});

  final PlatformFile? file;
  final ValueSetter<PlatformFile> onFileSelected;

  @override
  Widget build(BuildContext context) {
    Future<void> openFile() async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['soil'],
        withData: true,
      );
      if (result == null) return;

      onFileSelected(result.files.single);
    }

    return Row(
      children: [
        ElevatedButton(
          onPressed: openFile,
          child: const Text('Open Soil file'),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            file == null
                ? 'No file selected'
                : kIsWeb
                    ? file!.name
                    : file!.path!,
          ),
        ),
      ],
    );
  }
}

class _VMWidget extends HookWidget {
  const _VMWidget(this.state);

  final VMState state;

  @override
  Widget build(BuildContext context) {
    useListenable(state);

    final statusWidget = state.vm.status.when(
      running: () {
        final status = state.isRunning ? 'Running' : 'Paused';
        final instruction = state.vm
            .decodeNextInstruction()
            .map<InlineSpan>(InstructionSpan.new)
            .unwrapOrElse((it) => TextSpan(text: it));
        return Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '$status at '),
              WordSpan(state.vm.programCounter),
              const TextSpan(text: ': '),
              instruction,
            ],
          ),
        );
      },
      exited: (exitCode) => Text('Exited with code $exitCode'),
      panicked: () => const Text('Panicked'),
      error: (error) => Text('Error: $error'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Toolbar(state),
            const SizedBox(width: 16),
            Expanded(child: statusWidget),
          ],
        ),
        const SizedBox(height: 16),
        Text('Elapsed time: ${state.elapsedTime}'),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: RegistersWidget(state.vm),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border.fromBorderSide(BorderSide()),
            ),
            child: CustomPaint(painter: state.syscalls.canvas),
          ),
        ),
      ],
    );
  }
}

class InstructionSpan extends WidgetSpan {
  InstructionSpan(Instruction instruction)
      : super(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: InstructionWidget(instruction),
        );
}

class InstructionWidget extends StatelessWidget {
  const InstructionWidget(this.instruction, {super.key});

  final Instruction instruction;

  @override
  Widget build(BuildContext context) {
    final binary = instruction.toString(base: Base.binary);
    final decimal = instruction.toString(base: Base.decimal);
    final hex = instruction.toString();

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
      child: Text(
        instruction.toString(),
        style: monospaceTextStyle,
      ),
    );
  }
}
