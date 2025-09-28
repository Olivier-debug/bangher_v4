// Web stub — we don’t write to disk; callers must pass bytes.
import 'dart:typed_data';

Future<String> saveBytesToTempFile(Uint8List bytes, String fileName) async {
  // Not supported on web; return an empty path and let the caller use [bytes].
  return '';
}
