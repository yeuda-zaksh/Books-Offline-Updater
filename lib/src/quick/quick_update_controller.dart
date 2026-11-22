import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../controllers/app_controller.dart';
import '../db/db_controller.dart';
import '../db/db_manifest.dart';
import '../db/db_service.dart';
import '../services/disk_space.dart';
import '../services/otzaria_locator.dart';

enum QuickPhase { starting, needsLocation, working, done, failed }

/// "עדכון מהיר": מה שקורה כשהתוכנה מופעלת מתוך עדכוני אוצריא (תוכנות נוספות).
///
/// במחשב מחובר: מורידה לכונן את המסד המלא ואת קובצי העדכון של עד [stepsBack] הגרסאות האחרונות.
/// במחשב בלי רשת: מעדכנת (או מתקינה בפעם הראשונה) את המסד מהכונן.
class QuickUpdateController extends ChangeNotifier {
  /// [findOtzariaDb]: איפה אוצריא קוראת את המסד (מוזרק בבדיקות, כדי לא לקרוא את אוצריא של המחשב).
  QuickUpdateController({required this.mirrorDir, DbController? db, Future<String?> Function()? findOtzariaDb})
    : db = db ?? DbController(AppController()..dataDir = p.dirname(mirrorDir)),
      _findOtzariaDb = findOtzariaDb ?? OtzariaLocator.findDbPath {
    this.db.addListener(notifyListeners);
  }

  /// כמה גרסאות אחורה אפשר לעדכן בקובצי עדכון בלבד (כמו עדכוני אוצריא למסד הרשמי).
  static const stepsBack = 10;

  /// תיקיית קובצי המסד בכונן, ליד התוכנה.
  final String mirrorDir;
  final DbController db;
  final Future<String?> Function() _findOtzariaDb;

  QuickPhase phase = QuickPhase.starting;

  /// נקבע אחרי הבדיקה: `true` = מחשב מחובר (הורדה לכונן), `false` = התקנה מהכונן.
  bool? online;

  /// הודעת סיום או כשל משלנו (כשאין הודעה מ-[db]).
  String? note;

  bool _inited = false;
  bool _running = false;
  bool _disposed = false;

  /// יש פעולה בעיצומה (גם בשלבים שבהם [DbController.busy] עוד/כבר false, כמו זיהוי הגרסה).
  bool get running => _running || db.busy;

  /// אוצריא נמצאה במחשב הזה: המיקום המוצע הוא שלה, והמסד יצורף אליה.
  bool get otzariaFound => OtzariaLocator.dataRoot() != null;

  String get proposedFolder => p.dirname(OtzariaLocator.defaultNewDbPath());

  String get message => note ?? db.message ?? '';

  /// סגירה אוטומטית רק כשלא נשאר למשתמש מה לעשות: הכונן מוכן, או שהמסד מותקן ומצורף לאוצריא.
  bool get canAutoClose => phase == QuickPhase.done && (online == true || db.otzariaDbPath == db.targetDb);

  /// כשל "רך": המשתמש עצר, או ביטל אישור. מוצג בלי צבע שגיאה.
  bool get stoppedByUser => phase == QuickPhase.failed && note == null && db.message != null && !db.messageIsError;

  Future<void> start() async {
    if (_running || _disposed) return;
    _running = true;
    note = null;
    db.clearMessage();
    phase = QuickPhase.starting;
    notifyListeners();
    try {
      if (!_inited) {
        _inited = true;
        await db.init(pinMirrorDir: mirrorDir);
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
        await _prepareDrive();
      } else {
        await _applyFromDrive();
      }
    } catch (e) {
      _fail('שגיאה לא צפויה: $e');
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  // ─── מחשב מחובר ───────────────────────────────────────────────────

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

  Future<void> _prepareDrive() async {
    final m = db.remote!.manifest;
    final list = driveSet(m, db.remoteSteps?.manifest);
    final missing = missingBytes(list, mirrorDir);
    if (missing > 0) {
      final free = await freeDiskSpace(p.join(mirrorDir, 'x'));
      if (free != null && free < missing + 64 * 1024 * 1024) {
        _fail(
          'אין מספיק מקום פנוי בכונן. דרושים כ-${DbController.formatBytes(missing)}, '
          'ופנויים ${DbController.formatBytes(free)}. פנו מקום ונסו שוב.',
        );
        return;
      }
    }
    phase = QuickPhase.working;
    notifyListeners();
    final ok = await db.downloadArtifacts(
      list,
      title: missing == 0 ? 'בודק את הקבצים בכונן' : 'מוריד את עדכוני המסד לכונן',
      doneMessage: 'הכונן מוכן: מסד הספרים בגרסה ${m.version}.',
    );
    if (!ok) {
      _fail(null);
      return;
    }
    await pruneOldPatches(mirrorDir, list);
    _done();
  }

  // ─── מחשב בלי רשת ─────────────────────────────────────────────────

  Future<void> _applyFromDrive() async {
    if (db.mirror == null) {
      final net = db.remoteError == null
          ? ''
          : '\n\nאם המחשב הזה מחובר לרשת: לא הצלחנו להתחבר לשרת (${db.remoteError}).';
      _fail(
        db.mirrorError != null
            ? 'קובצי המסד בכונן אינם תקינים: ${db.mirrorError}$net'
            : 'אין בכונן קבצי מסד. הפעילו קודם את העדכון במחשב מחובר לרשת, ואז חזרו לכאן.$net',
      );
      return;
    }
    final attached = db.otzariaDbPath;
    if (attached != null) {
      if (db.targetDb != attached) {
        await db.setTarget(attached);
        if (_disposed) return;
        if (db.targetDb != attached) {
          _fail(null);
          return;
        }
      }
    } else if (!_existsSync(db.targetDb)) {
      // פעם ראשונה במחשב הזה: המשתמש מאשר (או משנה) את מיקום המסד.
      phase = QuickPhase.needsLocation;
      notifyListeners();
      return;
    }
    await _install();
  }

  /// המשתמש בחר תיקייה למסד (או אישר את המוצעת) בפעם הראשונה.
  Future<void> chooseFolder(String folder) async {
    if (phase != QuickPhase.needsLocation || _running || _disposed) return;
    _running = true;
    phase = QuickPhase.working;
    notifyListeners();
    try {
      await db.setTarget(p.join(folder, '$dbLibraryId.db'));
      if (_disposed) return;
      if (db.messageIsError && db.message != null) {
        _fail(null);
        return;
      }
      await _install();
    } catch (e) {
      _fail('שגיאה לא צפויה: $e');
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _install() async {
    phase = QuickPhase.working;
    notifyListeners();
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
        note = '${plan.message}${await db.ensureAttached()}';
        _done();
        return;
      case InstallAction.blocked:
        _fail('${plan.message}\nהפעילו את העדכון במחשב מחובר כדי להשלים את הקבצים בכונן.');
        return;
      case InstallAction.delta:
      case InstallAction.full:
        await db.install();
        if (_disposed) return;
        if (db.messageIsError || db.activity != null) {
          _fail(null);
        } else if (db.plan?.action == InstallAction.none) {
          _done();
        } else {
          // בוטל או נעצר (ההודעה כבר מ-db), או ש-install לא התחיל בכלל.
          _fail(db.message == null ? 'ההתקנה לא התחילה. נסו שוב.' : null);
        }
    }
  }

  static bool _existsSync(String path) {
    if (path.isEmpty) return false;
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  void _done() {
    if (_disposed) return;
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
