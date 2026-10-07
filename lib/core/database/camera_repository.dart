import 'package:sqflite/sqflite.dart';

import '../../models/speed_camera.dart';
import '../constants/app_constants.dart';
import '../location/heading_calculator.dart';
import 'db_helper.dart';

/// Read/write access to the local radar cache.
///
/// Two-stage spatial query:
///  1. a cheap *bounding box* SQL filter (`WHERE latitude BETWEEN …`) that uses
///     the `idx_camera_bbox` index and returns a handful of rows;
///  2. a precise **Haversine** filter in Dart, which is exact on a sphere but
///     cannot use an index.
///
/// That keeps a 2000 m neighbourhood scan at well under a millisecond.
class CameraRepository {
  CameraRepository({DbHelper? dbHelper}) : _helper = dbHelper ?? DbHelper.instance;

  final DbHelper _helper;

  static const String _order = 'ORDER BY updated_at DESC';

  Future<int> count() async {
    final Database db = await _helper.database;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${AppConstants.tableCameras}',
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<int> countTemporary() async {
    final Database db = await _helper.database;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${AppConstants.tableCameras} '
      'WHERE is_temporary = 1 AND (expires_at IS NULL OR expires_at > ?)',
      <Object?>[DateTime.now().millisecondsSinceEpoch],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// Inserts or refreshes a batch of cameras (OSM sync + community feed).
  ///
  /// Duplicates are resolved by the `idx_camera_identity` unique index, so
  /// re-syncing the same tile is idempotent.
  Future<int> upsertAll(Iterable<SpeedCamera> cameras) async {
    final List<SpeedCamera> list = cameras.toList(growable: false);
    if (list.isEmpty) return 0;

    final Database db = await _helper.database;
    await db.transaction((Transaction txn) async {
      final Batch batch = txn.batch();
      for (final SpeedCamera c in list) {
        batch.insert(
          AppConstants.tableCameras,
          c.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    return list.length;
  }

  Future<int> upsert(SpeedCamera camera) async {
    final Database db = await _helper.database;
    return db.insert(
      AppConstants.tableCameras,
      camera.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// All cameras inside [radiusMeters] of the given position, nearest first,
  /// each carrying its exact distance in [SpeedCamera.distanceMeters].
  Future<List<SpeedCamera>> nearby({
    required double latitude,
    required double longitude,
    double radiusMeters = AppConstants.radarHorizonMeters,
    bool includeTemporary = true,
    bool onlyActive = true,
  }) async {
    final Database db = await _helper.database;
    final BoundingBox box = HeadingCalculator.boundingBox(
      latitude: latitude,
      longitude: longitude,
      radiusMeters: radiusMeters,
    );

    final StringBuffer where = StringBuffer(
      'latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?',
    );
    final List<Object?> args = <Object?>[box.minLat, box.maxLat, box.minLon, box.maxLon];

    if (!includeTemporary) {
      where.write(' AND is_temporary = 0');
    }
    if (onlyActive) {
      where.write(' AND (expires_at IS NULL OR expires_at > ?)');
      args.add(DateTime.now().millisecondsSinceEpoch);
    }

    final List<Map<String, Object?>> rows = await db.query(
      AppConstants.tableCameras,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'updated_at DESC',
      limit: 800,
    );

    final List<SpeedCamera> result = <SpeedCamera>[];
    for (final Map<String, Object?> row in rows) {
      final SpeedCamera camera = SpeedCamera.fromMap(row);
      final double d = HeadingCalculator.haversineMeters(
        latitude,
        longitude,
        camera.latitude,
        camera.longitude,
      );
      if (d <= radiusMeters) {
        result.add(camera.copyWith(distanceMeters: d));
      }
    }

    result.sort((SpeedCamera a, SpeedCamera b) =>
        (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity));
    return result;
  }

  Future<List<SpeedCamera>> all({int limit = 500}) async {
    final Database db = await _helper.database;
    final List<Map<String, Object?>> rows =
        await db.query(AppConstants.tableCameras, orderBy: _order, limit: limit);
    return rows.map(SpeedCamera.fromMap).toList(growable: false);
  }

  /// Removes community reports that have timed out (the "2 hour" rule).
  Future<int> purgeExpiredTemporary() async {
    final Database db = await _helper.database;
    return db.delete(
      AppConstants.tableCameras,
      where: 'is_temporary = 1 AND expires_at IS NOT NULL AND expires_at <= ?',
      whereArgs: <Object?>[DateTime.now().millisecondsSinceEpoch],
    );
  }

  Future<int> deleteById(int id) async {
    final Database db = await _helper.database;
    return db.delete(
      AppConstants.tableCameras,
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Distance from a position to the nearest camera of any type (debug/UI).
  Future<SpeedCamera?> nearest({
    required double latitude,
    required double longitude,
  }) async {
    final List<SpeedCamera> list = await nearby(
      latitude: latitude,
      longitude: longitude,
      radiusMeters: AppConstants.radarHorizonMeters,
    );
    return list.isEmpty ? null : list.first;
  }
}
