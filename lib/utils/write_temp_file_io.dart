import 'dart:io' as io;
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

Future<String> saveBytesToTempFile(Uint8List bytes, String fileName) async {
  final dir = await getTemporaryDirectory();
  final path = '${dir.path}/$fileName';
  final f = io.File(path);
  await f.writeAsBytes(bytes, flush: true);
  return path;
}
