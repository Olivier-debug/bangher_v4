// =========================
// FILE: lib/features/confessions/ui/composer_sheet.dart
// =========================

import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../theme/app_theme.dart' as theme;
import '../data/confession_models.dart';
import '../data/confession_repo.dart';

const _topics = <String>['Love', 'Campus', 'Work', 'Family', 'Money', 'Friends', 'Random'];
const _languages = <String>['English', 'Afrikaans', 'Zulu', 'Xhosa', 'Sotho', 'French', 'Spanish'];
const _seedPrompts = <String>[
  "Today I realized…",
  "My hottest take is…",
  "I can't tell my friends that…",
  "I feel guilty because…",
  "If I could go back, I'd…",
  "The pettiest thing I did was…",
  "Lowkey, I love it when…",
  "I lied about… and now…",
];

class ComposerSheet extends StatefulWidget {
  const ComposerSheet({super.key, this.existing});
  final ConfessionItem? existing;

  @override
  State<ComposerSheet> createState() => _ComposerSheetState();
}

class _ComposerSheetState extends State<ComposerSheet> {
  final _repo = ConfessionRepository();
  final _text = TextEditingController();
  final _picker = ImagePicker();

  XFile? _picked;
  bool _anon = false;
  bool _posting = false;
  String _topic = 'Random';
  String _language = 'English';
  bool _nsfw = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _text.text = e.content;
      _topic = e.topic;
      _language = e.language;
      _nsfw = e.nsfw;
      _anon = e.isAnonymous;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final x = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 2000,
      );
      if (!mounted) return; // guard after async gap
      if (x != null) {
        setState(() => _picked = x);
      }
    } catch (_) {
      // ignore
    }
  }

  void _seedPrompt() {
    final seed = (_seedPrompts.toList()..shuffle()).first; // avoid mutating const list
    final t = _text.text;
    if (t.trim().isEmpty) {
      _text.text = '$seed\n';
    } else {
      _text.text = '$t\n$seed\n';
    }
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
    setState(() {});
  }

  Future<String?> _uploadPicked() async {
    if (_picked == null) return widget.existing?.imageUrl;
    final bytes = await _picked!.readAsBytes();
    final ext = _picked!.name.split('.').last.toLowerCase();
    final me = Supabase.instance.client.auth.currentUser?.id ?? 'anon';
    final path = 'u_$me/${DateTime.now().millisecondsSinceEpoch}.${ext.isEmpty ? 'jpg' : ext}';
    return _repo.uploadImageToPublicBucket(
      bucket: 'confessions',
      fileName: path,
      bytes: bytes,
      contentType: _inferContentType(bytes, ext),
    );
  }

  String _inferContentType(Uint8List _, String ext) {
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'jpg':
      case 'jpeg':
      default:
        return 'image/jpeg';
    }
  }

  Future<void> _submit() async {
    if (_posting) return;
    final content = _text.text.trim();
    if (content.isEmpty && _picked == null && widget.existing?.imageUrl == null) return;

    setState(() => _posting = true);

    try {
      final imageUrl = await _uploadPicked();

      late final ConfessionItem result;
      if (widget.existing == null) {
        result = await _repo.insertConfession(
          content: content,
          topic: _topic,
          language: _language,
          nsfw: _nsfw,
          isAnonymous: _anon,
          imageUrl: imageUrl,
        );
      } else {
        final removeExistingImage =
            _picked == null && widget.existing?.imageUrl != null && imageUrl == null;
        result = await _repo.updateConfession(
          confessionId: widget.existing!.id,
          content: content,
          topic: _topic,
          language: _language,
          nsfw: _nsfw,
          isAnonymous: _anon,
          imageUrl: imageUrl,
          removeImage: removeExistingImage,
        );
      }

      if (!mounted) return; // guard State.context usage after awaits
      Navigator.of(context).pop<ConfessionItem>(result);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn’t submit. Check your connection and try again.")),
      );
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final isEdit = widget.existing != null;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Container(
        decoration: const BoxDecoration(
          color: theme.AppTheme.ffPrimaryBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          boxShadow: [BoxShadow(blurRadius: 20, color: Colors.black54)],
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 4,
              width: 40,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            Row(
              children: [
                const Icon(Icons.auto_awesome, color: theme.AppTheme.ffPrimary),
                const SizedBox(width: 8),
                Text(
                  isEdit ? 'Edit confession' : 'New confession',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Row(
                  children: [
                    const Icon(Icons.person_outline, color: Colors.white54, size: 16),
                    const SizedBox(width: 6),
                    Switch(
                      value: _anon,
                      onChanged: (v) => setState(() => _anon = v),
                      thumbIcon: WidgetStateProperty.resolveWith(
                        (_) => Icon(_anon ? Icons.visibility_off : Icons.person),
                      ),
                      thumbColor: WidgetStateProperty.all(Colors.white),
                      trackColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? theme.AppTheme.ffPrimary
                            : Colors.white24,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _text,
              maxLines: 6,
              minLines: 3,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: "What's on your mind?",
                hintStyle: TextStyle(color: Colors.white54),
                border: InputBorder.none,
              ),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _SmallDropdown<String>(
                    value: _topic,
                    items: _topics,
                    icon: Icons.label_outline,
                    onChanged: (v) => setState(() => _topic = v ?? _topic),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SmallDropdown<String>(
                    value: _language,
                    items: _languages,
                    icon: Icons.language,
                    onChanged: (v) => setState(() => _language = v ?? _language),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Mark as sensitive (NSFW)',
                  child: FilterChip(
                    label: const Text('NSFW'),
                    selected: _nsfw,
                    onSelected: (v) => setState(() => _nsfw = v),
                    selectedColor: Colors.red.withValues(alpha: .35),
                    backgroundColor: const Color(0xFF141414),
                    labelStyle: TextStyle(color: _nsfw ? Colors.white : Colors.white70),
                    side: BorderSide(color: Colors.red.withValues(alpha: .35)),
                  ),
                ),
              ],
            ),
            if (_picked != null || widget.existing?.imageUrl != null) ...[
              const SizedBox(height: 12),
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _picked != null
                        ? FutureBuilder<Uint8List>(
                            future: _picked!.readAsBytes(),
                            builder: (context, snap) => SizedBox(
                              height: 180,
                              width: double.infinity,
                              child: snap.hasData
                                  ? Image.memory(snap.data!, fit: BoxFit.cover)
                                  : Container(color: const Color(0xFF202227)),
                            ),
                          )
                        : CachedNetworkImage(
                            imageUrl: widget.existing!.imageUrl!,
                            height: 180,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(color: const Color(0xFF202227)),
                          ),
                  ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Material(
                      color: Colors.black.withValues(alpha: .35),
                      borderRadius: BorderRadius.circular(10),
                      child: IconButton(
                        tooltip: 'Remove image',
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => setState(() {
                          _picked = null;
                          // If editing, removal is handled by patch in _submit().
                        }),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _seedPrompt,
                  icon: const Icon(Icons.auto_awesome, color: Colors.white),
                  label: const Text('Prompt', style: TextStyle(color: Colors.white)),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.photo, color: Colors.white),
                  label: const Text('Photo', style: TextStyle(color: Colors.white)),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _posting ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.AppTheme.ffPrimary,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: _posting
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(isEdit ? Icons.check : Icons.send, size: 18, color: Colors.white),
                  label: Text(
                    isEdit ? 'Save' : 'Post',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallDropdown<T> extends StatelessWidget {
  const _SmallDropdown({
    required this.value,
    required this.items,
    required this.icon,
    required this.onChanged,
  });

  final T value;
  final List<T> items;
  final IconData icon;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF121316),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.AppTheme.ffAlt.withValues(alpha: .35)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          icon: const Icon(Icons.expand_more, color: Colors.white70, size: 18),
          dropdownColor: const Color(0xFF0E0F11),
          onChanged: onChanged,
          items: items
              .map(
                (e) => DropdownMenuItem<T>(
                  value: e,
                  child: Row(
                    children: [
                      Icon(icon, color: Colors.white54, size: 16),
                      const SizedBox(width: 6),
                      Text(e.toString(), style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}
