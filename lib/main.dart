import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_localizations/flutter_localizations.dart';

import 'dart:io';

import 'src/controllers/app_controller.dart';
import 'src/db/db_controller.dart' show dbMirrorDirName;
import 'src/quick/quick_update_controller.dart';
import 'src/quick/quick_update_screen.dart';
import 'src/services/app_paths.dart';
import 'src/services/single_instance.dart';
import 'src/screens/app_shell.dart';
import 'src/theme/app_theme.dart';

// נשמר לכל חיי התהליך; המערכת משחררת אותו בסיום או בקריסה.
// ignore: unused_element
SingleInstance? _instanceLock;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final lock = await SingleInstance.acquire(p.join(AppPaths.userConfigDir(), 'app.lock'));
  if (lock == null) {
    runApp(const _AlreadyRunningApp());
    return;
  }
  _instanceLock = lock;
  // מתוך עדכוני אוצריא (או --quick): מסך עדכון יחיד שמתחיל לעבוד מיד.
  if (args.contains('--quick') || AppPaths.launchedFromOtzariaUpdates()) {
    runApp(QuickUpdateApp(mirrorDir: p.join(AppPaths.programDir(), dbMirrorDirName)));
    return;
  }
  runApp(const OfflineUpdateApp());
}

class QuickUpdateApp extends StatefulWidget {
  const QuickUpdateApp({super.key, required this.mirrorDir});
  final String mirrorDir;

  @override
  State<QuickUpdateApp> createState() => _QuickUpdateAppState();
}

class _QuickUpdateAppState extends State<QuickUpdateApp> {
  late QuickUpdateController? _quick = QuickUpdateController(mirrorDir: widget.mirrorDir);

  void _openFull() {
    final q = _quick;
    if (q == null || q.running) return;
    setState(() => _quick = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => q.dispose());
  }

  @override
  void dispose() {
    _quick?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _quick;
    if (q == null) return const OfflineUpdateApp();
    return MaterialApp(
      title: 'עדכון מסד הספרים',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      locale: const Locale('he', 'IL'),
      supportedLocales: const [Locale('he', 'IL')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()),
      home: QuickUpdateScreen(controller: q, onOpenFull: _openFull),
    );
  }
}

class _AlreadyRunningApp extends StatefulWidget {
  const _AlreadyRunningApp();

  @override
  State<_AlreadyRunningApp> createState() => _AlreadyRunningAppState();
}

class _AlreadyRunningAppState extends State<_AlreadyRunningApp> {
  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(seconds: 10), () => exit(0));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('he', 'IL'),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'התוכנה כבר פתוחה. עברו לחלון הקיים.\nפתיחה כפולה עלולה לפגוע במסד הספרים.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: () => exit(0), child: const Text('סגור')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OfflineUpdateApp extends StatefulWidget {
  const OfflineUpdateApp({super.key});

  @override
  State<OfflineUpdateApp> createState() => _OfflineUpdateAppState();
}

class _OfflineUpdateAppState extends State<OfflineUpdateApp> {
  final AppController _controller = AppController();

  @override
  void initState() {
    super.initState();
    _controller.init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => MaterialApp(
        title: 'עדכון אופליין למאגר ספרים',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _controller.themeMode,
        locale: const Locale('he', 'IL'),
        supportedLocales: const [Locale('he', 'IL')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()),
        home: AppShell(controller: _controller),
      ),
    );
  }
}
