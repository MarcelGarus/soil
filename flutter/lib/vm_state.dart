import 'dart:ui' as ui;

import 'package:soil_vm/soil_vm.dart';
import 'package:supernova_flutter/supernova_flutter.dart' hide Bytes;

class VMState with ChangeNotifier {
  VMState(SoilBinary binary) : this._(binary, FlutterSyscalls());
  VMState._(this._binary, this._syscalls) : _vm = VM(_binary, _syscalls);

  FlutterSyscalls _syscalls;
  FlutterSyscalls get syscalls => _syscalls;

  SoilBinary _binary;
  VM _vm;
  VM get vm => _vm;

  var _isRunning = false;
  bool get isRunning => _isRunning;

  void play() {
    if (isRunning) return;

    _isRunning = true;
    unawaited(_run());
    notifyListeners();
  }

  void pause() {
    if (!isRunning) return;

    _isRunning = false;
    notifyListeners();
  }

  Future<void> _run() async {
    final vm = this.vm;
    while (isRunning && vm.status.isRunning) {
      vm.runInstructions(100);
      notifyListeners();

      // Give the UI some time to update
      await Future<void>.delayed(const Duration(milliseconds: 17));
    }
  }

  void step() {
    assert(!isRunning);
    assert(vm.status.isRunning);
    vm.runInstruction();
    notifyListeners();
  }

  void restart() {
    _syscalls = FlutterSyscalls();
    _vm = VM(_binary, syscalls);
    _isRunning = false;
    notifyListeners();
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
