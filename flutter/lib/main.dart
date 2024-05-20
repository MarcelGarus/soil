import 'package:file_picker/file_picker.dart';
import 'package:soil_vm/soil_vm.dart';
import 'package:supernova_flutter/supernova_flutter.dart' hide Bytes;

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
    final file = useState<PlatformFile?>(null);
    final error = useState<String?>(null);
    final binary = useState<SoilBinary?>(null);

    return Scaffold(
      appBar: AppBar(title: const Text('Soil VM')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _FileSelection(
              file: file.value,
              onFileSelected: (it) {
                file.value = it;

                final binaryResult = Parser.parse(Bytes(it.bytes!));
                if (binaryResult.isErr()) {
                  error.value = binaryResult.unwrapErr();
                  return;
                }
                binary.value = binaryResult.unwrap();
                error.value = null;
              },
            ),
            if (error.value != null) ...[
              const SizedBox(height: 16),
              Text(
                error.value!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (binary.value != null) ...[
              const SizedBox(height: 16),
              Expanded(child: _VMWidget(binary.value!)),
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
  const _VMWidget(this.binary);

  final SoilBinary binary;

  @override
  Widget build(BuildContext context) {
    final vm =
        useMemoized(() => VM(binary, DefaultSyscalls(arguments: [])), [binary]);
    final vmStatus = useState(vm.status);
    useEffect(
      () {
        var continueRunning = true;
        Future(() async {
          while (continueRunning && vm.status.isRunning) {
            vm.runInstructions(100);
            vmStatus.value = vm.status;

            await Future<void>.value();
          }
        });
        return () => continueRunning = false;
      },
      [vm],
    );

    return Text('VM Status: ${vmStatus.value}');
  }
}
