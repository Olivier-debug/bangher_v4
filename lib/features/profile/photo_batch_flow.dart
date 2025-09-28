// lib/features/profile/photo_batch_flow.dart
// Multi-select picker → crop each → upload to Supabase with slick UX.
// Requires: image_picker, file_picker (for web), supabase_flutter, your showProfilePhotoCropper().

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:supabase_flutter/supabase_flutter.dart';

// Reuse your existing cropper dialog:
import '../../widgets/photo_cropper_dialog.dart';
import '../swipe/presentation/swipe_models.dart' show kProfileBucket;

/// Simple return type so caller can update DB.
class BatchUploadResult {
  final List<String> storagePaths; // e.g. "profile_pictures/uid/....jpg"
  final List<String> publicOrSignedUrls; // mirrors order, maybe empty if you opt-out
  const BatchUploadResult({
    required this.storagePaths,
    required this.publicOrSignedUrls,
  });
}

enum _ItemState { queued, cropping, uploading, done, failed, skipped }

class _BatchItem {
  final String name;
  final Uint8List bytes; // original
  Uint8List? cropped; // after crop
  _ItemState state = _ItemState.queued;
  String? storagePath;
  String? url;
  String? error;
  _BatchItem(this.name, this.bytes);
}

/// Public API: shows a bottom sheet that drives the entire flow and returns uploaded paths/urls.
Future<BatchUploadResult?> pickCropAndUploadPhotos(
  BuildContext context, {
  required String userId,
  int maxCount = 9,
  String bucket = kProfileBucket,
  bool returnSignedUrls = false,
  Duration signedExpiry = const Duration(hours: 1),
}) async {
  final picked = await _pickMany(maxCount: maxCount);
  if (!context.mounted) return null; // guard after async gap
  if (picked.isEmpty) return null;

  final items = <_BatchItem>[
    for (final p in picked) _BatchItem(p.$1, p.$2),
  ];

  return showModalBottomSheet<BatchUploadResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF0E0F12),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => _BatchFlowSheet(
      userId: userId,
      bucket: bucket,
      items: items,
      returnSignedUrls: returnSignedUrls,
      signedExpiry: signedExpiry,
    ),
  );
}

/// Cross-platform multi-pick: ImagePicker for mobile/desktop, FilePicker for web.
/// Returns tuples of (displayName, bytes).
Future<List<(String, Uint8List)>> _pickMany({required int maxCount}) async {
  try {
    if (!kIsWeb) {
      final picker = ImagePicker();
      final files = await picker.pickMultiImage(
        limit: maxCount,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 92,
      );
      if (files.isEmpty) return const [];
      final out = <(String, Uint8List)>[];
      for (final f in files.take(maxCount)) {
        final b = await f.readAsBytes();
        out.add((f.name, b));
      }
      return out;
    } else {
      final res = await fp.FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
        type: fp.FileType.image,
      );
      if (res == null || res.files.isEmpty) return const [];
      final out = <(String, Uint8List)>[];
      for (final f in res.files.take(maxCount)) {
        final data = f.bytes;
        if (data != null && data.isNotEmpty) {
          out.add(((f.name), data));
        }
      }
      return out;
    }
  } catch (e) {
    // No BuildContext here: just log and let caller decide UI.
    debugPrint('Gallery/FilePicker error: $e');
    return const [];
  }
}

/// Bottom sheet that orchestrates crop → upload pipeline with status UI.
class _BatchFlowSheet extends StatefulWidget {
  const _BatchFlowSheet({
    required this.userId,
    required this.bucket,
    required this.items,
    required this.returnSignedUrls,
    required this.signedExpiry,
  });

  final String userId;
  final String bucket;
  final List<_BatchItem> items;
  final bool returnSignedUrls;
  final Duration signedExpiry;

  @override
  State<_BatchFlowSheet> createState() => _BatchFlowSheetState();
}

class _BatchFlowSheetState extends State<_BatchFlowSheet> {
  final _ctrl = ScrollController();
  bool _busy = false;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runPipeline());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _runPipeline() async {
    if (_busy) return;
    setState(() => _busy = true);

    final nav = Navigator.of(context); // capture synchronously

    final uploadQueue = <Future<void>>[];
    const maxConcurrent = 3;
    int inFlight = 0;

    Future<void> scheduleUpload(_BatchItem it) async {
      inFlight++;
      final client = Supabase.instance.client;
      try {
        final now = DateTime.now().millisecondsSinceEpoch;
        final rnd = Random();
        final filename = '${now}_${rnd.nextInt(0x7fffffff)}.jpg';
        final path = '${widget.userId}/$filename';

        await client.storage.from(widget.bucket).uploadBinary(
          path,
          it.cropped!, // bytes from cropper
          fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
        );

        it.storagePath = '${widget.bucket}/$path';
        it.url = widget.returnSignedUrls
            ? await client.storage.from(widget.bucket).createSignedUrl(
                path, widget.signedExpiry.inSeconds)
            : client.storage.from(widget.bucket).getPublicUrl(path);

        it.state = _ItemState.done;
      } catch (e) {
        it.state = _ItemState.failed;
        it.error = e.toString();
      } finally {
        if (mounted) setState(() {}); // refresh tile
        inFlight--;
      }
    }

    for (int i = 0; i < widget.items.length; i++) {
      if (_cancelled) break;
      if (!mounted) break; // guard before context usage

      final it = widget.items[i];

      // Crop
      setState(() => it.state = _ItemState.cropping);
      final smaller = await downscaleImageBytes(it.bytes, maxDim: 2000);
      if (!mounted || _cancelled) break;
      final cropped = await showProfilePhotoCropper(
        context,
        sourceBytes: smaller,
        aspectRatio: 4 / 5,
        jpegQuality: 86,
      );
      if (!mounted) break; // keep this one too
      if (_cancelled) break;
      if (cropped == null || cropped.isEmpty) {
        it.state = _ItemState.skipped;
        setState(() {});
        continue;
      }
      it.cropped = cropped;

      // Schedule upload with backpressure
      it.state = _ItemState.uploading;
      setState(() {});
      final fut = scheduleUpload(it);
      uploadQueue.add(fut);

      // backpressure loop
      while (inFlight >= maxConcurrent && mounted && !_cancelled) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // Auto-scroll to keep latest visible.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (mounted) {
        await _ctrl.animateTo(
          _ctrl.position.maxScrollExtent + 120,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    }

    await Future.wait(uploadQueue);

    setState(() => _busy = false);

    if (!_cancelled) {
      final paths = <String>[];
      final urls = <String>[];
      for (final it in widget.items) {
        if (it.state == _ItemState.done && it.storagePath != null) {
          paths.add(it.storagePath!);
          urls.add(it.url ?? '');
        }
      }
      if (mounted) {
        nav.pop(BatchUploadResult(
          storagePaths: paths,
          publicOrSignedUrls: urls,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final anyUploading = widget.items.any((e) => e.state == _ItemState.cropping || e.state == _ItemState.uploading);
    final done = widget.items.where((e) => e.state == _ItemState.done).length;
    final failed = widget.items.where((e) => e.state == _ItemState.failed).length;
    final total = widget.items.length;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              const Text('Add photos', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (anyUploading && !_cancelled)
                TextButton(
                  onPressed: () => setState(() => _cancelled = true),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                ),
              IconButton(
                tooltip: 'Close',
                onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close, color: Colors.white70),
              ),
            ]),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Processed $done of $total • ${failed > 0 ? "$failed failed" : "All good"}',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: GridView.builder(
                controller: _ctrl,
                shrinkWrap: true,
                physics: const BouncingScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: widget.items.length,
                itemBuilder: (_, i) {
                  final it = widget.items[i];
                  final imgBytes = it.cropped ?? it.bytes;
                  return _ThumbTile(item: it, hero: imgBytes);
                },
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: (_busy && !_cancelled) ? const Color(0xFF4A4C53) : const Color(0xFFFF2D88),
                ),
                onPressed: (_busy && !_cancelled)
                    ? null
                    : () {
                        final paths = <String>[];
                        final urls = <String>[];
                        for (final it in widget.items) {
                          if (it.state == _ItemState.done && it.storagePath != null) {
                            paths.add(it.storagePath!);
                            urls.add(it.url ?? '');
                          }
                        }
                        Navigator.of(context).pop(BatchUploadResult(storagePaths: paths, publicOrSignedUrls: urls));
                      },
                child: (_busy && !_cancelled)
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Done', style: TextStyle(color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThumbTile extends StatelessWidget {
  const _ThumbTile({required this.item, required this.hero});
  final _BatchItem item;
  final Uint8List hero;

  Color _badgeColor(_ItemState s) {
    switch (s) {
      case _ItemState.queued:
        return const Color(0xFF3A3D44);
      case _ItemState.cropping:
        return const Color(0xFF0066FF);
      case _ItemState.uploading:
        return const Color(0xFF8E44AD);
      case _ItemState.done:
        return const Color(0xFF00E676);
      case _ItemState.failed:
        return const Color(0xFFFF3B30);
      case _ItemState.skipped:
        return const Color(0xFFB0B0B0);
    }
  }

  String _badgeText(_ItemState s) {
    switch (s) {
      case _ItemState.queued:
        return 'Queued';
      case _ItemState.cropping:
        return 'Cropping';
      case _ItemState.uploading:
        return 'Uploading';
      case _ItemState.done:
        return 'Done';
      case _ItemState.failed:
        return 'Failed';
      case _ItemState.skipped:
        return 'Skipped';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(hero, fit: BoxFit.cover),
          ),
        ),
        Positioned(
          left: 6,
          bottom: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .45),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: .10)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: _badgeColor(item.state), shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(_badgeText(item.state), style: const TextStyle(color: Colors.white, fontSize: 12)),
            ]),
          ),
        ),
        if (item.state == _ItemState.failed && item.error != null)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: .5), borderRadius: BorderRadius.circular(10)),
              child: const Center(child: Icon(Icons.error_outline, color: Colors.redAccent, size: 28)),
            ),
          ),
      ],
    );
  }
}