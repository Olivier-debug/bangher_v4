// ============================================================================
// FILE: lib/features/matches/matches_screen.dart
// PURPOSE: Simple Matches list; tap goes to Chat.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'match_repository.dart';

class MatchesScreen extends ConsumerWidget {
  const MatchesScreen({super.key});
  static const routeName = '/matches';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meId = Supabase.instance.client.auth.currentUser?.id;
    if (meId == null) {
      return const Scaffold(body: Center(child: Text('Sign in to see matches')));
    }

    final stream = ref.watch(StreamProvider.autoDispose((_) {
      return ref.read(matchRepositoryProvider).watchMyMatches(meId);
    }));

    return Scaffold(
      appBar: AppBar(title: const Text('Matches'), centerTitle: true),
      body: stream.when(
        data: (items) {
          if (items.isEmpty) {
            return const _Empty();
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, i) {
              final it = items[i];
              final other = it.other;
              return ListTile(
                leading: _Avatar(url: other?.photoUrl),
                title: Text(other?.name ?? 'User'),
                subtitle: Text(_fmt(it.createdAt)),
                onTap: () async {
                  final repo = ref.read(matchRepositoryProvider);
                  final id = it.matchId ??
                      await repo.getOrFetchMatchId(meId, other?.id ?? '');
                  if (id == null) return;
                  if (!context.mounted) return;
                  Navigator.of(context).pushNamed('/chat', arguments: {'matchId': id});
                },
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load matches: $e')),
      ),
    );
  }

  String _fmt(DateTime dt) =>
      dt.millisecondsSinceEpoch == 0 ? '—' : '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')}';
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('No matches yet. Keep swiping!'),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({this.url});
  final String? url;
  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) return const CircleAvatar(child: Icon(Icons.person));
    return CircleAvatar(backgroundImage: NetworkImage(url!));
  }
}