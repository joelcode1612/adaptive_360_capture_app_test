import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/sitewise_schema.dart';

/// Opens and migrates the app's local SQLite database.
///
/// One database, one schema, one version. The store takes a [Database] rather
/// than a file path so tests can hand it an in-memory database from
/// `sqflite_common_ffi` and exercise the real DDL, the real constraints and the
/// real transactions — not a mock of them.
///
/// ## Foreign keys
///
/// SQLite defaults `PRAGMA foreign_keys` to **off**, per connection. Enabling it
/// in `onConfigure` is what makes `ON DELETE CASCADE` mean anything: without it
/// deleting a session would leave 38 orphaned frame rows pointing at JPEGs that
/// are about to be deleted.
class SitewiseDatabase {
  SitewiseDatabase._(this.db);

  /// The open handle. Callers should prefer [CaptureSessionStore] over reaching
  /// into this directly.
  final Database db;

  /// The file name inside the platform's databases directory.
  static const String fileName = 'sitewise.db';

  /// Opens the app database at its default location.
  ///
  /// [factory] and [path] exist for tests and for a desktop/FFI host; in the app
  /// both are omitted.
  static Future<SitewiseDatabase> open({
    DatabaseFactory? factory,
    String? path,
    bool singleInstance = true,
  }) async {
    final DatabaseFactory dbFactory = factory ?? databaseFactory;
    final String dbPath = path ?? p.join(await dbFactory.getDatabasesPath(), fileName);
    final Database database = await dbFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: kSitewiseSchemaVersion,
        singleInstance: singleInstance,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onDowngrade: onDatabaseDowngradeDelete,
      ),
    );
    return SitewiseDatabase._(database);
  }

  /// Wraps an already-open handle (a test that owns its own database).
  factory SitewiseDatabase.adopt(Database database) => SitewiseDatabase._(database);

  Future<void> close() => db.close();

  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    for (final statement in kSitewiseCreateStatements) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
    await _recordVersion(db, 1, version);
  }

  static Future<void> _onUpgrade(Database db, int from, int to) async {
    // Additive only. Every step runs inside the transaction sqflite already
    // opened for the upgrade, so a failure leaves the previous version intact
    // rather than a half-migrated database.
    for (var version = from + 1; version <= to; version++) {
      final statements = sitewiseMigrationStatements[version];
      if (statements == null) {
        debugPrint(
          'SITEWISE_DB: no migration registered for version $version; '
          'the schema may be older than the code expects',
        );
        continue;
      }
      for (final statement in statements) {
        await db.execute(statement);
      }
      await _recordVersion(db, version, to);
    }
  }

  static Future<void> _recordVersion(Database db, int version, int target) async {
    // `schema_migrations` is created by the first statement of the initial
    // schema; an upgrade from a database that predates it must not fail here.
    try {
      await db.insert(
        'schema_migrations',
        <String, Object?>{
          'version': version,
          'description':
              kSitewiseMigrationDescriptions[version] ?? 'schema version $version',
          'applied_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (error) {
      debugPrint('SITEWISE_DB: could not record schema version $version: $error');
    }
    debugPrint('SITEWISE_DB: schema at version $version (target $target)');
  }

  /// The highest version recorded in `schema_migrations`, or `0` when the table
  /// is empty. Used by tests and diagnostics.
  Future<int> recordedVersion() async {
    final rows = await db.rawQuery(
      'SELECT MAX(version) AS version FROM schema_migrations',
    );
    final value = rows.isEmpty ? null : rows.first['version'];
    return (value as num?)?.toInt() ?? 0;
  }
}
