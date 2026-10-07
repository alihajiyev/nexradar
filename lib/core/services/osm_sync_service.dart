import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/speed_camera.dart';
import '../constants/app_constants.dart';
import '../constants/camera_types.dart';
import '../database/camera_repository.dart';
import '../location/heading_calculator.dart';

/// Pulls `highway=speed_camera` (and friends) out of OpenStreetMap via the
/// Overpass API and caches them in SQLite.
///
/// OSM is the offline-friendly backbone of the camera database: it is free,
/// global, community-maintained, and — crucially — an *area* fetch, so a driver
/// can cache a whole city before losing signal.
class OsmSyncService {
  OsmSyncService({required this.repository, http.Client? client})
      : _client = client ?? http.Client();

  final CameraRepository repository;
  final http.Client _client;

  /// Runs the query against each mirror until one answers.
  Future<SyncResult> syncCameras({
    required double latitude,
    required double longitude,
    double radiusMeters = AppConstants.defaultSyncRadiusMeters,
    void Function(String message)? onLog,
  }) async {
    final Stopwatch clock = Stopwatch()..start();
    final double radius = radiusMeters.clamp(
      1000.0,
      AppConstants.maxSyncRadiusMeters,
    );
    final BoundingBox box = HeadingCalculator.boundingBox(
      latitude: latitude,
      longitude: longitude,
      radiusMeters: radius,
    );
    final String query = buildOverpassQuery(box);

    Object? lastError;
    for (final String endpoint in AppConstants.overpassEndpoints) {
      try {
        onLog?.call('OSM sorğusu: ${Uri.parse(endpoint).host}');
        final List<SpeedCamera> cameras = await _query(
          Uri.parse(endpoint),
          query,
        );
        final int stored = await repository.upsertAll(cameras);
        clock.stop();
        onLog?.call('$stored radar OSM-dən yazıldı (${clock.elapsedMilliseconds} ms)');
        return SyncResult(
          ok: true,
          fetched: cameras.length,
          stored: stored,
          endpoint: endpoint,
          radiusMeters: radius,
          durationMs: clock.elapsedMilliseconds,
        );
      } catch (e) {
        lastError = e;
        if (kDebugMode) debugPrint('[OsmSync] $endpoint failed: $e');
        onLog?.call('${Uri.parse(endpoint).host} alınmadı, növbəti server...');
      }
    }
    clock.stop();
    return SyncResult(
      ok: false,
      fetched: 0,
      stored: 0,
      error: lastError?.toString() ?? 'Naməlum xəta',
      radiusMeters: radius,
      durationMs: clock.elapsedMilliseconds,
    );
  }

  static String buildOverpassQuery(BoundingBox box) {
    final String bbox = '${box.minLat},${box.minLon},${box.maxLat},${box.maxLon}';
    return '''
[out:json][timeout:${AppConstants.overpassTimeout.inSeconds}];
(
  node["highway"="speed_camera"]($bbox);
  node["enforcement"="maxspeed"]($bbox);
  node["enforcement"="average_speed"]($bbox);
  node["highway"="speed_display"]["camera"~"yes"]($bbox);
);
out body;
''';
  }

  Future<List<SpeedCamera>> _query(Uri endpoint, String query) async {
    final http.Response res = await _client
        .post(
          endpoint,
          headers: const <String, String>{
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': 'NexRadar/1.0 (speed camera HUD)',
          },
          body: <String, String>{'data': query},
        )
        .timeout(AppConstants.overpassTimeout);

    if (res.statusCode != 200) {
      throw Exception('Overpass HTTP ${res.statusCode}');
    }

    final dynamic decoded = jsonDecode(res.body);
    if (decoded is! Map || decoded['elements'] is! List) {
      throw Exception('Overpass cavabı gözlənilən formatda deyil');
    }

    final List<SpeedCamera> out = <SpeedCamera>[];
    for (final dynamic element in decoded['elements'] as List<dynamic>) {
      if (element is! Map) continue;
      final dynamic lat = element['lat'];
      final dynamic lon = element['lon'];
      if (lat is! num || lon is! num) continue;

      final Map<String, String> tags = <String, String>{};
      final dynamic rawTags = element['tags'];
      if (rawTags is Map) {
        rawTags.forEach((dynamic k, dynamic v) => tags['$k'] = '$v');
      }

      out.add(
        SpeedCamera(
          latitude: lat.toDouble(),
          longitude: lon.toDouble(),
          maxSpeed: parseMaxSpeed(tags['maxspeed']) ??
              AppConstants.defaultSpeedLimitKmh.round(),
          directionBearing: parseDirection(
            tags['direction'] ?? tags['camera:direction'],
          ),
          type: parseCameraType(tags),
          isTemporary: false,
          source: SpeedCamera.sourceOsm,
          updatedAt: DateTime.now(),
        ),
      );
    }
    return out;
  }

  /// Parses OSM's many spellings of a speed limit: `80`, `80 km/h`,
  /// `50 mph`, `30 knots`, `AZ:urban`, `walk`…
  static int? parseMaxSpeed(String? raw) {
    if (raw == null) return null;
    final String value = raw.trim().toLowerCase();
    if (value.isEmpty) return null;
    if (value == 'none' || value == 'signals' || value == 'variable') return null;
    if (value == 'walk' || value == 'foot') return 10;

    final RegExpMatch? number = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(value);
    if (number == null) {
      // Named zones we care about.
      if (value.contains('urban')) return 60;
      if (value.contains('rural')) return 90;
      if (value.contains('motorway')) return 110;
      if (value.contains('living_street')) return 20;
      return null;
    }

    final double parsed =
        double.tryParse(number.group(1)!.replaceAll(',', '.')) ?? 0;
    if (parsed <= 0) return null;

    double kmh = parsed;
    if (value.contains('mph')) {
      kmh = parsed * 1.609344;
    } else if (value.contains('knot')) {
      kmh = parsed * 1.852;
    }
    final int rounded = kmh.round();
    // Reject nonsense values that would confuse the driver.
    if (rounded < 5 || rounded > 160) return null;
    return rounded;
  }

  /// `direction=270`, `direction=W`, `direction=north` → degrees.
  ///
  /// Matching is on the *whole* normalized token, never on a prefix: a prefix
  /// check would happily read `nonsense` as due north.
  static double? parseDirection(String? raw) {
    if (raw == null) return null;
    final String value = raw.trim().toLowerCase();
    if (value.isEmpty) return null;

    final double? numeric = double.tryParse(value);
    if (numeric != null) {
      if (numeric < 0 || numeric > 360) return null;
      return numeric % 360;
    }

    const Map<String, double> compass = <String, double>{
      'n': 0, 'north': 0,
      'ne': 45, 'northeast': 45,
      'e': 90, 'east': 90,
      'se': 135, 'southeast': 135,
      's': 180, 'south': 180,
      'sw': 225, 'southwest': 225,
      'w': 270, 'west': 270,
      'nw': 315, 'northwest': 315,
    };
    // Normalize separators so "north east", "north-east" and "north_east"
    // all collapse onto the same key.
    final String flat = value.replaceAll(RegExp(r'[\s_-]'), '');
    return compass[flat];
  }

  /// Maps OSM tags onto our four enforcement categories.
  static CameraType parseCameraType(Map<String, String> tags) {
    final String enforcement = (tags['enforcement'] ?? '').toLowerCase();
    final String speedCamera = (tags['speed_camera'] ?? '').toLowerCase();
    final String highway = (tags['highway'] ?? '').toLowerCase();
    final String cameraMount = (tags['camera:mount'] ?? '').toLowerCase();
    final String cameraType = (tags['camera:type'] ?? '').toLowerCase();

    if (enforcement == 'average_speed' || speedCamera == 'average_speed') {
      return CameraType.averageSpeed;
    }
    if (highway == 'traffic_signals' ||
        tags['camera:type'] == 'traffic_signals' ||
        speedCamera == 'traffic_signals') {
      return CameraType.redLight;
    }
    if (speedCamera == 'mobile' ||
        cameraMount == 'mobile' ||
        cameraType == 'mobile' ||
        enforcement == 'maxspeed_mobile') {
      return CameraType.mobile;
    }
    return CameraType.fixed;
  }

  void dispose() => _client.close();
}

class SyncResult {
  const SyncResult({
    required this.ok,
    required this.fetched,
    required this.stored,
    this.endpoint,
    this.error,
    this.radiusMeters = 0,
    this.durationMs = 0,
  });

  final bool ok;
  final int fetched;
  final int stored;
  final String? endpoint;
  final String? error;
  final double radiusMeters;
  final int durationMs;

  String get message {
    if (!ok) return 'Sinxronizasiya alınmadı: ${error ?? 'naməlum xəta'}';
    if (fetched == 0) return 'Bu radiusda OSM-də radar tapılmadı.';
    return '$stored radar yükləndi (${(radiusMeters / 1000).toStringAsFixed(0)} km).';
  }
}
