import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:soil_vm/soil_vm.dart';
import 'package:supernova_flutter/supernova_flutter.dart' hide Bytes;

import 'registers.dart';

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

    void handleFileSelected(PlatformFile selectedFile) {
      file.value = selectedFile;

      final binaryResult = Parser.parse(Bytes(selectedFile.bytes!));
      if (binaryResult.isErr()) {
        error.value = binaryResult.unwrapErr();
        return;
      }
      binary.value = binaryResult.unwrap();
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
    final syscalls = useMemoized(FlutterSyscalls.new, []);
    final vm = useMemoized(() => VM(binary, syscalls), [binary]);
    final rebuild = useRebuildRequest();
    useEffect(
      () {
        var continueRunning = true;
        Future(() async {
          while (continueRunning && vm.status.isRunning) {
            vm.runInstructions(100);
            rebuild.request();

            await Future<void>.delayed(const Duration(milliseconds: 17));
          }
        });
        return () => continueRunning = false;
      },
      [vm],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('VM Status: ${vm.status}'),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: RegistersWidget(vm.registers),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border.fromBorderSide(BorderSide()),
            ),
            child: CustomPaint(painter: syscalls.canvas),
          ),
        ),
      ],
    );
  }
}

class FlutterSyscalls extends DefaultSyscalls {
  FlutterSyscalls() : super(arguments: []);

  final canvas = VMCanvas();

  @override
  UiSize uiDimensions() => canvas.uiDimensions();
  @override
  void uiRender(Bytes buffer, UiSize size) =>
      unawaited(canvas.uiRender(buffer, size));
}

class VMCanvas extends CustomPainter {
  VMCanvas() : this._(ChangeNotifier());
  VMCanvas._(this._notifier) : super(repaint: _notifier);

  ChangeNotifier _notifier;

  Size? _lastSize;
  UiSize uiDimensions() {
    if (_lastSize == null) return const UiSize.square(Word(100));

    final size = _lastSize! / 10;
    return UiSize(Word(size.width.toInt()), Word(size.height.toInt()));
  }

  final _paint = Paint();
  ui.Image? _renderedImage;
  Future<void> uiRender(Bytes buffer, UiSize size) async {
    if (size.width == const Word(0) || size.height == const Word(0)) return;

    final convertedBuffer = Uint8List(size.area.value * 4);
    for (var i = 0; i < size.area.value; i++) {
      convertedBuffer[4 * i] = buffer[Word(3 * i)].value;
      convertedBuffer[4 * i + 1] = buffer[Word(3 * i + 1)].value;
      convertedBuffer[4 * i + 2] = buffer[Word(3 * i + 2)].value;
      convertedBuffer[4 * i + 3] = 255;
    }

    // ignore: discarded_futures
    final descriptor = ui.ImageDescriptor.raw(
      await ui.ImmutableBuffer.fromUint8List(convertedBuffer),
      width: size.width.value,
      height: size.height.value,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frameInfo = await codec.getNextFrame();
    _renderedImage = frameInfo.image;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    _notifier.notifyListeners();
  }

  @override
  void paint(Canvas canvas, Size size) {
    _lastSize = size;

    if (_renderedImage == null) return;

    canvas.save();
    canvas.scale(
      size.width / _renderedImage!.width,
      size.height / _renderedImage!.height,
    );
    canvas.drawImage(_renderedImage!, Offset.zero, _paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) =>
      this != oldDelegate;
}
