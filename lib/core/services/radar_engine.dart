import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/speed_camera.dart';
import '../../models/vehicle_state.dart';
import '../constants/app_constants.dart';
import '../constants/camera_types.dart';
import '../database/camera_repository.dart';
import '../location/heading_calculator.dart';
import '../location/location_service.dart';
import '../location/speed_interpolator.dart';
import 'alert_service.dart';
import 'crowdsourced_radar_service.dart';
import 'osm_sync_service.dart';
import 'overlay_service.dart';
import 'settings_service.dart';
import 'tts_service.dart';

/// The brain of NexRadar.
///
/// Pipeline, once per GPS fix (≈1 Hz):
///
/// ```
/// GPS ─▶ heading ─▶ local cache (2 km, SQLite + haversine)
///                   └─▶ angular target filter  |θ_heading − θ_camera| ≤ 45°
///                        └─▶ nearest forward threat
///                             ├─▶ VehicleState (status / limit / remaining)
///                             ├─▶ native overlay payload
///                             ├─▶ TTS ladder   400 m → 150 m
///                             └─▶ beep ladder  500 m → 200 m / speeding
/// ```
///
/// Between fixes, [onFrame] advances the 60 FPS interpolation so the needle
/// glides instead of stepping, and forwards the smoothed value to the floating
/// bubble.
class RadarEngine {
  RadarEngine({
    required this.repository,
    required this.locationService,
    required this.settings,
    required this.tts,
    required this.alerts,
    required this.overlay,
    required this.crowd,
    required this.osmSync,
  });

  final CameraRepository repository;
  final LocationService locationService;
  final SettingsService settings;
  final TtsService tts;
  final AlertService alerts;
  final OverlayService overlay;
  final CrowdsourcedRadarService crowd;
  final OsmSyncService osmSync;

  /// The single snapshot every widget renders from.
  final ValueNotifier<VehicleState> state =
      ValueNotifier<VehicleState>(VehicleState.empty());

  /// Smoothed needle value (60 FPS).
  final SpeedInterpolator interpolator = SpeedInterpolator();

  /// Rolling log shown on the dashboard.
  final ValueNotifier<List<EngineLogEntry>> log =
      ValueNotifier<List<EngineLogEntry>>(const <EngineLogEntry>[]);

  StreamSubscription<Position>? _positionSub;
  Timer? _communityTimer;

  bool _running = false;
  bool get isRunning => _running;

  // ------------------------------------------------------------- cache state
  List<SpeedCamera> _cache = const <SpeedCamera>[];
  DateTime _cacheLoadedAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _cacheLat = double.nan;
  double _cacheLon = double.nan;

  // ------------------------------------------------------------ motion state
  Position? _previous;
  double _heading = 0;
  bool _hadFix = false;

  /// Lowest distance we have seen per camera, so we only announce *crossings*
  /// (and a later revisit re-announces).
  final Map<String, double> _lastDistance = <String, double>{};
  final Set<String> _spokenSlowDown = <String>{};

  DateTime _lastOverlayPush = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastPushedSignature = '';

  int get cameraCacheSize => _cache.length;
  double get heading => _heading;

  // ---------------------------------------------------------------- lifecycle

  Future<void> start({bool background = true}) async {
    if (_running) return;
    _running = true;
    _appendLog('Mühərrik işə salındı');

    _positionSub = locationService.positions(background: background).listen(
      _onPosition,
      onError: (Object e) => _appendLog('GPS xətası: $e'),
    );

    // Community radars refresh on a timer, independent of GPS cadence.
    _communityTimer?.cancel();
    _communityTimer = Timer.periodic(
      AppConstants.communityPollInterval,
      (_) => unawaited(refreshCommunity()),
    );

    final Position? last = await locationService.lastKnown();
    if (last != null) {
      await _onPosition(last);
    }
  }

  Future<void> stop() async {
    _running = false;
    await _positionSub?.cancel();
    _positionSub = null;
    _communityTimer?.cancel();
    _communityTimer = null;
    await tts.stop();
    await alerts.stopAll();
    await overlay.hide();
    _appendLog('Mühərrik dayandırıldı');
  }

  // -------------------------------------------------------------- GPS intake

  Future<void> _onPosition(Position p) async {
    if (!_running) return;

    // A fix with no speed at all is useless for a speedometer; keep the last
    // known one but do not treat it as a new sample.
    final double kmh = LocationService.kmh(p);
    _heading = _computeHeading(p);
    _previous = p;

    await _refreshCacheIfStale(p.latitude, p.longitude);

    final List<SpeedCamera> forward = _forwardThreats(
      latitude: p.latitude,
      longitude: p.longitude,
      heading: _heading,
    );
    final SpeedCamera? nearest = forward.isEmpty ? null : forward.first;

    final VehicleState next = VehicleState(
      speedKmh: interpolator.current,
      rawSpeedKmh: kmh,
      headingDegrees: _heading,
      latitude: p.latitude,
      longitude: p.longitude,
      accuracyMeters: p.accuracy,
      timestamp: DateTime.now(),
      threat: nearest,
      threatDistanceMeters: nearest?.distanceMeters,
      threatBearingDegrees: nearest == null
          ? null
          : HeadingCalculator.bearingDegrees(
              p.latitude,
              p.longitude,
              nearest.latitude,
              nearest.longitude,
            ),
      hasFix: true,
      camerasInRange: _cache.length,
    );

    interpolator.setTarget(kmh);
    if (!_hadFix) {
      // First fix: jump straight to the value, no sweep from zero.
      interpolator.snapTo(kmh);
      _hadFix = true;
    }

    // Keep the smoothed value and the raw sample consistent inside one state
    // object so listeners never see a half-updated snapshot.
    state.value = next.copyWith(speedKmh: interpolator.current);

    _evaluateAlerts(state.value);
    await _maybePushToOverlay(force: true);
  }

  /// GPS `heading` is only trustworthy while actually moving; when it is not we
  /// derive the bearing from consecutive fixes, then low-pass the result so the
  /// angular filter does not twitch.
  double _computeHeading(Position p) {
    double candidate = _heading;
    if (p.heading >= 0 && p.heading < 360 && p.speed > 1.5) {
      candidate = p.heading;
    } else if (_previous != null) {
      final double moved = HeadingCalculator.haversineMeters(
        _previous!.latitude,
        _previous!.longitude,
        p.latitude,
        p.longitude,
      );
      if (moved > 4.0) {
        candidate = HeadingCalculator.bearingDegrees(
          _previous!.latitude,
          _previous!.longitude,
          p.latitude,
          p.longitude,
        );
      }
    }
    // Circular exponential smoothing (never average across the 0°/360° seam).
    final double delta = _signedAngleDelta(candidate, _heading);
    return HeadingCalculator.normalizeDegrees(_heading + delta * 0.45);
  }

  static double _signedAngleDelta(double target, double current) {
    double d = (target - current) % 360;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return d;
  }

  // ------------------------------------------------------------ spatial query

  Future<void> _refreshCacheIfStale(double lat, double lon) async {
    final DateTime now = DateTime.now();
    final bool timeExpired =
        now.difference(_cacheLoadedAt) > AppConstants.cameraRefreshInterval;
    final bool movedAway = !_cacheLat.isNaN &&
        HeadingCalculator.haversineMeters(_cacheLat, _cacheLon, lat, lon) >
            AppConstants.cameraRefreshMoveMeters;
    if (!timeExpired && !movedAway && _cache.isNotEmpty) return;

    _cacheLoadedAt = now;
    _cacheLat = lat;
    _cacheLon = lon;
    _cache = await repository.nearby(
      latitude: lat,
      longitude: lon,
      radiusMeters: AppConstants.radarHorizonMeters,
    );

    // Forget crossings for cameras that are no longer around.
    if (_lastDistance.isNotEmpty) {
      final Set<String> alive = _cache.map((SpeedCamera c) => c.identityKey).toSet();
      _lastDistance.removeWhere((String k, _) => !alive.contains(k));
      _spokenSlowDown.removeWhere((String k) => !alive.contains(k));
    }
  }

  /// Applies the angular target filter; result is sorted by distance.
  List<SpeedCamera> _forwardThreats({
    required double latitude,
    required double longitude,
    required double heading,
  }) {
    final List<SpeedCamera> out = <SpeedCamera>[];
    for (final SpeedCamera c in _cache) {
      final double? d = c.distanceMeters;
      if (d == null) continue;
      final double bearing = HeadingCalculator.bearingDegrees(
        latitude,
        longitude,
        c.latitude,
        c.longitude,
      );
      final bool ahead = HeadingCalculator.isForwardThreat(
        headingDegrees: heading,
        bearingToCamera: bearing,
        cameraDirection: c.directionBearing,
        toleranceDegrees: settings.angularTolerance,
      );
      if (ahead) {
        out.add(c);
      }
    }
    out.sort((SpeedCamera a, SpeedCamera b) =>
        (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity));
    return out;
  }

  // ----------------------------------------------------------- alert ladder

  void _evaluateAlerts(VehicleState s) {
    final SpeedCamera? camera = s.threat;
    final double? distance = s.threatDistanceMeters;
    if (camera == null || distance == null) return;

    final String key = camera.identityKey;
    final double? previous = _lastDistance[key];
    _lastDistance[key] = distance;

    final bool closing = previous == null || distance < previous;

    // --- voice ladder (crossing detection, so each gate fires exactly once) --
    if (settings.voiceEnabled) {
      final bool crossedFar = previous == null
          ? distance <= AppConstants.voiceFarMeters
          : previous > AppConstants.voiceFarMeters &&
              distance <= AppConstants.voiceFarMeters;
      final bool crossedNear = previous == null
          ? distance <= AppConstants.voiceNearMeters
          : previous > AppConstants.voiceNearMeters &&
              distance <= AppConstants.voiceNearMeters;

      if (crossedFar) {
        _appendLog('${camera.type.wire} radar ${distance.round()} m '
            '— hədd ${camera.maxSpeed}');
        unawaited(
          camera.isTemporary
              ? tts.announceCommunityReport(limitKmh: camera.maxSpeed)
              : tts.announceCameraAhead(
                  limitKmh: camera.maxSpeed,
                  distanceMeters: distance.round(),
                ),
        );
      }

      if (crossedNear && !_spokenSlowDown.contains(key)) {
        _spokenSlowDown.add(key);
        unawaited(
          tts.announceSlowDown(
            distanceMeters: distance.round(),
            limitKmh: camera.maxSpeed,
          ),
        );
      }
    }

    // --- audible/kinetic ladder ---------------------------------------------
    if (settings.beepEnabled && closing) {
      if (s.isSpeeding && distance <= AppConstants.overlayWarnFarMeters) {
        unawaited(alerts.alarm());
        if (settings.voiceEnabled && s.speedKmh > camera.maxSpeed + 12) {
          unawaited(
            tts.announceSpeeding(
              speedKmh: s.speedKmh.round(),
              limitKmh: camera.maxSpeed,
            ),
          );
        }
      } else if (distance <= AppConstants.overlayWarnNearMeters) {
        unawaited(alerts.alarm());
      } else if (distance <= AppConstants.overlayWarnFarMeters) {
        unawaited(alerts.tick());
      }
    }
  }

  // --------------------------------------------------------------- 60 FPS sim

  /// Call once per rendered frame (drives the in-app gauge). Also forwards a
  /// throttled payload to the native bubble, which interpolates on its own
  /// render thread while the app is backgrounded.
  void onFrame(double dtSeconds) {
    interpolator.advance(dtSeconds);

    final VehicleState current = state.value;
    if ((current.speedKmh - interpolator.current).abs() > 0.02 && current.hasFix) {
      state.value = current.copyWith(speedKmh: interpolator.current);
    }

    unawaited(_maybePushToOverlay());
  }

  Future<void> _maybePushToOverlay({bool force = false}) async {
    if (!overlay.isRunning) return;

    final VehicleState s = state.value;
    // The vehicle state owns the driving numbers; the settings own the display
    // preferences. The native bubble needs both in one bundle.
    final Map<String, Object?> payload = <String, Object?>{
      ...s.toOverlayPayload(),
      'unit': settings.speedUnit,
      'showRemaining': settings.showRemaining,
    };

    // Only spend a platform-channel round trip when something moved.
    final String signature = '${payload['status']}|'
        '${(payload['speedKmh'] as double? ?? 0).toStringAsFixed(1)}|'
        '${payload['distanceMeters']}|${payload['limit']}|'
        '${payload['hasFix']}|${payload['isSpeeding']}';
    final DateTime now = DateTime.now();
    if (!force &&
        signature == _lastPushedSignature &&
        now.difference(_lastOverlayPush) < const Duration(seconds: 2)) {
      return;
    }
    if (!force && now.difference(_lastOverlayPush) < const Duration(milliseconds: 180)) {
      return;
    }
    _lastPushedSignature = signature;
    _lastOverlayPush = now;
    await overlay.pushState(payload);
  }

  // ------------------------------------------------------------ user actions

  /// One tap on the bubble → a live "mobile YPX" report at the current spot.
  Future<ReportResult> reportTemporaryRadar({
    int? maxSpeed,
    CameraType type = CameraType.mobile,
  }) async {
    final VehicleState s = state.value;
    if (!s.hasFix) {
      _appendLog('GPS fiksi yoxdur — radar bildirilə bilməz');
      return ReportResult.noFix();
    }

    final int limit = maxSpeed ??
        s.speedLimit ??
        settings.displaySpeed(AppConstants.defaultSpeedLimitKmh).round();

    final ReportResult result = await crowd.reportTemporaryRadar(
      latitude: s.latitude,
      longitude: s.longitude,
      maxSpeed: limit,
      headingDegrees: _heading,
      type: type,
    );

    _appendLog('Yeni radar bildirildi: $limit km/s · ${result.message}');
    await _refreshCache(force: true);
    return result;
  }

  Future<void> _refreshCache({bool force = false}) async {
    final VehicleState s = state.value;
    if (!s.hasFix) return;
    _cacheLoadedAt = DateTime.fromMillisecondsSinceEpoch(0);
    await _refreshCacheIfStale(s.latitude, s.longitude);
  }

  /// Pulls community reports from the backend.
  Future<int> refreshCommunity() async {
    final VehicleState s = state.value;
    if (!s.hasFix) return 0;
    if (!crowd.isRemoteConfigured) return 0;

    try {
      final int found = await crowd.fetchNearby(
        latitude: s.latitude,
        longitude: s.longitude,
        radiusMeters: AppConstants.radarHorizonMeters,
      );
      if (found > 0) {
        _appendLog('$found canlı radar bildirimi alındı');
        await _refreshCache(force: true);
      }
      return found;
    } catch (e) {
      if (kDebugMode) debugPrint('[RadarEngine] community refresh failed: $e');
      return 0;
    }
  }

  /// Downloads the OSM camera set around the current position.
  Future<SyncResult> syncOsmCameras({double? radiusMeters}) async {
    final VehicleState s = state.value;
    final Position? last = await locationService.lastKnown();
    final double lat = s.hasFix ? s.latitude : (last?.latitude ?? double.nan);
    final double lon = s.hasFix ? s.longitude : (last?.longitude ?? double.nan);
    if (lat.isNaN || lon.isNaN) {
      return const SyncResult(
        ok: false,
        fetched: 0,
        stored: 0,
        error: 'Konum yoxdur — GPS gözlənilir',
      );
    }

    final SyncResult result = await osmSync.syncCameras(
      latitude: lat,
      longitude: lon,
      radiusMeters: radiusMeters ?? settings.syncRadius,
      onLog: _appendLog,
    );
    _appendLog(result.message);
    if (result.ok) {
      await settings.markSynced();
      await _refreshCache(force: true);
    }
    return result;
  }

  // -------------------------------------------------------------------- log

  void _appendLog(String message) {
    final List<EngineLogEntry> next = <EngineLogEntry>[
      EngineLogEntry(message: message, at: DateTime.now()),
      ...log.value,
    ];
    if (next.length > 60) next.removeRange(60, next.length);
    log.value = List<EngineLogEntry>.unmodifiable(next);
  }

  void logExternal(String message) => _appendLog(message);

  Future<void> dispose() async {
    await stop();
    await _positionSub?.cancel();
    interpolator.dispose();
  }
}

class EngineLogEntry {
  const EngineLogEntry({required this.message, required this.at});

  final String message;
  final DateTime at;

  String get clock =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';
}
