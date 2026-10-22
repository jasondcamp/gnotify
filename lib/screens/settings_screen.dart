import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/app_log.dart';
import '../services/github_service.dart';
import '../services/settings_service.dart';
import '../services/watcher_service.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsService settingsService;
  final GitHubService github;
  final bool canClose;
  final VoidCallback onClose;

  const SettingsScreen({
    super.key,
    required this.settingsService,
    required this.github,
    required this.canClose,
    required this.onClose,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _token;
  late final TextEditingController _org;
  late final TextEditingController _interval;
  final _newTarget = TextEditingController();
  final _newTargetFocus = FocusNode();
  late List<String> _targets;

  bool _obscureToken = true;
  late bool _notifyReviewRequests;
  late bool _notifyApprovals;
  late bool _notifyCopilot;
  bool _testing = false;
  bool _saving = false;
  String? _testResult;
  bool _testOk = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = widget.settingsService.settings;
    _token = TextEditingController(text: s.token);
    _org = TextEditingController(text: s.org);
    _interval = TextEditingController(text: '${s.pollIntervalSeconds}');
    _targets = List.of(s.targets);
    _notifyReviewRequests = s.notifyReviewRequests;
    _notifyApprovals = s.notifyApprovals;
    _notifyCopilot = s.notifyCopilotReviews;
  }

  @override
  void dispose() {
    _token.dispose();
    _org.dispose();
    _interval.dispose();
    _newTarget.dispose();
    _newTargetFocus.dispose();
    super.dispose();
  }

  void _addTarget() {
    var t = _newTarget.text.trim();
    if (t.startsWith('@')) t = t.substring(1);
    if (t.isEmpty) return;
    if (t.contains('/') && !t.split('/').first.contains(RegExp(r'\S'))) return;
    if (!_targets.contains(t)) setState(() => _targets.add(t));
    _newTarget.clear();
    _newTargetFocus.requestFocus();
  }

  Future<void> _useMe() async {
    final token = _token.text.trim();
    if (token.isEmpty) {
      setState(() => _error = 'Enter a token first');
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      widget.github.token = token;
      final user = await widget.github.getAuthenticatedUser();
      if (!_targets.contains(user.login)) setState(() => _targets.add(user.login));
      setState(() {
        _testOk = true;
        _testResult = 'Signed in as ${user.login}';
      });
    } on GitHubException catch (e) {
      setState(() {
        _testOk = false;
        _testResult = e.statusCode == 401 ? 'Token rejected' : 'GitHub ${e.statusCode}: ${e.message}';
      });
    } catch (_) {
      setState(() {
        _testOk = false;
        _testResult = 'Network error';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _openLog() async {
    final path = AppLog.instance.path;
    if (path == null) return setState(() => _error = 'Log file unavailable');
    AppLog.instance.info('log opened from settings');
    await WatcherService.openUrl(Uri.file(path).toString());
  }

  Future<void> _save() async {
    final token = _token.text.trim();
    final org = _org.text.trim();
    final interval = int.tryParse(_interval.text.trim()) ?? 60;
    if (token.isEmpty) return setState(() => _error = 'Token is required');
    if (org.isEmpty) return setState(() => _error = 'Organization is required');
    if (_targets.isEmpty) return setState(() => _error = 'Add at least one user or team');
    for (final t in _targets) {
      if (t.contains('/') && t.split('/').first.toLowerCase() != org.toLowerCase()) {
        return setState(() => _error = 'Team "$t" must be in $org (use $org/team-slug)');
      }
    }

    setState(() {
      _saving = true;
      _error = null;
      _testResult = null;
    });

    // Confirm the token can actually search this org before leaving the screen.
    // Fine-grained tokens issued under the wrong resource owner pass /user but
    // fail every org-scoped search with a 422.
    String? accessError;
    try {
      widget.github.token = token;
      await widget.github.checkOrgSearchable(org);
    } on GitHubException catch (e) {
      accessError = e.statusCode == 401
          ? 'Token rejected'
          : 'Token cannot search $org: ${e.message}';
    } catch (_) {
      accessError = null; // offline: save anyway, the watcher will report it
    }

    await widget.settingsService.save(Settings(
      token: token,
      org: org,
      targets: _targets,
      pollIntervalSeconds: interval,
      notifyReviewRequests: _notifyReviewRequests,
      notifyApprovals: _notifyApprovals,
      notifyCopilotReviews: _notifyCopilot,
    ));
    if (!mounted) return;
    setState(() => _saving = false);
    if (accessError != null) {
      setState(() {
        _testOk = false;
        _testResult = accessError;
      });
      return;
    }
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      body: Column(
        children: [
          _buildHeader(),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('GitHub token'),
                  const SizedBox(height: 4),
                  _field(
                    _token,
                    hint: 'ghp_… or github_pat_…',
                    obscure: _obscureToken,
                    suffix: IconButton(
                      iconSize: 16,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        _obscureToken ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        color: const Color(0xFF9CA3AF),
                      ),
                      onPressed: () => setState(() => _obscureToken = !_obscureToken),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Classic: repo + read:org. Fine-grained: resource owner must be the org, '
                    'with Pull requests: read (and Members: read for teams).',
                    style: GoogleFonts.inter(fontSize: 10, color: const Color(0xFF9CA3AF)),
                  ),
                  const SizedBox(height: 12),
                  _label('Organization'),
                  const SizedBox(height: 4),
                  _field(_org, hint: 'my-org'),
                  const SizedBox(height: 12),
                  _label('Watch for review requests to'),
                  const SizedBox(height: 4),
                  _buildTargets(),
                  const SizedBox(height: 4),
                  Text(
                    'Usernames, or teams as org/team-slug.',
                    style: GoogleFonts.inter(fontSize: 10, color: const Color(0xFF9CA3AF)),
                  ),
                  const SizedBox(height: 12),
                  _label('Poll interval (seconds)'),
                  const SizedBox(height: 4),
                  SizedBox(width: 120, child: _field(_interval, hint: '60')),
                  const SizedBox(height: 12),
                  _label('Notifications'),
                  const SizedBox(height: 2),
                  _toggle(
                    'Review requests for the users and teams above',
                    _notifyReviewRequests,
                    (v) => setState(() => _notifyReviewRequests = v),
                  ),
                  _toggle(
                    'Approvals on PRs I opened',
                    _notifyApprovals,
                    (v) => setState(() => _notifyApprovals = v),
                  ),
                  _toggle(
                    'Copilot finished reviewing a PR I opened',
                    _notifyCopilot,
                    (v) => setState(() => _notifyCopilot = v),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'All off: the list and badge still update, nothing pops up.',
                    style: GoogleFonts.inter(fontSize: 10, color: const Color(0xFF9CA3AF)),
                  ),
                  if (_testResult != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _testResult!,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: _testOk ? const Color(0xFF10B981) : Colors.red,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
      child: Row(
        children: [
          Image.asset('assets/logo.png', width: 20, height: 20),
          const SizedBox(width: 8),
          Text(
            'Settings',
            style: GoogleFonts.manrope(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF1A1A2E),
            ),
          ),
          const Spacer(),
          if (widget.canClose)
            IconButton(
              tooltip: 'Back',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, color: Color(0xFF6B7280)),
              onPressed: widget.onClose,
            ),
        ],
      ),
    );
  }

  Widget _buildTargets() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_targets.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _targets
                  .map(
                    (t) => Chip(
                      label: Text(t, style: GoogleFonts.inter(fontSize: 12)),
                      avatar: Icon(
                        t.contains('/') ? Icons.group_outlined : Icons.person_outline,
                        size: 14,
                      ),
                      deleteIcon: const Icon(Icons.close, size: 14),
                      onDeleted: () => setState(() => _targets.remove(t)),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                  )
                  .toList(),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _field(
                _newTarget,
                hint: 'username or org/team-slug',
                focusNode: _newTargetFocus,
                onSubmitted: (_) => _addTarget(),
              ),
            ),
            const SizedBox(width: 6),
            _smallButton('Add', onPressed: _addTarget),
            const SizedBox(width: 6),
            _smallButton('Add me', onPressed: _testing ? null : _useMe, loading: _testing),
          ],
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _openLog,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: const Color(0xFF6B7280),
            ),
            icon: const Icon(Icons.article_outlined, size: 14),
            label: Text('Log', style: GoogleFonts.inter(fontSize: 12)),
          ),
          TextButton.icon(
            onPressed: WatcherService.quitApp,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: const Color(0xFF6B7280),
            ),
            icon: const Icon(Icons.power_settings_new, size: 14),
            label: Text('Quit', style: GoogleFonts.inter(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error ?? '',
              style: GoogleFonts.inter(fontSize: 11, color: Colors.red),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF6366F1),
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text('Save', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _toggle(String text, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        SizedBox(
          height: 28,
          child: FittedBox(
            child: Switch(
              value: value,
              activeTrackColor: const Color(0xFF6366F1),
              onChanged: onChanged,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: GoogleFonts.inter(fontSize: 12, color: Colors.black87)),
        ),
      ],
    );
  }

  Widget _label(String text) => Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: const Color(0xFF6B7280),
        ),
      );

  Widget _field(
    TextEditingController controller, {
    String? hint,
    bool obscure = false,
    Widget? suffix,
    FocusNode? focusNode,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscure,
      onSubmitted: onSubmitted,
      style: GoogleFonts.inter(fontSize: 13, color: Colors.black87),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFFBDBDBD)),
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        suffixIcon: suffix,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF6366F1)),
        ),
      ),
    );
  }

  Widget _smallButton(String text, {VoidCallback? onPressed, bool loading = false}) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: loading
          ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(text, style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF4F46E5))),
    );
  }
}
