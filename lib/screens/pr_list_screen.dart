import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
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

class _PrListScreenState extends State<PrListScreen> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = 'v${info.version}');
  }

  Future<void> _open(PullRequest pr) async {
    await WatcherService.openUrl(pr.htmlUrl);
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
          return Column(
            children: [
              _buildHeader(prs.length),
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              Expanded(child: prs.isEmpty ? _buildEmpty() : _buildList(prs)),
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
              onPressed: widget.watcher.refresh,
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

  Widget _buildEmpty() {
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
              error ?? 'No PRs waiting on you',
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
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: prs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) => _PrRow(pr: prs[i], onTap: () => _open(prs[i])),
    );
  }

  Widget _buildFooter() {
    final updated = widget.watcher.lastUpdated;
    final error = widget.watcher.error;
    final status = error ??
        (updated != null ? 'Updated ${_relative(updated)}' : 'Waiting for first refresh');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              status,
              style: GoogleFonts.inter(
                fontSize: 11,
                color: error != null ? Colors.red : const Color(0xFF9CA3AF),
              ),
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

class _PrRow extends StatefulWidget {
  final PullRequest pr;
  final VoidCallback onTap;
  const _PrRow({required this.pr, required this.onTap});

  @override
  State<_PrRow> createState() => _PrRowState();
}

class _PrRowState extends State<_PrRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final pr = widget.pr;
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
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
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
