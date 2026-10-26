import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/pull_request.dart';
import '../services/settings_service.dart';
import '../services/watcher_service.dart';

class PrListScreen extends StatefulWidget {
  final WatcherService watcher;
  final SettingsService settingsService;
  final ValueNotifier<int>? refreshNotifier;
  final VoidCallback onOpenSettings;

  const PrListScreen({
    super.key,
    required this.watcher,
    required this.settingsService,
    required this.onOpenSettings,
    this.refreshNotifier,
  });

  @override
  State<PrListScreen> createState() => _PrListScreenState();
}

enum _Tab { toReview, mine }

class _PrListScreenState extends State<PrListScreen> {
  static const _kTabKey = 'last_tab';
  String _version = '';
  _Tab _tab = _Tab.toReview;

  // One controller per tab so the two lists never inherit each other's
  // offset, and so the popover can snap back to the newest PRs on open.
  final _reviewScroll = ScrollController();
  final _mineScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadTab();
    widget.refreshNotifier?.addListener(_scrollToTop);
  }

  @override
  void dispose() {
    widget.refreshNotifier?.removeListener(_scrollToTop);
    _reviewScroll.dispose();
    _mineScroll.dispose();
    super.dispose();
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in [_reviewScroll, _mineScroll]) {
        if (c.hasClients) c.jumpTo(0);
      }
    });
  }

  Future<void> _loadTab() async {
    final prefs = await SharedPreferences.getInstance();
    final i = prefs.getInt(_kTabKey) ?? 0;
    if (mounted && i >= 0 && i < _Tab.values.length) setState(() => _tab = _Tab.values[i]);
  }

  Future<void> _selectTab(_Tab t) async {
    setState(() => _tab = t);
    _scrollToTop();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kTabKey, t.index);
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = 'v${info.version}');
  }

  Future<void> _open(String url) async {
    await WatcherService.openUrl(url);
    await WatcherService.closePopover();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      body: ListenableBuilder(
        listenable: widget.watcher,
        builder: (context, _) {
          final prs = widget.watcher.pullRequests;
          final mine = widget.watcher.myPullRequests;
          return Column(
            children: [
              _buildHeader(prs.length),
              _buildTabs(prs.length, mine.length),
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              Expanded(
                child: switch (_tab) {
                  _Tab.toReview => prs.isEmpty
                      ? _buildEmpty('No PRs waiting on you')
                      : _buildList(prs),
                  _Tab.mine => mine.isEmpty
                      ? _buildEmpty('No open PRs of yours in ${widget.settingsService.settings.org}')
                      : _buildMyList(mine),
                },
              ),
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _buildFooter(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
      child: Row(
        children: [
          Image.asset('assets/logo.png', width: 20, height: 20),
          const SizedBox(width: 8),
          Text(
            'gnotify',
            style: GoogleFonts.manrope(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(width: 8),
          if (count > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          const Spacer(),
          if (widget.watcher.isPolling)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: 'Refresh',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh, color: Color(0xFF6B7280)),
              onPressed: () => widget.watcher.refresh(force: true),
            ),
          IconButton(
            tooltip: 'Settings',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.settings_outlined, color: Color(0xFF6B7280)),
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildTabs(int toReview, int mine) {
    Widget tab(_Tab t, String label, int count) {
      final selected = _tab == t;
      return Expanded(
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _selectTab(t),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: selected ? const Color(0xFF6366F1) : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? const Color(0xFF1A1A2E) : const Color(0xFF6B7280),
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(width: 6),
                    Text(
                      '$count',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: selected ? const Color(0xFF6366F1) : const Color(0xFF9CA3AF),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tab(_Tab.toReview, 'To Review', toReview),
        tab(_Tab.mine, 'My PRs', mine),
      ],
    );
  }

  Widget _buildEmpty(String emptyText) {
    final error = widget.watcher.error;
    final detail = widget.watcher.errorDetail;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              error == null ? Icons.check_circle_outline : Icons.error_outline,
              size: 36,
              color: error == null ? const Color(0xFF10B981) : Colors.red,
            ),
            const SizedBox(height: 10),
            Text(
              error ?? emptyText,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF6B7280)),
            ),
            if (error != null && detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF9CA3AF)),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: widget.onOpenSettings,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  side: const BorderSide(color: Color(0xFFE5E7EB)),
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(
                  'Open Settings',
                  style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF4F46E5)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildList(List<PullRequest> prs) {
    return ListView.separated(
      key: const PageStorageKey('to-review'),
      controller: _reviewScroll,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: prs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) => _PrRow(pr: prs[i], onTap: () => _open(prs[i].htmlUrl)),
    );
  }

  Widget _buildMyList(List<OwnPullRequest> mine) {
    return ListView.separated(
      key: const PageStorageKey('my-prs'),
      controller: _mineScroll,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: mine.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) => _OwnPrRow(own: mine[i], onTap: () => _open(mine[i].pr.htmlUrl)),
    );
  }

  Widget _buildFooter() {
    final updated = widget.watcher.lastUpdated;
    final error = widget.watcher.error;
    final rl = widget.watcher.rateLimit;
    final warning = widget.watcher.warning;
    final budget = rl == null ? '' : ' · API ${rl.remaining}/${rl.limit}';
    final status = error ??
        warning ??
        (updated != null ? 'Updated ${_relative(updated)}$budget' : 'Waiting for first refresh');
    final statusColor = error != null
        ? Colors.red
        : warning != null
            ? const Color(0xFFB45309)
            : const Color(0xFF9CA3AF);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              status,
              style: GoogleFonts.inter(fontSize: 11, color: statusColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            _version,
            style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF9CA3AF)),
          ),
        ],
      ),
    );
  }
}

String _relative(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

class _PrRow extends StatelessWidget {
  final PullRequest pr;
  final VoidCallback onTap;
  const _PrRow({required this.pr, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _Card(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(url: pr.authorAvatarUrl, login: pr.author),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        pr.repoName,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF6366F1),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      ' #${pr.number}',
                      style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF9CA3AF)),
                    ),
                    const Spacer(),
                    Text(
                      _relative(pr.updatedAt),
                      style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF9CA3AF)),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  pr.title,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF1A1A2E),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      pr.author,
                      style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF6B7280)),
                    ),
                    const SizedBox(width: 6),
                    ...pr.requestedFrom.map(
                      (t) => Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEEF2FF),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          t.contains('/') ? t.split('/').last : t,
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            color: const Color(0xFF4F46E5),
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    _UnresolvedCount(pr.unresolvedThreads),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  final String login;
  const _Avatar({required this.url, required this.login});

  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      radius: 14,
      backgroundColor: const Color(0xFFE0E7FF),
      child: Text(
        login.isNotEmpty ? login[0].toUpperCase() : '?',
        style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF4F46E5)),
      ),
    );
    if (url == null) return fallback;
    return ClipOval(
      child: Image.network(
        '$url${url!.contains('?') ? '&' : '?'}s=56',
        width: 28,
        height: 28,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

/// Hover-highlighting card shared by both row types.
class _Card extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;
  const _Card({required this.onTap, required this.child});

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _hover ? Colors.white : Colors.white.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _hover ? const Color(0xFF6366F1) : const Color(0xFFE5E7EB),
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _OwnPrRow extends StatelessWidget {
  final OwnPullRequest own;
  final VoidCallback onTap;
  const _OwnPrRow({required this.own, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pr = own.pr;
    final (label, fg, bg) = switch (own.state) {
      ReviewState.approved => ('Approved', const Color(0xFF047857), const Color(0xFFD1FAE5)),
      ReviewState.changesRequested => ('Changes requested', const Color(0xFFB91C1C), const Color(0xFFFEE2E2)),
      ReviewState.draft => ('Draft', const Color(0xFF6B7280), const Color(0xFFF3F4F6)),
      ReviewState.awaiting => ('Awaiting review', const Color(0xFFB45309), const Color(0xFFFEF3C7)),
    };
    final base = switch (own.state) {
      ReviewState.approved => 'by ${own.approvers.join(', ')}',
      ReviewState.changesRequested => 'by ${own.changesRequestedBy.join(', ')}',
      _ => own.pendingReviewers.isEmpty
          ? (own.copilot == CopilotStatus.none ? 'no reviewers requested' : '')
          : 'asked ${own.pendingReviewers.map((r) => r.contains('/') ? r.split('/').last : r).join(', ')}',
    };
    final copilot = switch (own.copilot) {
      CopilotStatus.reviewing => 'Copilot reviewing',
      CopilotStatus.reviewed => 'Copilot reviewed',
      CopilotStatus.none => '',
    };
    final detail = [base, copilot].where((t) => t.isNotEmpty).join(' · ');

    return _Card(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  pr.repoName,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF6366F1),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                ' #${pr.number}',
                style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF9CA3AF)),
              ),
              const Spacer(),
              Text(
                _relative(pr.updatedAt),
                style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF9CA3AF)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            pr.title,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF1A1A2E),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  label,
                  style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: fg),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  detail,
                  style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF6B7280)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _UnresolvedCount(pr.unresolvedThreads),
            ],
          ),
        ],
      ),
    );
  }
}

/// "3" and a comment bubble, right-aligned on a row; nothing when zero.
class _UnresolvedCount extends StatelessWidget {
  final int count;
  const _UnresolvedCount(this.count);

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Tooltip(
      message: count == 1 ? '1 unresolved comment thread' : '$count unresolved comment threads',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$count',
            style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF6B7280)),
          ),
          const SizedBox(width: 3),
          const Icon(Icons.chat_bubble_outline, size: 12, color: Color(0xFF9CA3AF)),
        ],
      ),
    );
  }
}
