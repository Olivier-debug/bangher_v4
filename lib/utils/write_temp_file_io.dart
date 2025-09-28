// Non-web: persist bytes to a temporary file and return its path.
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String> saveBytesToTempFile(Uint8List bytes, String fileName) async {
  final dir = await getTemporaryDirectory();
  final f = io.File(p.join(dir.path, fileName));
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}
