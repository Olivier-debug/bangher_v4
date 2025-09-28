// Reusable profile photo cropper dialog.
// - Separate from pages for testability and reuse.
// - ExtendedImage editor (4:5 aspect by default).
// - Crops/rotates/flips in an isolate; pre-resizes huge images for speed.
// - Returns compressed JPG bytes.

import 'dart:ui' as ui;

import 'package:extended_image/extended_image.dart';
import 'package:flutter/foundation.dart'; // compute, Uint8List
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

// Downscale to speed up the crop UI and encoding.
// Use PNG here to preserve pixels pre-encode; we’ll JPEG after crop.
Future<Uint8List> downscaleImageBytes(Uint8List bytes, {int maxDim = 2000}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frameInfo = await codec.getNextFrame();
  final w = frameInfo.image.width, h = frameInfo.image.height;
  final larger = w > h ? w : h;
  if (larger <= maxDim) return bytes;

  final scale = maxDim / larger;
  final targetW = (w * scale).round();
  final targetH = (h * scale).round();

  final codec2 = await ui.instantiateImageCodec(
    bytes,
    targetWidth: targetW,
    targetHeight: targetH,
  );
  final frame2 = await codec2.getNextFrame();
  final bd = await frame2.image.toByteData(format: ui.ImageByteFormat.png);
  return Uint8List.view(bd!.buffer);
}

Future<Uint8List?> showProfilePhotoCropper(
  BuildContext context, {
  required Uint8List sourceBytes,
  double aspectRatio = 4 / 5,
  int jpegQuality = 86,
}) {
  return showDialog<Uint8List>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PhotoCropperDialog(
      sourceBytes: sourceBytes,
      aspectRatio: aspectRatio,
      jpegQuality: jpegQuality,
    ),
  );
}

class _PhotoCropperDialog extends StatefulWidget {
  const _PhotoCropperDialog({
    required this.sourceBytes,
    required this.aspectRatio,
    required this.jpegQuality,
  });

  final Uint8List sourceBytes;
  final double aspectRatio;
  final int jpegQuality;

  @override
  State<_PhotoCropperDialog> createState() => _PhotoCropperDialogState();
}

class _PhotoCropperDialogState extends State<_PhotoCropperDialog> {
  final _editorKey = GlobalKey<ExtendedImageEditorState>();
  final _controller = ImageEditorController();
  final _canConfirm = ValueNotifier<bool>(false);
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    _canConfirm.dispose();
    super.dispose();
  }

  Future<void> _doCrop() async {
    final state = _editorKey.currentState;
    if (state == null) return;

    setState(() => _busy = true);
    try {
      final bytes = await _cropImageInIsolate(
        state: state,
        quality: widget.jpegQuality,
        maxDimension: 1800, // pre-resize huge images before crop/encode
      );
      if (!mounted) return;
      Navigator.of(context).pop(bytes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Crop failed: $e'), backgroundColor: Colors.red),
      );
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final aspect = widget.aspectRatio;
    return Dialog(
      backgroundColor: const Color(0xFF0A0A0A),
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 780),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text('Edit photo',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Reset',
                        onPressed: _busy
                            ? null
                            : () {
                                _controller.reset();
                                _controller.updateCropAspectRatio(aspect);
                                HapticFeedback.lightImpact();
                              },
                        icon: const Icon(Icons.restore, color: Colors.white70),
                      ),
                      IconButton(
                        tooltip: 'Rotate 90°',
                        onPressed: _busy
                            ? null
                            : () {
                                _controller.rotate();
                                HapticFeedback.selectionClick();
                              },
                        icon: const Icon(Icons.rotate_90_degrees_ccw, color: Colors.white70),
                      ),
                      IconButton(
                        tooltip: 'Flip',
                        onPressed: _busy
                            ? null
                            : () {
                                _controller.flip();
                                HapticFeedback.selectionClick();
                              },
                        icon: const Icon(Icons.flip, color: Colors.white70),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        color: Colors.black,
                        child: ExtendedImage.memory(
                          widget.sourceBytes,
                          fit: BoxFit.contain,
                          mode: ExtendedImageMode.editor,
                          filterQuality: FilterQuality.high,
                          extendedImageEditorKey: _editorKey,
                          cacheRawData: true,
                          loadStateChanged: (s) {
                            if (s.extendedImageLoadState == LoadState.completed) {
                              if (!_canConfirm.value) {
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (mounted) _canConfirm.value = true;
                                });
                              }
                            }
                            return null;
                          },
                          initEditorConfigHandler: (_) {
                            return EditorConfig(
                              maxScale: 8.0,
                              cropRectPadding: const EdgeInsets.all(16),
                              hitTestSize: 24,
                              lineColor: Colors.white70,
                              editorMaskColorHandler: (context, down) =>
                                  const Color(0xFF000000),
                              cropAspectRatio: aspect,
                              initCropRectType: InitCropRectType.imageRect,
                              cropLayerPainter: const EditorCropLayerPainter(),
                              controller: _controller,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Spacer(),
                      TextButton(
                        onPressed: _busy ? null : () => Navigator.of(context).pop(),
                        child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                      ),
                      const SizedBox(width: 8),
                      ValueListenableBuilder<bool>(
                        valueListenable: _canConfirm,
                        builder: (_, canUse, __) {
                          final disabled = _busy || !canUse;
                          return FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: disabled ? const Color(0xFF4A4C53) : const Color(0xFFFF2D88),
                            ),
                            onPressed: disabled ? null : _doCrop,
                            child: disabled && _busy
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Text('Use photo', style: TextStyle(color: Colors.white)),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_busy)
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  child: const Center( 
                    child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// -------- isolate-backed crop pipeline (fast + memory-safe) --------

Future<Uint8List> _cropImageInIsolate({
  required ExtendedImageEditorState state,
  required int quality,
  required int maxDimension,
}) async {
  final Rect? cropRect = state.getCropRect();
  final EditActionDetails action = state.editAction!;
  final Uint8List data = state.rawImageData;

  final m = <String, dynamic>{
    'bytes': data,
    'crop': cropRect == null
        ? null
        : {
            'x': cropRect.left.round(),
            'y': cropRect.top.round(),
            'w': cropRect.width.round(),
            'h': cropRect.height.round(),
          },
    'rotate': action.rotateDegrees,
    'flipY': action.flipY,
    'quality': quality,
    'maxDim': maxDimension,
  };
  return compute(_cropEncodeIsolate, m);
}

Future<Uint8List> _cropEncodeIsolate(Map<String, dynamic> m) async {
  final Uint8List bytes = m['bytes'] as Uint8List;
  final Map<String, Object?>? crop = m['crop'] as Map<String, Object?>?;
  final double rotateDeg = (m['rotate'] as num?)?.toDouble() ?? 0.0;
  final bool flipY = (m['flipY'] as bool?) ?? false;
  final int qualityIn = (m['quality'] as int?) ?? 92;
  final int maxDim = (m['maxDim'] as int?) ?? 3000;

  img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw Exception('Unsupported image format');
  }

  img.Image image = img.bakeOrientation(decoded);

  // pre-resize huge images to speed up crop/encode
  final int w = image.width, h = image.height;
  final int larger = w > h ? w : h;
  if (larger > maxDim) {
    final scale = maxDim / larger;
    image = img.copyResize(image, width: (w * scale).round(), height: (h * scale).round());
  }

  if (rotateDeg != 0) {
    image = img.copyRotate(image, angle: rotateDeg);
  }
  if (flipY) {
    image = img.flipHorizontal(image);
  }

  if (crop != null) {
    final int x = (crop['x'] as num).toInt().clamp(0, image.width - 1);
    final int y = (crop['y'] as num).toInt().clamp(0, image.height - 1);
    final int cw = (crop['w'] as num).toInt().clamp(1, image.width - x);
    final int ch = (crop['h'] as num).toInt().clamp(1, image.height - y);
    image = img.copyCrop(image, x: x, y: y, width: cw, height: ch);
  }

  final int q = qualityIn.clamp(1, 100);
  final List<int> jpg = img.encodeJpg(image, quality: q); 
  return Uint8List.fromList(jpg);
}