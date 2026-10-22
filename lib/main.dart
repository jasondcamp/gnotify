import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'services/app_log.dart';
import 'services/github_service.dart';
import 'services/settings_service.dart';
import 'services/watcher_service.dart';
import 'screens/pr_list_screen.dart';
import 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.instance.init();
  try {
    final info = await PackageInfo.fromPlatform();
    AppLog.instance.info('gnotify ${info.version}+${info.buildNumber} starting');
  } catch (_) {
    AppLog.instance.info('gnotify starting');
  }
  runApp(const GnotifyApp());
}

class GnotifyApp extends StatelessWidget {
  const GnotifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'gnotify',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6366F1),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      home: const GnotifyShell(),
    );
  }
}

class GnotifyShell extends StatefulWidget {
  const GnotifyShell({super.key});

  @override
  State<GnotifyShell> createState() => _GnotifyShellState();
}

class _GnotifyShellState extends State<GnotifyShell> {
  static const _channel = MethodChannel('com.jasoncamp.gnotify/menubar');

  final _settingsService = SettingsService();
  final _github = GitHubService();
  late final WatcherService _watcher;
  final _refreshNotifier = ValueNotifier<int>(0);

  bool _loaded = false;
  bool _showSettings = false;

  @override
  void initState() {
    super.initState();
    _watcher = WatcherService(github: _github, settingsService: _settingsService);
    _channel.setMethodCallHandler(_handleNativeCall);
    _init();
  }

  Future<void> _init() async {
    await _settingsService.load();
    final configured = _settingsService.settings.isConfigured;
    if (mounted) {
      setState(() {
        _loaded = true;
        _showSettings = !configured;
      });
    }
    await _watcher.start();
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'popoverOpened':
        _refreshNotifier.value++;
        _watcher.refresh();
        break;
      case 'openSettings':
        if (mounted) setState(() => _showSettings = true);
        break;
      case 'refresh':
        _watcher.refresh(force: true);
        break;
    }
  }

  @override
  void dispose() {
    _watcher.dispose();
    _settingsService.dispose();
    _refreshNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        backgroundColor: Color(0xFFF2F2F7),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_showSettings) {
      return SettingsScreen(
        settingsService: _settingsService,
        github: _github,
        canClose: _settingsService.settings.isConfigured,
        onClose: () => setState(() => _showSettings = false),
      );
    }
    return PrListScreen(
      watcher: _watcher,
      settingsService: _settingsService,
      refreshNotifier: _refreshNotifier,
      onOpenSettings: () => setState(() => _showSettings = true),
    );
  }
}
