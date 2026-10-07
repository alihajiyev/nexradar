import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../models/speed_camera.dart';
import '../constants/app_constants.dart';
import '../constants/camera_types.dart';
import '../database/camera_repository.dart';
import '../database/db_helper.dart';
import '../location/heading_calculator.dart';
import 'settings_service.dart';

/// Live community radar sharing ("crowdsourcing").
///
/// Design rules:
///
/// * **SQLite always wins.** A tap on the bubble is written locally *first*,
///   so a driver in a tunnel still gets the alert and the report is uploaded
///   whenever connectivity returns (`pending_report` queue).
/// * **Two hours and it is gone.** A mobile unit does not stay put, so every
///   report carries an `expiresAt` and is pruned both locally and remotely.
/// * **Transport is pluggable.** If a real Firebase project is configured
///   (google-services.json + `Firebase.initializeApp`) the Realtime Database
///   SDK is used; otherwise we talk to the Realtime Database **REST API**
///   (`https://<db>.firebaseio.com/radars.json`), which needs no build-time
///   configuration at all and keeps the offline-first promise intact.
class CrowdsourcedRadarService {
  CrowdsourcedRadarService({
    required this.repository,
    required this.settings,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final CameraRepository repository;
  final SettingsService settings;
  final http.Client _client;

  static const String _remotePath = 'radars';

  /// Compile-time default so CI builds can bake in a database URL:
  /// `flutter build apk --dart-define=NEX_RADAR_FIREBASE_URL=https://x.firebaseio.com`
  static const String _bakedUrl =
      String.fromEnvironment('NEX_RADAR_FIREBASE_URL', defaultValue: '');

  _RemoteTransport? _transport;
  bool _transportResolved = false;

  String? get remoteBaseUrl {
    final String configured = settings.firebaseUrl.isNotEmpty
        ? settings.firebaseUrl
        : _bakedUrl;
    if (configured.isEmpty) return null;
    // Accept both the bare host and the full REST URL.
    final String base = configured.contains('://') ? configured : 'https://$configured';
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  bool get isRemoteConfigured => remoteBaseUrl != null;

  bool get isRemoteReady => _transportResolved && _transport != null;

  Future<_RemoteTransport?> _resolveTransport() async {
    if (_transportResolved) return _transport;
    _transportResolved = true;
    final String? base = remoteBaseUrl;
    if (base == null) {
      _transport = null;
      return null;
    }
    _transport = _RestTransport(_client, baseUrl: base);
    return _transport;
  }

  // -------------------------------------------------------------- reporting

  /// Called when the driver taps "＋ Radar" on the floating bubble.
  ///
  /// Returns the locally stored camera (already usable by the engine) plus
  /// whether it also reached the network.
  Future<ReportResult> reportTemporaryRadar({
    required double latitude,
    required double longitude,
    required int maxSpeed,
    double? headingDegrees,
    CameraType type = CameraType.mobile,
  }) async {
    final SpeedCamera camera = SpeedCamera(
      latitude: latitude,
      longitude: longitude,
      maxSpeed: maxSpeed,
      directionBearing: headingDegrees,
      type: type,
      isTemporary: true,
      source: SpeedCamera.sourceCommunity,
      expiresAt: DateTime.now().add(AppConstants.temporaryRadarTtl),
      updatedAt: DateTime.now(),
    );

    await repository.upsert(camera);
    final bool queued = await _enqueue(camera);

    bool uploaded = false;
    try {
      uploaded = await flushPendingQueue();
    } catch (_) {
      uploaded = false;
    }

    return ReportResult(
      camera: camera,
      storedLocally: true,
      queuedForUpload: queued,
      uploaded: uploaded,
    );
  }

  Future<bool> _enqueue(SpeedCamera camera) async {
    final Database db = await DbHelper.instance.database;
    await db.insert(AppConstants.tablePendingReports, <String, Object?>{
      'payload': jsonEncode(camera.toJson()),
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'attempts': 0,
    });
    return true;
  }

  /// Pushes every queued report to the backend. Safe to call whenever the
  /// network comes back.
  Future<bool> flushPendingQueue() async {
    final _RemoteTransport? transport = await _resolveTransport();
    if (transport == null) return false;

    final Database db = await DbHelper.instance.database;
    final List<Map<String, Object?>> rows = await db.query(
      AppConstants.tablePendingReports,
      orderBy: 'created_at ASC',
      limit: 50,
    );
    if (rows.isEmpty) return true;

    bool allOk = true;
    for (final Map<String, Object?> row in rows) {
      final int id = (row['id'] as num).toInt();
      try {
        final Map<dynamic, dynamic> json =
            jsonDecode(row['payload'] as String) as Map<dynamic, dynamic>;
        final SpeedCamera camera = SpeedCamera.fromJson(json);
        await transport.put(camera);
        await db.delete(
          AppConstants.tablePendingReports,
          where: 'id = ?',
          whereArgs: <Object?>[id],
        );
      } catch (e) {
        allOk = false;
        await db.rawUpdate(
          'UPDATE ${AppConstants.tablePendingReports} '
          'SET attempts = attempts + 1, last_error = ? WHERE id = ?',
          <Object?>[e.toString(), id],
        );
        // Drop poison rows so the queue cannot grow forever.
        await db.delete(
          AppConstants.tablePendingReports,
          where: 'attempts > 5 AND id = ?',
          whereArgs: <Object?>[id],
        );
      }
    }
    return allOk;
  }

  // ------------------------------------------------------------------ fetch

  /// Pulls every live report and merges it into SQLite.
  ///
  /// The Realtime Database REST API cannot do geo-queries, so we fetch the
  /// (small — everything expires after two hours) live set and filter locally
  /// with the same haversine helper the engine uses.
  Future<int> fetchNearby({
    required double latitude,
    required double longitude,
    double radiusMeters = AppConstants.radarHorizonMeters,
  }) async {
    final _RemoteTransport? transport = await _resolveTransport();
    if (transport == null) return 0;

    final List<SpeedCamera> remote = await transport.list();
    if (remote.isEmpty) return 0;

    final List<SpeedCamera> inRange = <SpeedCamera>[];
    for (final SpeedCamera c in remote) {
      if (c.isExpired) {
        // Best-effort remote cleanup; never block the UI on it.
        unawaited(transport.delete(c).catchError((_) => false));
        continue;
      }
      final double d = HeadingCalculator.haversineMeters(
        latitude,
        longitude,
        c.latitude,
        c.longitude,
      );
      if (d <= radiusMeters) inRange.add(c);
    }

    if (inRange.isNotEmpty) {
      await repository.upsertAll(inRange);
    }
    return inRange.length;
  }

  /// Removes timed-out community reports from the local cache.
  Future<int> purgeExpired() => repository.purgeExpiredTemporary();

  void dispose() {
    _client.close();
  }
}

class ReportResult {
  const ReportResult({
    required this.camera,
    required this.storedLocally,
    required this.queuedForUpload,
    required this.uploaded,
    this.hasFix = true,
  });

  /// No GPS fix — nothing could be reported.
  factory ReportResult.noFix() {
    return ReportResult(
      camera: SpeedCamera(
        latitude: 0,
        longitude: 0,
        maxSpeed: 0,
        source: SpeedCamera.sourceCommunity,
        isTemporary: true,
        updatedAt: DateTime.now(),
      ),
      storedLocally: false,
      queuedForUpload: false,
      uploaded: false,
      hasFix: false,
    );
  }

  final SpeedCamera camera;
  final bool storedLocally;
  final bool queuedForUpload;
  final bool uploaded;

  /// Lets callers distinguish "reported" from "no GPS fix available".
  final bool hasFix;

  bool get isSuccess => storedLocally && hasFix;

  String get message {
    if (!hasFix) return 'Konum yoxdur.';
    if (uploaded) return 'Radar yayımlandı — yaxınlıqdaki sürücülər görür.';
    if (queuedForUpload) return 'Radar yadda saxlanıldı, şəbəkə olanda göndəriləcək.';
    return 'Radar yalnız bu cihazda saxlanıldı.';
  }
}

// ---------------------------------------------------------------------------
// Transports
// ---------------------------------------------------------------------------

abstract class _RemoteTransport {
  Future<bool> put(SpeedCamera camera);
  Future<List<SpeedCamera>> list();
  Future<bool> delete(SpeedCamera camera);
}

/// Firebase Realtime Database over plain REST.
///
/// `PUT /radars/<key>.json` is idempotent, which is exactly what we want for
/// crowdsourced reports: two drivers reporting the same spot collapse into one
/// entry instead of duplicating it.
class _RestTransport implements _RemoteTransport {
  _RestTransport(this._client, {required String baseUrl}) : _base = baseUrl;


  final http.Client _client;
  final String _base;

  Uri _url([String? key]) => Uri.parse(
        '$_base/${CrowdsourcedRadarService._remotePath}'
        '${key == null ? '' : '/$key'}.json',
      );

  String _keyFor(SpeedCamera camera) => camera.identityKey.replaceAll(':', '_');

  @override
  Future<bool> put(SpeedCamera camera) async {
    final http.Response res = await _client
        .put(
          _url(_keyFor(camera)),
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(camera.toJson()),
        )
        .timeout(const Duration(seconds: 12));
    return res.statusCode >= 200 && res.statusCode < 300;
  }

  @override
  Future<List<SpeedCamera>> list() async {
    final http.Response res =
        await _client.get(_url()).timeout(const Duration(seconds: 12));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException('RTDB list failed: ${res.statusCode}');
    }
    final dynamic decoded = jsonDecode(res.body);
    if (decoded is! Map) return const <SpeedCamera>[];
    final List<SpeedCamera> out = <SpeedCamera>[];
    decoded.forEach((dynamic key, dynamic value) {
      if (value is Map) {
        try {
          out.add(SpeedCamera.fromJson(value));
        } catch (_) {
          // Malformed entry — ignore rather than poison the whole feed.
        }
      }
    });
    return out;
  }

  @override
  Future<bool> delete(SpeedCamera camera) async {
    final http.Response res = await _client
        .delete(_url(_keyFor(camera)))
        .timeout(const Duration(seconds: 12));
    return res.statusCode >= 200 && res.statusCode < 300;
  }
}

class HttpException implements Exception {
  HttpException(this.message);
  final String message;
  @override
  String toString() => 'HttpException: $message';
}
