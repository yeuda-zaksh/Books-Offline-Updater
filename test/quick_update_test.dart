import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:books_offline_update/src/controllers/app_controller.dart';
import 'package:books_offline_update/src/db/db_controller.dart';
import 'package:books_offline_update/src/db/db_manifest.dart';
import 'package:books_offline_update/src/db/db_service.dart';
import 'package:books_offline_update/src/quick/quick_update_controller.dart';
import 'package:books_offline_update/src/quick/quick_update_screen.dart';
import 'package:books_offline_update/src/services/app_paths.dart';
import 'package:books_offline_update/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _sha(int n) => n.toRadixString(16).padLeft(64, '0');

Map<String, dynamic> _part(String name, int size, int sha) => {
  'url': 'https://example.com/$name',
  'size': size,
  'sha256': _sha(sha),
};

/// גרסה v: sha = v. צעד from→from+1, ודלתא ישירה from→latest.
Map<String, dynamic> _step(int from, int to, {String? name}) => {
  'compression': 'zstd-patch',
  'size': 100,
  'sha256': _sha(to),
  'from_db_version': from,
  'from_sha256': _sha(from),
  'parts': [_part(name ?? '$dbLibraryId-$to.db.from-$from.patch.zst', 10, 1000 + from * 100 + to)],
};

DbManifest _manifest(int latest, {List<int> directFrom = const []}) => DbManifest.parse(
  Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': 1,
        'library_id': dbLibraryId,
        'db_version': latest,
        'full': {
          'compression': 'zstd',
          'size': 1000,
          'sha256': _sha(latest),
          'parts': [_part('$dbLibraryId-$latest.db.zst', 50, 9999)],
        },
        'delta': [for (final f in directFrom) _step(f, latest)],
      }),
    ),
  ),
);

StepsManifest _steps(int first, int latest, {Set<int> missing = const {}}) => StepsManifest(
  libraryId: dbLibraryId,
  version: latest,
  steps: [
    for (var v = first; v < latest; v++)
      if (!missing.contains(v)) DbManifest.artifactFrom(_step(v, v + 1), delta: true),
  ],
);

DbRelease _release(DbManifest m) => DbRelease(Uint8List(0), '', m);

/// בקר מסד בלי רשת, בלי הגדרות על הדיסק ובלי לגעת באוצריא.
class _FakeDb extends DbController {
  _FakeDb() : super(AppController());

  DbRelease? fakeRemote;
  StepsRelease? fakeSteps;
  DbRelease? fakeMirror;
  String? attachedPath;
  String initialTarget = '';
  List<DbArtifact>? downloaded;
  bool installed = false;
  bool downloadOk = true;
  String? fakeRemoteError;
  bool installNoop = false;
  String? installStopMessage;

  @override
  Future<void> init({String? pinMirrorDir}) async {
    mirrorDir = pinMirrorDir ?? '';
    otzariaDbPath = attachedPath;
    targetDb = initialTarget;
    await refreshMirror();
    await checkRemote();
  }

  @override
  Future<void> refreshMirror() async => mirror = fakeMirror;

  @override
  Future<void> checkRemote() async {
    remote = fakeRemote;
    remoteSteps = fakeSteps;
    remoteError = fakeRemoteError;
  }

  @override
  Future<void> inspectTarget() async {}

  @override
  Future<void> setTarget(String path) async => targetDb = path;

  @override
  Future<bool> downloadArtifacts(List<DbArtifact> list, {required String title, String? doneMessage}) async {
    downloaded = list;
    return downloadOk;
  }

  @override
  InstallPlan? get plan => installed
      ? InstallPlan(InstallAction.none, 'עדכני')
      : InstallPlan(InstallAction.full, 'מלא', artifact: mirror!.manifest.full);

  @override
  Future<void> install() async {
    if (installNoop) return;
    if (installStopMessage != null) {
      message = installStopMessage;
      messageIsError = false;
      return;
    }
    installed = true;
  }
}

/// בקר מסד אמיתי עם הגדרות בתיקייה זמנית, בלי פנייה לרשת.
class _NoNetDb extends DbController {
  _NoNetDb(String configDir) : super(AppController(), configDir: configDir);

  @override
  Future<void> checkRemote() async {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('quick'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('הקבצים שיורדים לכונן', () {
    test('מסד מלא + צעדים של 10 גרסאות אחורה + דלתאות ישירות, בלי כפילויות', () {
      final m = _manifest(52, directFrom: [50, 51]);
      final set = QuickUpdateController.driveSet(m, _steps(30, 52));
      expect(set.first, same(m.full));
      final steps = set.skip(1).where((a) => int.parse(a.sha256, radix: 16) == a.fromVersion! + 1);
      expect(steps.map((a) => a.fromVersion).toSet(), {42, 43, 44, 45, 46, 47, 48, 49, 50, 51});
      // הדלתא הישירה 51→52 זהה לצעד (אותו שם קובץ): לא נוספת שוב. 50→52 כן.
      final direct = set.where((a) => a.fromVersion == 50 && a.sha256 == _sha(52)).toList();
      expect(direct, hasLength(1));
      final names = [for (final a in set) ...a.parts.map((x) => x.fileName)];
      expect(names.toSet().length, names.length);
    });

    test('בלי מניפסט צעדים: המסד המלא והדלתאות הישירות', () {
      final m = _manifest(52, directFrom: [51]);
      final set = QuickUpdateController.driveSet(m, null);
      expect(set, hasLength(2));
    });

    test('צעד שאין ממנו שרשרת עד העדכנית לא יורד', () {
      final m = _manifest(52);
      final set = QuickUpdateController.driveSet(m, _steps(40, 52, missing: {47}));
      expect(set.skip(1).map((a) => a.fromVersion).toSet(), {48, 49, 50, 51});
    });
  });

  test('ניקוי קובצי עדכון ישנים מהכונן בלבד', () async {
    final keep = QuickUpdateController.driveSet(_manifest(52), _steps(48, 52));
    for (final n in [
      '$dbLibraryId-49.db.from-48.patch.zst',
      '$dbLibraryId-40.db.from-39.patch.zst',
      '$dbLibraryId-52.db.zst',
      'other.patch.zst',
      'manifest.json',
    ]) {
      File(p.join(tmp.path, n)).writeAsStringSync('x');
    }
    await QuickUpdateController.pruneOldPatches(tmp.path, keep);
    final left = tmp.listSync().map((e) => p.basename(e.path)).toSet();
    expect(left, {
      '$dbLibraryId-49.db.from-48.patch.zst',
      '$dbLibraryId-52.db.zst',
      'other.patch.zst',
      'manifest.json',
    });
  });

  test('זיהוי הפעלה מתוך עדכוני אוצריא', () {
    expect(AppPaths.launchedFromOtzariaUpdates(tmp.path), isFalse);
    File(p.join(tmp.path, 'descriptor.json')).writeAsStringSync('{}');
    expect(AppPaths.launchedFromOtzariaUpdates(tmp.path), isFalse);
    File(p.join(tmp.path, 'installer.json')).writeAsStringSync('{}');
    expect(AppPaths.launchedFromOtzariaUpdates(tmp.path), isTrue);
  });

  group('זרימת העדכון המהיר', () {
    late _FakeDb db;
    late QuickUpdateController c;
    setUp(() {
      db = _FakeDb();
      c = QuickUpdateController(mirrorDir: p.join(tmp.path, dbMirrorDirName), db: db);
    });
    tearDown(() => c.dispose());

    test('מחשב מחובר: מוריד לכונן את כל הסט ומסיים', () async {
      final m = _manifest(52, directFrom: [50, 51]);
      db.fakeRemote = _release(m);
      db.fakeSteps = StepsRelease(Uint8List(0), '', _steps(40, 52));
      await c.start();
      expect(c.online, isTrue);
      expect(c.phase, QuickPhase.done);
      expect(
        db.downloaded!.map((a) => a.parts.first.fileName),
        QuickUpdateController.driveSet(m, db.fakeSteps!.manifest).map((a) => a.parts.first.fileName),
      );
      expect(db.installed, isFalse);
    });

    test('מחשב מחובר: הורדה שנכשלה מציגה כשל ואפשר לנסות שוב', () async {
      db.fakeRemote = _release(_manifest(52));
      db.downloadOk = false;
      await c.start();
      expect(c.phase, QuickPhase.failed);
      db.downloadOk = true;
      await c.start();
      expect(c.phase, QuickPhase.done);
    });

    test('בלי רשת ובלי קבצים בכונן: הסבר', () async {
      await c.start();
      expect(c.online, isFalse);
      expect(c.phase, QuickPhase.failed);
      expect(c.message, contains('במחשב מחובר'));
    });

    test('בלי רשת, פעם ראשונה: שואלים על מיקום, ואז מתקינים שם', () async {
      db.fakeMirror = _release(_manifest(52));
      db.initialTarget = p.join(tmp.path, 'none', 'x.db');
      await c.start();
      expect(c.phase, QuickPhase.needsLocation);
      expect(db.installed, isFalse);
      final folder = p.join(tmp.path, 'chosen');
      await c.chooseFolder(folder);
      expect(db.targetDb, p.join(folder, '$dbLibraryId.db'));
      expect(db.installed, isTrue);
      expect(c.phase, QuickPhase.done);
    });

    test('בלי רשת, המסד כבר מצורף לאוצריא: מתקינים בלי לשאול', () async {
      db.fakeMirror = _release(_manifest(52));
      final attached = p.join(tmp.path, 'otz', '$dbLibraryId.db');
      db.attachedPath = attached;
      await c.start();
      expect(db.targetDb, attached);
      expect(db.installed, isTrue);
      expect(c.phase, QuickPhase.done);
    });

    test('בלי רשת, מסד קיים שנבחר בעבר: מתקינים בלי לשאול', () async {
      db.fakeMirror = _release(_manifest(52));
      final existing = File(p.join(tmp.path, 'mine.db'))..writeAsStringSync('');
      db.initialTarget = existing.path;
      await c.start();
      expect(db.installed, isTrue);
      expect(c.phase, QuickPhase.done);
    });

    test('סגירה אוטומטית: רק כשאין מה לעשות (מחובר, או מסד מצורף לאוצריא)', () async {
      db.fakeMirror = _release(_manifest(52));
      db.initialTarget = p.join(tmp.path, 'none', 'x.db');
      await c.start();
      await c.chooseFolder(p.join(tmp.path, 'chosen'));
      expect(c.phase, QuickPhase.done);
      expect(c.canAutoClose, isFalse, reason: 'המסד הותקן אבל לא צורף לאוצריא');

      final db2 = _FakeDb()
        ..fakeMirror = _release(_manifest(52))
        ..attachedPath = p.join(tmp.path, 'otz.db');
      final c2 = QuickUpdateController(mirrorDir: tmp.path, db: db2);
      await c2.start();
      expect(c2.canAutoClose, isTrue);
      c2.dispose();
    });

    test('בחירת תיקייה: עוברים מיד לשלב העבודה, ולחיצה כפולה נבלעת', () async {
      db.fakeMirror = _release(_manifest(52));
      db.initialTarget = p.join(tmp.path, 'none', 'x.db');
      await c.start();
      final first = c.chooseFolder(p.join(tmp.path, 'a'));
      expect(c.phase, QuickPhase.working);
      expect(c.running, isTrue);
      await c.chooseFolder(p.join(tmp.path, 'b'));
      await first;
      expect(db.targetDb, p.join(tmp.path, 'a', '$dbLibraryId.db'));
    });

    test('ההתקנה לא התחילה (בלי הודעה): הודעה ברורה ולא ריקה', () async {
      db.fakeMirror = _release(_manifest(52));
      db.attachedPath = p.join(tmp.path, 'otz.db');
      db.installNoop = true;
      await c.start();
      expect(c.phase, QuickPhase.failed);
      expect(c.message, contains('לא התחילה'));
    });

    test('עצירה בידי המשתמש: כשל רך, לא שגיאה; וניסיון חוזר מצליח', () async {
      db.fakeMirror = _release(_manifest(52));
      db.attachedPath = p.join(tmp.path, 'otz.db');
      db.installStopMessage = 'הפעולה נעצרה. המסד הקיים לא שונה.';
      await c.start();
      expect(c.phase, QuickPhase.failed);
      expect(c.stoppedByUser, isTrue);
      db.installStopMessage = null;
      await c.start();
      expect(c.phase, QuickPhase.done);
    });

    test('בלי קבצים בכונן ויש שגיאת רשת: מוצגת גם שגיאת הרשת', () async {
      db.fakeRemoteError = 'חסום';
      await c.start();
      expect(c.message, contains('חסום'));
    });

    test('אחרי dispose תהליך שרץ לא זורק ולא מודיע', () async {
      db.fakeMirror = _release(_manifest(52));
      db.attachedPath = p.join(tmp.path, 'otz.db');
      final run = c.start();
      c.dispose();
      await run;
      expect(c.phase, isNot(QuickPhase.done));
      // tearDown קורא שוב ל-dispose: מחליפים בבקר חדש.
      c = QuickUpdateController(mirrorDir: tmp.path, db: _FakeDb());
    });
  });

  group('שמירת ההגדרות במצב מהיר', () {
    test('תיקיית המראה הננעצת לא דורסת את זו שנשמרה', () async {
      final cfg = Directory(p.join(tmp.path, 'cfg'))..createSync();
      final settings = File(p.join(cfg.path, 'db_settings.json'));
      settings.writeAsStringSync(jsonEncode({'mirrorDir': 'D:/saved', 'targetDb': p.join(tmp.path, 'a.db')}));
      final db = _NoNetDb(cfg.path);
      await db.init(pinMirrorDir: p.join(tmp.path, 'pinned'));
      expect(db.mirrorDir, p.join(tmp.path, 'pinned'));
      await db.setTarget(p.join(tmp.path, 'b.db'));
      final j = jsonDecode(settings.readAsStringSync()) as Map<String, dynamic>;
      expect(j['mirrorDir'], 'D:/saved');
      expect(j['targetDb'], p.join(tmp.path, 'b.db'));
      db.dispose();
    });

    test('בלי תיקייה שמורה: נשמר ריק (ברירת המחדל), לא התיקייה הננעצת', () async {
      final cfg = Directory(p.join(tmp.path, 'cfg'))..createSync();
      final settings = File(p.join(cfg.path, 'db_settings.json'));
      settings.writeAsStringSync(jsonEncode({'targetDb': p.join(tmp.path, 'a.db')}));
      final db = _NoNetDb(cfg.path);
      await db.init(pinMirrorDir: p.join(tmp.path, 'pinned'));
      await db.setTarget(p.join(tmp.path, 'b.db'));
      final j = jsonDecode(settings.readAsStringSync()) as Map<String, dynamic>;
      expect(j['mirrorDir'], '');
      db.dispose();
    });
  });

  group('המסך', () {
    Widget host(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      builder: (context, ch) => Directionality(textDirection: TextDirection.rtl, child: ch!),
      home: child,
    );

    testWidgets('פעם ראשונה: מוצג המיקום המוצע ושני כפתורים', (t) async {
      final db = _FakeDb()
        ..fakeMirror = _release(_manifest(52))
        ..initialTarget = p.join(tmp.path, 'none', 'x.db');
      final c = QuickUpdateController(mirrorDir: tmp.path, db: db);
      // המסך קיים לפני שהתהליך רץ: הכפתורים חייבים להיות פעילים בסיומו (באג: נשארו מושבתים).
      await t.pumpWidget(host(QuickUpdateScreen(controller: c, autoStart: false, onClose: () {})));
      await t.runAsync(c.start);
      await t.pump();
      expect(find.text(c.proposedFolder), findsOneWidget);
      final ok = t.widget<ButtonStyleButton>(
        find.ancestor(of: find.text('התקנה בתיקייה הזו'), matching: find.bySubtype<ButtonStyleButton>()),
      );
      final other = t.widget<ButtonStyleButton>(
        find.ancestor(of: find.text('בחירת תיקייה אחרת'), matching: find.bySubtype<ButtonStyleButton>()),
      );
      expect(ok.onPressed, isNotNull);
      expect(other.onPressed, isNotNull);
      expect(find.text('פתיחת התוכנה המלאה'), findsNothing, reason: 'לא הועבר onOpenFull');
    });

    testWidgets('אחרי סיום: הכפתור לתוכנה המלאה מוצג', (t) async {
      final db = _FakeDb();
      final c = QuickUpdateController(mirrorDir: tmp.path, db: db);
      await t.pumpWidget(host(QuickUpdateScreen(controller: c, autoStart: false, onClose: () {}, onOpenFull: () {})));
      await t.runAsync(c.start);
      await t.pump();
      expect(c.phase, QuickPhase.failed);
      expect(find.text('פתיחת התוכנה המלאה'), findsOneWidget);
    });

    testWidgets('הצלחה: נסגר לבד אחרי הספירה', (t) async {
      final db = _FakeDb()..fakeRemote = _release(_manifest(52));
      final c = QuickUpdateController(mirrorDir: tmp.path, db: db);
      var closed = false;
      await t.pumpWidget(
        host(
          QuickUpdateScreen(
            controller: c,
            autoStart: false,
            autoCloseAfter: const Duration(seconds: 3),
            onClose: () => closed = true,
          ),
        ),
      );
      // זהו קובץ שכבר "בכונן": אין צורך בבדיקת מקום פנוי (שעלולה לא להסתיים בזמן המדומה).
      final f = db.fakeRemote!.manifest.full.parts.first;
      File(p.join(tmp.path, f.fileName)).writeAsBytesSync(List.filled(f.size, 0));
      // start רץ באזור הזמן המדומה (שם נוצר טיימר הסגירה); פעולות הקבצים האמיתיות מסתיימות בהמתנה אמיתית.
      unawaited(c.start());
      for (var i = 0; i < 100 && c.phase != QuickPhase.done; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump();
      }
      expect(c.phase, QuickPhase.done);
      expect(find.text('סגור'), findsOneWidget);
      expect(find.textContaining('חברו את הכונן'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      expect(closed, isTrue);
    });
  });
}
