// FILE: lib/features/inbox/tabs/requests_tab.dart
import 'package:flutter/material.dart';
import '../../chat/widgets/peer_avatar.dart';
import '../../chat/chat_page.dart';
import '../data/chat_requests_via_matches_repo.dart';

class RequestsTab extends StatefulWidget {
  const RequestsTab({super.key});

  @override
  State<RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends State<RequestsTab> {
  final repo = ChatRequestsViaMatchesRepo();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<RequestItem>>(
      stream: repo.streamInboundRequests(),
      builder: (context, snap) {
        final items = snap.data ?? const <RequestItem>[];
        if (snap.connectionState == ConnectionState.waiting) {
          return const _RequestsSkeleton();
        }
        if (items.isEmpty) {
          return const _EmptyRequests();
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) => _RequestTile(
            item: items[i],
            onViewProfile: () => _viewProfile(items[i].senderId),
            onAccept: () async {
              final matchId = await repo.accept(items[i].matchId);
              if (!context.mounted) return; // fix: guard BuildContext after await
              if (matchId != null) {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChatPage(matchId: matchId),
                  settings: const RouteSettings(name: ChatPage.routeName),
                ));
              } else {
                _toast('Could not open chat.');
              }
            },
            onDecline: () async {
              await repo.decline(items[i].matchId);
              if (!context.mounted) return; // fix: guard BuildContext after await
              _toast('Request dismissed');
            },
          ),
        );
      },
    );
  }

  void _viewProfile(String uid) {
    // Replace with your profile route if desired.
    _toast('Open profile for $uid');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.item,
    required this.onViewProfile,
    required this.onAccept,
    required this.onDecline,
  });

  final RequestItem item;
  final VoidCallback onViewProfile;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF14151A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF23242A)),
        boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black38, offset: Offset(0, 6))],
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PeerAvatar(
            userId: item.senderId,
            online: false,
            size: 56,
            border: Border.all(color: const Color(0xFF2A2C33), width: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                'Someone',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                item.firstMessage,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.25),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _pillButton(
                  context,
                  label: 'View profile',
                  onTap: onViewProfile,
                  borderColor: const Color(0xFF2F86FF),
                ),
                _pillButton(
                  context,
                  label: 'Like back',
                  onTap: onAccept,
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF0F7B), Color(0xFF6759FF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                _pillButton(
                  context,
                  label: 'Dismiss',
                  onTap: onDecline,
                  borderColor: const Color(0xFF3A3D45),
                ),
              ]),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _pillButton(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
    LinearGradient? gradient,
    Color? borderColor,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Ink(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          gradient: gradient,
          color: gradient == null ? const Color(0xFF22252C) : null,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: borderColor ?? const Color(0x22FFFFFF)),
          boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black38, offset: Offset(0, 4))],
        ),
        child: const Center(
          child: Text('',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
        ),
      ),
    );
  }
}

class _EmptyRequests extends StatelessWidget {
  const _EmptyRequests();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
      children: const [
        Center(
          child: Text('No chat requests yet', style: TextStyle(color: Colors.white70, fontSize: 16)),
        ),
      ],
    );
  }
}

class _RequestsSkeleton extends StatelessWidget {
  const _RequestsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
      itemBuilder: (_, __) => Container(
        height: 96,
        decoration: BoxDecoration(
          color: const Color(0xFF14151A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF23242A)),
        ),
      ),
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemCount: 6,
    );
  }
}
