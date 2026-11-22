import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../db/db_controller.dart' show DbController;
import '../theme/app_tokens.dart';
import '../widgets/db_job_panel.dart';
import 'quick_update_controller.dart';

/// מסך יחיד של "עדכון מהיר": מתחיל לעבוד מיד, ונסגר לבד אחרי הצלחה.
class QuickUpdateScreen extends StatefulWidget {
  const QuickUpdateScreen({
    super.key,
    required this.controller,
    this.onOpenFull,
    this.autoStart = true,
    this.autoCloseAfter = const Duration(seconds: 10),
    this.onClose,
  });

  final QuickUpdateController controller;

  /// פתיחת התוכנה המלאה (כל הלשוניות) במקום המסך הזה.
  final VoidCallback? onOpenFull;
  final bool autoStart;

  /// `null`: לא נסגר לבד.
  final Duration? autoCloseAfter;

  /// ברירת מחדל: יציאה מהתהליך (עדכוני אוצריא ממתינה לה).
  final VoidCallback? onClose;

  @override
  State<QuickUpdateScreen> createState() => _QuickUpdateScreenState();
}

class _QuickUpdateScreenState extends State<QuickUpdateScreen> {
  QuickUpdateController get c => widget.controller;
  Timer? _closeTimer;
  int _secondsLeft = 0;
  QuickPhase? _lastPhase;

  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onExitRequested: _confirmExit);

  @override
  void initState() {
    super.initState();
    _lifecycle;
    c.db.confirm = _confirm;
    c.addListener(_onChange);
    if (widget.autoStart) WidgetsBinding.instance.addPostFrameCallback((_) => c.start());
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    c.removeListener(_onChange);
    _lifecycle.dispose();
    super.dispose();
  }

  void _onChange() {
    if (c.phase == _lastPhase) return;
    _lastPhase = c.phase;
    _closeTimer?.cancel();
    final after = widget.autoCloseAfter;
    if (c.canAutoClose && after != null) {
      _secondsLeft = after.inSeconds;
      _closeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        setState(() => _secondsLeft--);
        if (_secondsLeft <= 0) {
          t.cancel();
          _close();
        }
      });
    }
  }

  void _stopAutoClose() {
    _closeTimer?.cancel();
    setState(() => _closeTimer = null);
  }

  void _close() {
    final cb = widget.onClose;
    if (cb != null) {
      cb();
    } else {
      exit(0);
    }
  }

  Future<AppExitResponse> _confirmExit() async {
    if (!c.running || !mounted) return AppExitResponse.exit;
    final close = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('העדכון בעיצומו'),
        content: const Text('העדכון עדיין רץ. לסגור בכל זאת? (המסד הקיים לא ייפגע, ואפשר להמשיך אחר כך)'),
        actions: [
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('להישאר')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('לסגור בכל זאת')),
        ],
      ),
    );
    return close == true ? AppExitResponse.exit : AppExitResponse.cancel;
  }

  Future<bool> _confirm(String message) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('אישור'),
        content: Text(
          message == DbController.unknownDbConfirmText
              ? 'גרסת המסד במחשב הזה לא מזוהה לפי הקבצים שבכונן. זה קורה כשהמסד ישן מ-10 גרסאות, '
                    'או כשהכונן הוכן לפני שהמסד הזה עודכן (ואז המסד שבמחשב חדש יותר מזה שבכונן).\n\n'
                    'להמשיך ולהחליף אותו במסד המלא שבכונן?'
              : message,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('המשך')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _pickOtherFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת תיקייה למסד הספרים');
    if (dir != null) await c.chooseFolder(dir);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTokens.spaceLG),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context),
                  const SizedBox(height: AppTokens.spaceLG),
                  ..._body(context),
                  if (widget.onOpenFull != null && !c.running) ...[
                    const SizedBox(height: AppTokens.spaceXL),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(onPressed: widget.onOpenFull, child: const Text('פתיחת התוכנה המלאה')),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final sub = switch (c.online) {
      true => 'מחשב מחובר: הכנת הכונן למחשב ללא רשת',
      false => 'עדכון המסד מהכונן',
      null => 'בודק חיבור לרשת...',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('עדכון מסד הספרים הלא רשמי', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AppTokens.spaceXS),
        Text(sub, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  List<Widget> _body(BuildContext context) {
    final theme = Theme.of(context);
    switch (c.phase) {
      case QuickPhase.starting:
        final insp = c.db.inspecting;
        final pr = c.db.inspectProgress;
        return [
          Text(insp ? 'מזהה את גרסת המסד במחשב...' : 'מתכונן...', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppTokens.spaceMD),
          ClipRRect(
            borderRadius: AppTokens.borderRadiusAll,
            child: LinearProgressIndicator(value: insp ? pr : null, minHeight: 12),
          ),
        ];
      case QuickPhase.needsLocation:
        return [
          Text('זו הפעם הראשונה שהמסד מותקן במחשב הזה.', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppTokens.spaceSM),
          Text(
            c.otzariaFound
                ? 'המסד יישמר בתיקייה הבאה (מיקום ברירת המחדל של אוצריא למסדים אישיים), '
                      'ויצורף לאוצריא כך שהספרים יופיעו בה מעצמם:'
                : 'אוצריא לא נמצאה במחשב הזה (או שעוד לא נפתחה בו). המסד יישמר בתיקייה הבאה, '
                      'ואחרי שאוצריא תותקן ותיפתח פעם אחת, לחצו שוב על העדכון כדי לצרף אליה את המסד:',
          ),
          const SizedBox(height: AppTokens.spaceSM),
          Container(
            padding: const EdgeInsets.all(AppTokens.spaceSM),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: AppTokens.borderRadiusAll,
            ),
            child: SelectableText(c.proposedFolder, textDirection: TextDirection.ltr),
          ),
          const SizedBox(height: AppTokens.spaceLG),
          Row(
            children: [
              FilledButton.icon(
                onPressed: c.running ? null : () => c.chooseFolder(c.proposedFolder),
                icon: const Icon(Icons.check),
                label: const Text('התקנה בתיקייה הזו'),
              ),
              const SizedBox(width: AppTokens.spaceSM),
              OutlinedButton.icon(
                onPressed: c.running ? null : _pickOtherFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('בחירת תיקייה אחרת'),
              ),
            ],
          ),
        ];
      case QuickPhase.working:
        return [
          if (c.db.activity != null)
            DbProgressPanel(db: c.db)
          else ...[
            Text(c.db.inspecting ? 'מזהה את גרסת המסד במחשב...' : 'מתכונן...', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppTokens.spaceMD),
            ClipRRect(
              borderRadius: AppTokens.borderRadiusAll,
              child: LinearProgressIndicator(value: c.db.inspecting ? c.db.inspectProgress : null, minHeight: 12),
            ),
          ],
        ];
      case QuickPhase.done:
        return [
          _Result(text: c.message, error: false),
          if (c.online == true) ...[
            const SizedBox(height: AppTokens.spaceSM),
            Text(
              'עכשיו חברו את הכונן למחשב ללא רשת, ושם לחצו שוב על אותה תוכנה בעדכוני אוצריא.',
              style: theme.textTheme.titleMedium,
            ),
          ] else ...[
            const SizedBox(height: AppTokens.spaceSM),
            if (c.canAutoClose) Text('אפשר לפתוח את אוצריא.', style: theme.textTheme.titleMedium),
          ],
          const SizedBox(height: AppTokens.spaceLG),
          Row(
            children: [
              FilledButton(onPressed: _close, child: const Text('סגור')),
              const SizedBox(width: AppTokens.spaceMD),
              if (_closeTimer != null) ...[
                Text('נסגר בעוד $_secondsLeft שניות'),
                TextButton(onPressed: _stopAutoClose, child: const Text('השאר פתוח')),
              ],
            ],
          ),
        ];
      case QuickPhase.failed:
        return [
          _Result(text: c.message.isEmpty ? 'הפעולה לא הושלמה.' : c.message, error: !c.stoppedByUser),
          const SizedBox(height: AppTokens.spaceLG),
          Row(
            children: [
              FilledButton.icon(onPressed: c.start, icon: const Icon(Icons.refresh), label: const Text('נסו שוב')),
              const SizedBox(width: AppTokens.spaceSM),
              TextButton(onPressed: _close, child: const Text('סגור')),
            ],
          ),
        ];
    }
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.text, required this.error});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = error ? cs.errorContainer : (dark ? const Color(0xFF1B3A1F) : const Color(0xFFDCEFDD));
    final fg = error ? cs.onErrorContainer : (dark ? const Color(0xFFA5D6A7) : const Color(0xFF1B5E20));
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(AppTokens.spaceMD),
        decoration: BoxDecoration(color: bg, borderRadius: AppTokens.borderRadiusAll),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(error ? Icons.error_outline : Icons.check_circle, color: fg, size: 28),
            const SizedBox(width: AppTokens.spaceMD),
            Expanded(
              child: SelectableText(
                text,
                style: TextStyle(color: fg, fontSize: AppTokens.fontLG),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
