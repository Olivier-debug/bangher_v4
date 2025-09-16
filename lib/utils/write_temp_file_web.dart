import 'dart:typed_data';

Future<String> saveBytesToTempFile(Uint8List bytes, String fileName) async {
  // Not used on web (we upload bytes directly). Return a harmless token.
  return fileName;
}
