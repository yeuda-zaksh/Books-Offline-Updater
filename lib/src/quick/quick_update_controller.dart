import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../controllers/app_controller.dart';
import '../db/db_controller.dart';
import '../db/db_manifest.dart';
import '../db/db_service.dart';
import '../services/disk_space.dart';
import '../services/otzaria_locator.dart';

/// checking: בדיקה אוטומטית בפתיחה. ready: מחכים ללחיצה על הכפתור ([action]). working: הורדה/עדכון.
enum QuickPhase { checking, ready, working, done, failed }

/// מה יקרה בלחיצה על הכפתור: הורדה לכונן (מחשב מחובר), עדכון המסד, או התקנה ראשונה (בחירת מיקום).
enum QuickAction { download, update, install }

/// "עדכון מהיר": מה שקורה כשהתוכנה מופעלת מתוך עדכוני אוצריא (תוכנות נוספות).
///
/// במחשב מחובר: בודק בכל פתיחה אם יש גרסה חדשה, ובלחיצה מוריד לכונן את המסד המלא ואת קובצי העדכון
/// של עד [stepsBack] הגרסאות האחרונות. במחשב בלי רשת: בלחיצה מעדכן את המסד מהכונן, ובפעם הראשונה
/// מתקין אותו במיקום שהמשתמש בוחר.
class QuickUpdateController extends ChangeNotifier {
  /// [findOtzariaDb]: איפה אוצריא קוראת את המסד (מוזרק בבדיקות, כדי לא לקרוא את אוצריא של המחשב).
  QuickUpdateController({required this.mirrorDir, DbController? db, Future<String?> Function()? findOtzariaDb})
    : db = db ?? DbController(AppController()..dataDir = p.dirname(mirrorDir)),
      _findOtzariaDb = findOtzariaDb ?? OtzariaLocator.findDbPath {
    this.db.autoInspect = false;
    this.db.addListener(notifyListeners);
  }

  /// כמה גרסאות אחורה אפשר לעדכן בקובצי עדכון בלבד (כמו עדכוני אוצריא למסד הרשמי).
  static const stepsBack = 10;

  /// תיקיית קובצי המסד בכונן, ליד התוכנה.
  final String mirrorDir;
  final DbController db;
  final Future<String?> Function() _findOtzariaDb;

  QuickPhase phase = QuickPhase.checking;
  QuickAction? action;

  /// נקבע אחרי הבדיקה: `true` = מחשב מחובר (הורדה לכונן), `false` = עדכון מהכונן.
  bool? online;

  /// שתי שורות קצרות למצב הנוכחי (מוכן / הסתיים).
  String title = '';
  String detail = '';

  /// הערה שדורשת תשומת לב (למשל: המסד לא צורף לאוצריא). מוצגת בהדגשה.
  String? warning;

  /// הודעת כשל.
  String? note;

  bool _inited = false;
  bool _running = false;
  bool _disposed = false;
  List<DbArtifact> _driveList = const [];

  /// יש פעולה בעיצומה (גם בשלבים שבהם [DbController.busy] עוד/כבר false, כמו זיהוי הגרסה).
  bool get running => _running || db.busy;

  /// התיקייה שמוצעת בהתקנה ראשונה: "מסדים אישיים" של אוצריא (או במסמכים, כשאוצריא לא נמצאה).
  String get proposedFolder => p.dirname(OtzariaLocator.defaultNewDbPath());

  String get message => note ?? db.message ?? '';

  /// כשל "רך": המשתמש עצר, או ביטל אישור. מוצג בלי צבע שגיאה.
  bool get stoppedByUser => phase == QuickPhase.failed && note == null && db.message != null && !db.messageIsError;

  int? get _version => (db.remote ?? db.mirror)?.manifest.version;

  // ─── בדיקה ────────────────────────────────────────────────────────

  /// הבדיקה האוטומטית בפתיחה (וב"נסו שוב"): מה מצב הכונן או המסד, ואיזה כפתור להציג.
  Future<void> start() async {
    if (_running || _disposed) return;
    _running = true;
    note = null;
    warning = null;
    action = null;
    db.clearMessage();
    phase = QuickPhase.checking;
    notifyListeners();
    try {
      if (!_inited) {
        _inited = true;
        await db.init(pinMirrorDir: mirrorDir);
        db.otzariaDbPath = await _findOtzariaDb();
      } else {
        // ניסיון חוזר: ייתכן שבינתיים המסד צורף באוצריא, או שהתקנה קודמת נקטעה.
        db.otzariaDbPath = await _findOtzariaDb();
        if (db.targetDb.isNotEmpty) await DbService.recoverInterrupted(db.targetDb);
        await db.refreshMirror();
        await db.checkRemote();
      }
      if (_disposed) return;
      online = db.remote != null;
      if (online!) {
        _checkDrive();
      } else {
        await _checkLocal();
      }
    } catch (e) {
      _fail('שגיאה לא צפויה: $e');
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  void _checkDrive() {
    final m = db.remote!.manifest;
    _driveList = driveSet(m, db.remoteSteps?.manifest);
    final missing = missingBytes(_driveList, mirrorDir);
    if (missing == 0 && db.mirror?.manifest.version == m.version) {
      _done('הכונן מעודכן', 'גרסה ${m.version}');
      return;
    }
    _ready(QuickAction.download, 'גרסה ${m.version} זמינה', missing == 0 ? '' : '${_size(missing)} להורדה');
  }

  Future<void> _checkLocal() async {
    if (db.mirror == null) {
      final net = db.remoteError == null ? '' : '\n\nאם המחשב מחובר לרשת: ${db.remoteError}';
      _fail(
        db.mirrorError != null
            ? 'קובצי המסד בכונן אינם תקינים: ${db.mirrorError}$net'
            : 'אין בכונן קבצי מסד. הפעילו קודם את התוכנה במחשב מחובר לרשת.$net',
      );
      return;
    }
    final v = _version;
    final attached = db.otzariaDbPath;
    // מצורף לאוצריא אבל הקובץ נמחק: כמו התקנה ראשונה (בחירת מיקום).
    if (attached != null && _existsSync(attached)) {
      if (db.targetDb != attached) {
        await db.setTarget(attached);
        if (_disposed) return;
        if (db.targetDb != attached) {
          _fail(null);
          return;
        }
      }
    } else if (attached != null || !_existsSync(db.targetDb)) {
      _ready(QuickAction.install, 'המסד לא מותקן במחשב הזה', 'גרסה $v בכונן');
      return;
    }
    await db.inspectTarget();
    if (_disposed) return;
    final plan = db.plan;
    if (plan == null) {
      _fail(db.message ?? 'לא ניתן לזהות את המסד במחשב הזה.');
      return;
    }
    switch (plan.action) {
      case InstallAction.none:
        // מעודכן, אבל אולי עוד לא מצורף לאוצריא (למשל הותקן ידנית).
        final extra = await db.ensureAttached();
        _done('המסד מעודכן', 'גרסה $v', warning: _warningFrom(extra));
      case InstallAction.blocked:
        _fail('${plan.message}\nהפעילו את התוכנה במחשב מחובר כדי להשלים את הקבצים בכונן.');
      case InstallAction.delta:
      case InstallAction.full:
        final from = db.localMirror?.version;
        _ready(QuickAction.update, 'גרסה $v זמינה', from == null ? '' : 'במחשב: גרסה $from');
    }
  }

  // ─── פעולה ────────────────────────────────────────────────────────

  /// הכפתור הראשי: הורדה לכונן או עדכון המסד. להתקנה ראשונה: [installTo].
  Future<void> run() async {
    if (phase != QuickPhase.ready || _running || _disposed) return;
    switch (action) {
      case QuickAction.download:
        await _guard(_download);
      case QuickAction.update:
        await _guard(_install);
      case QuickAction.install:
      case null:
        return;
    }
  }

  /// התקנה ראשונה בתיקייה שהמשתמש בחר.
  Future<void> installTo(String folder) async {
    if (phase != QuickPhase.ready || action != QuickAction.install || _running || _disposed) return;
    await _guard(() async {
      await db.setTarget(p.join(folder, '$dbLibraryId.db'));
      if (_disposed) return;
      if (db.messageIsError && db.message != null) {
        _fail(null);
        return;
      }
      await _install();
    });
  }

  Future<void> _guard(Future<void> Function() body) async {
    _running = true;
    note = null;
    warning = null;
    phase = QuickPhase.working;
    notifyListeners();
    try {
      await body();
    } catch (e) {
      _fail('שגיאה לא צפויה: $e');
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _download() async {
    final m = db.remote!.manifest;
    final missing = missingBytes(_driveList, mirrorDir);
    if (missing > 0) {
      final free = await freeDiskSpace(p.join(mirrorDir, 'x'));
      if (free != null && free < missing + 64 * 1024 * 1024) {
        _fail(
          'אין מספיק מקום פנוי בכונן. דרושים ${_size(missing)}, '
          'ופנויים ${_size(free)}.',
        );
        return;
      }
    }
    final ok = await db.downloadArtifacts(_driveList, title: 'מוריד', doneMessage: '');
    if (_disposed) return;
    if (!ok) {
      _fail(null);
      return;
    }
    await pruneOldPatches(mirrorDir, _driveList);
    _done('הכונן מוכן', 'גרסה ${m.version} · אפשר לעבור למחשב ללא רשת');
  }

  Future<void> _install() async {
    await db.inspectTarget();
    if (_disposed) return;
    final plan = db.plan;
    // בתיקייה שנבחרה כבר יש מסד עדכני: רק מצרפים אותו לאוצריא.
    if (plan?.action == InstallAction.none) {
      final extra = await db.ensureAttached();
      _done('המסד מעודכן', 'גרסה ${_version ?? ''}', warning: _warningFrom(extra));
      return;
    }
    if (plan == null || !plan.canRun) {
      _fail(plan?.message ?? db.message ?? 'לא ניתן לזהות את המסד במחשב הזה.');
      return;
    }
    await db.install();
    if (_disposed) return;
    if (db.messageIsError || db.activity != null) {
      _fail(null);
      return;
    }
    await db.inspectTarget();
    if (_disposed) return;
    if (db.plan?.action != InstallAction.none) {
      // בוטל או נעצר (ההודעה כבר מ-db), או ש-install לא התחיל בכלל.
      _fail(db.message == null ? 'העדכון לא התחיל. נסו שוב.' : null);
      return;
    }
    final msg = db.message ?? '';
    final nl = msg.indexOf('\n');
    _done('המסד עודכן', 'גרסה ${_version ?? ''}', warning: nl < 0 ? null : msg.substring(nl + 1));
  }

  /// גודל בבידוד כיווניות (LRI…PDI): בלעדיו "935.1 MB" מוצג הפוך בשורה עברית.
  static String _size(int bytes) =>
      '${String.fromCharCode(0x2066)}${DbController.formatBytes(bytes)}${String.fromCharCode(0x2069)}';

  static String? _warningFrom(String attachNote) {
    final t = attachNote.trim();
    return attachNote.startsWith('\n') && t.isNotEmpty ? t : null;
  }

  // ─── הקבצים בכונן ─────────────────────────────────────────────────

  /// המסד המלא, קובצי העדכון הישירים, וצעדי העדכון של עד [stepsBack] גרסאות אחורה (בלי כפילויות).
  static List<DbArtifact> driveSet(DbManifest m, StepsManifest? steps) {
    final out = <DbArtifact>[m.full];
    final names = <String>{for (final x in m.full.parts) x.fileName};
    void add(DbArtifact a) {
      final n = [for (final x in a.parts) x.fileName];
      if (n.every(names.contains)) return;
      names.addAll(n);
      out.add(a);
    }

    final minVersion = m.version - stepsBack;
    final window = [
      for (final s in steps?.steps ?? const <DbArtifact>[])
        if (s.fromVersion! >= minVersion && steps!.chainFromSha(s.fromSha256!, m.full.sha256) != null) s,
    ]..sort((a, b) => b.fromVersion!.compareTo(a.fromVersion!));
    window.forEach(add);
    for (final d in m.deltas) {
      if (d.fromVersion! >= minVersion) add(d);
    }
    return out;
  }

  static int missingBytes(List<DbArtifact> list, String dir) {
    var total = 0;
    for (final a in list) {
      for (final part in a.parts) {
        final f = File(DbService.partPath(dir, part));
        if (!(f.existsSync() && f.lengthSync() == part.size)) total += part.size;
      }
    }
    return total;
  }

  /// מוחק מהכונן קובצי עדכון ישנים שיצאו מחלון הגרסאות (ההורדה עצמה מוחקת רק מה שאינו במניפסט).
  static Future<void> pruneOldPatches(String dir, List<DbArtifact> keep) async {
    final names = <String>{for (final a in keep) ...a.parts.map((x) => x.fileName)};
    try {
      await for (final e in Directory(dir).list()) {
        if (e is! File) continue;
        final n = p.basename(e.path);
        if (n.startsWith('$dbLibraryId-') && n.endsWith('.patch.zst') && !names.contains(n)) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ─── מצב ──────────────────────────────────────────────────────────

  static bool _existsSync(String path) {
    if (path.isEmpty) return false;
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  void _ready(QuickAction a, String t, String d) {
    if (_disposed) return;
    action = a;
    title = t;
    detail = d;
    phase = QuickPhase.ready;
    notifyListeners();
  }

  void _done(String t, String d, {String? warning}) {
    if (_disposed) return;
    title = t;
    detail = d;
    this.warning = warning;
    phase = QuickPhase.done;
    notifyListeners();
  }

  void _fail(String? text) {
    if (_disposed) return;
    if (text != null) note = text;
    phase = QuickPhase.failed;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    db.removeListener(notifyListeners);
    db.dispose();
    super.dispose();
  }
}
