import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../constants/app_constants.dart';

/// Offline-first SQLite bootstrap.
///
/// The whole app must work in a tunnel with no signal, so SQLite is the source
/// of truth and the network feeds are only ever a *cache warmer*.
class DbHelper {
  DbHelper._();

  static final DbHelper instance = DbHelper._();

  Database? _db;
  Future<Database>? _opening;

  Future<Database> get database {
    final Database? existing = _db;
    if (existing != null && existing.isOpen) return Future<Database>.value(existing);
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    try {
      final String base = await getDatabasesPath();
      final String path = p.join(base, AppConstants.dbName);
      final Database db = await openDatabase(
        path,
        version: AppConstants.dbVersion,
        onConfigure: (Database db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
      _db = db;
      return db;
    } finally {
      _opening = null;
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE ${AppConstants.tableCameras}(
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        latitude          REAL    NOT NULL,
        longitude         REAL    NOT NULL,
        max_speed         INTEGER NOT NULL,
        direction_bearing REAL,
        camera_type       TEXT    NOT NULL DEFAULT 'fixed',
        is_temporary      INTEGER NOT NULL DEFAULT 0,
        source            TEXT    NOT NULL DEFAULT 'osm',
        expires_at        INTEGER,
        updated_at        INTEGER NOT NULL
      )
    ''');

    // Identity is (lat, lon, type): a radar does not move, so re-syncing the
    // same region must UPDATE instead of duplicating.
    await db.execute('''
      CREATE UNIQUE INDEX idx_camera_identity
      ON ${AppConstants.tableCameras}(
        latitude, longitude, camera_type
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_camera_bbox
      ON ${AppConstants.tableCameras}(latitude, longitude)
    ''');

    await db.execute('''
      CREATE INDEX idx_camera_expiry
      ON ${AppConstants.tableCameras}(is_temporary, expires_at)
    ''');

    // Reports created while offline, flushed when the network comes back.
    await db.execute('''
      CREATE TABLE ${AppConstants.tablePendingReports}(
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        payload    TEXT    NOT NULL,
        created_at INTEGER NOT NULL,
        attempts   INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      )
    ''');

    // Generic key/value scratchpad for sync bookkeeping (etag, tile cursors…).
    await db.execute('''
      CREATE TABLE ${AppConstants.tableSyncMeta}(
        key   TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v1 is the initial schema; future versions add migrations here.
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Wipes every camera — used by "Clear local cache" in settings.
  Future<void> wipe() async {
    final Database db = await database;
    await db.delete(AppConstants.tableCameras);
    await db.delete(AppConstants.tablePendingReports);
    await db.delete(AppConstants.tableSyncMeta);
  }
}
