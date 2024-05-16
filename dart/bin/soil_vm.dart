import 'package:soil_vm/soil_vm.dart';
import 'package:supernova/supernova.dart';
import 'package:supernova/supernova_io.dart';

Future<void> main(List<String> arguments) async {
  await initSupernova(shouldInitializeTimeMachine: false);

  if (arguments.length != 1) {
    logger.error('Usage: soil_vm file.soil');
    return;
  }
  final bytes = await File(arguments.single).readAsBytes();
  final parsed = Parser.parse(bytes).unwrap();
  logger.info('Parsed Soil binary: $parsed');
}
