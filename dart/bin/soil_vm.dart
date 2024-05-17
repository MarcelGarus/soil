import 'package:soil_vm/soil_vm.dart';
import 'package:supernova/supernova.dart' hide Bytes;
import 'package:supernova/supernova_io.dart';

Future<void> main(List<String> arguments) async {
  await initSupernova(shouldInitializeTimeMachine: false);

  if (arguments.length != 1) {
    logger.error('Usage: soil_vm file.soil');
    return;
  }

  final file = File(arguments.single);
  final bytes = await file.readAsBytes();

  logger.info('Parsing Soil binary: ${file.path}…');
  final soilBinary = Parser.parse(Bytes(bytes)).unwrap();
  logger.info('Parsed Soil binary: $soilBinary');

  final vm = VM(soilBinary, const DefaultSyscalls(arguments: []));
  vm.runForever();
}
