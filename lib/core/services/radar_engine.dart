import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/speed_camera.dart';
import '../../models/vehicle_state.dart';
import '../constants/app_constants.dart';
import '../constants/camera_types.dart';
import '../database/camera_repository.dart';
import '../location/approach_ladder.dart';
import '../location/average_speed_tracker.dart';
import '../location/heading_calculator.dart';
import '../location/location_service.dart';
import '../location/route_corridor.dart';
import '../location/speed_interpolator.dart';
import 'alert_service.dart';
import 'crowdsourced_radar_service.dart';
import 'diagnostics_service.dart';
import 'drive_report.dart';
import 'osm_sync_service.dart';
import 'overlay_service.dart';
import 'settings_service.dart';
import 'tts_service.dart';

/// The brain of NexRadar.
///
/// Pipeline, once per GPS fix (≈1 Hz):
///
/// ```
/// GPS ─▶ driven track (corridor) ─▶ stable course over ground
///       └─▶ local cache (5 km, SQLite + haversine)
///            └─▶ angular target filter  |θ_heading − θ_camera| ≤ 45°
///                 └─▶ on-my-road filter  (corridor ≤ 150 m)
///                      └─▶ nearest forward threat
///                           ├─▶ VehicleState (status / limit / remaining)
///                           ├─▶ native overlay payload
///                           ├─▶ TTS ladder   1 km → 500 m → 200 m
///                           └─▶ beep ladder  500 m → 200 m / speeding
/// ```
///
/// [tick] advances the interpolation so the needle glides instead of stepping and
/// forwards the smoothed value to the floating bubble. It is driven both by the
/// dashboard's frame ticker *and* by the engine's own pump, so the bubble keeps
/// moving with no UI attached — which is the normal state of affairs in a car.
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

  /// The road the driver is actually on: a stable course plus the "is that
  /// radar on my road" test. See [RouteCorridor].
  final RouteCorridor corridor = RouteCorridor();

  /// Average-speed sections, measured from the moment the entry marker is
  /// passed. See [AverageSpeedTracker].
  final AverageSpeedTracker averageSpeed = AverageSpeedTracker();

  StreamSubscription<Position>? _positionSub;
  Timer? _communityTimer;
  Timer? _pump;

  /// Wall clock of the last [tick], so the interpolation step is the real
  /// elapsed time no matter who drove it.
  DateTime _lastTickAt = DateTime.now();

  /// How fast the engine pumps itself when no UI is attached. Ten times the GPS
  /// cadence is far more than the exponential filter needs, and cheap enough to
  /// leave running while the screen is off.
  static const Duration pumpInterval = Duration(milliseconds: 100);

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

  // -------------------------------------------------------------- diagnostics
  //
  // Deliberately plain fields rather than notifiers: the diagnostics screen
  // polls, and nothing else renders them. They exist so a driver who reports
  // "it stopped working" can be answered with numbers instead of a guess.

  DateTime? _lastFixAt;
  DateTime? _sessionStarted;
  DateTime _lastRecordedHeartbeat = DateTime.fromMillisecondsSinceEpoch(0);
  AnnouncementRecord? _lastAnnouncement;
  int _announcements = 0;
  int _camerasInRange = 0;
  int _forwardThreatCount = 0;
  int _filteredOffRoute = 0;

  AverageSpeedReading? _averageReading;
  DateTime _lastSectionWarnAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ------------------------------------------------------------ session totals
  //
  // Kept for the whole drive, not for the last frame: these are the numbers that
  // answer "was I alright?" after a trip, and they keep counting while the app
  // is closed, because the pipeline does.
  double _odometerMeters = 0;
  double _maxSpeedKmh = 0;
  int _overLimitSeconds = 0;
  final Set<String> _passedRadarKeys = <String>{};
  DateTime _lastFixWallAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _sessionEndedAt;

  /// The drive so far — or the drive that just ended, until the next one starts.
  DriveReport get report => DriveReport(
        startedAt: _sessionStarted,
        endedAt: _sessionEndedAt,
        distanceMeters: _odometerMeters,
        maxSpeedKmh: _maxSpeedKmh,
        overLimitSeconds: _overLimitSeconds,
        announcements: _announcements,
        radarsPassed: _passedRadarKeys.length,
        camerasSeen: _camerasInRange,
      );

  /// The running average of the section the driver is inside, or null when he is
  /// not inside one (or when there is not enough of it behind him yet).
  AverageSpeedReading? get averageReading => _averageReading;

  /// How often the pipeline proves to the flight recorder that it is alive.
  static const Duration heartbeatInterval = Duration(seconds: 30);

  DateTime? get lastFixAt => _lastFixAt;
  DateTime? get sessionStarted => _sessionStarted;
  AnnouncementRecord? get lastAnnouncement => _lastAnnouncement;
  int get announcements => _announcements;
  int get camerasInRange => _camerasInRange;
  int get forwardThreatCount => _forwardThreatCount;
  int get filteredOffRoute => _filteredOffRoute;

  DateTime _lastOverlayPush = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastPushedSignature = '';

  int get cameraCacheSize => _cache.length;
  double get heading => _heading;

  // ---------------------------------------------------------------- lifecycle

  Future<void> start({bool background = true}) async {
    if (_running) return;
    _running = true;
    _sessionStarted = DateTime.now();
    _sessionEndedAt = null;
    _odometerMeters = 0;
    _maxSpeedKmh = 0;
    _overLimitSeconds = 0;
    _passedRadarKeys.clear();
    _appendLog('Mühərrik işə salındı');
    Diag.event('engine', 'started (background: $background)');

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

    // The engine's own clock. The dashboard's ticker calls [tick] too, but with
    // the task swiped away there is no ticker at all — and the bubble would then
    // keep chasing a smoothed speed that never moved.
    _lastTickAt = DateTime.now();
    _pump?.cancel();
    _pump = Timer.periodic(pumpInterval, (_) => tick());

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
    _pump?.cancel();
    _pump = null;
    corridor.reset();
    averageSpeed.leave();
    _averageReading = null;
    _sessionEndedAt = DateTime.now();
    await tts.stop();
    await alerts.stopAll();
    await overlay.hide();
    _appendLog('Mühərrik dayandırıldı');
    Diag.event('engine', 'stopped after $_announcements announcements');
  }

  // -------------------------------------------------------------- GPS intake

  Future<void> _onPosition(Position p) async {
    if (!_running) return;

    // A fix with no speed at all is useless for a speedometer; keep the last
    // known one but do not treat it as a new sample.
    final double kmh = LocationService.kmh(p);
    corridor.addFix(p.latitude, p.longitude);
    _heading = _computeHeading(p);
    // The corridor must be extended before any radar is measured against it.
    corridor.prepare(courseDegreesOfTravel: _heading);
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

    final DateTime fixWall = DateTime.now();
    final Duration sinceLastFix = _lastFixWallAt.millisecondsSinceEpoch == 0
        ? Duration.zero
        : fixWall.difference(_lastFixWallAt);
    _lastFixWallAt = fixWall;
    _lastFixAt = fixWall;
    _camerasInRange = _cache.length;

    // Session totals. A gap longer than a minute is a tunnel or a lost signal,
    // not time spent speeding, so it is excluded from the over-limit total.
    if (_previous != null) {
      final double moved = HeadingCalculator.haversineMeters(
        _previous!.latitude,
        _previous!.longitude,
        p.latitude,
        p.longitude,
      );
      // Ignore GPS jumps: a fix that moved further than any car could.
      if (moved < 1500) _odometerMeters += moved;
    }
    if (kmh > _maxSpeedKmh) _maxSpeedKmh = kmh;
    if (state.value.isSpeeding &&
        sinceLastFix.inSeconds <= 60 &&
        sinceLastFix.inSeconds > 0) {
      _overLimitSeconds += sinceLastFix.inSeconds;
    }
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
    _updateAverageSection();
    await _maybePushToOverlay(force: true);
  }

  /// Where the car is *going*, not merely which way the nose is pointing.
  ///
  /// Preference order:
  ///
  /// 1. **the driven line** — the bearing across the last ~60 m of road the car
  ///    actually travelled. Stable through a curve and through a traffic jam,
  ///    which is what stops radars from the next street from drifting into the
  ///    cone every time the GPS heading twitches.
  /// 2. the GPS `heading` field, but only while genuinely moving.
  /// 3. the bearing between the last two fixes.
  ///
  /// The last two are low-passed so the angular filter never jumps at the
  /// 0°/360° seam.
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

    final double? road = corridor.courseDegrees();
    if (road != null) return road;

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
    }
  }

  /// Applies the angular target filter and the on-my-road filter; result is
  /// sorted by distance.
  ///
  /// The angular test alone still lets through cameras that are inside the cone
  /// but on a different road — a parallel street, a side road 200 m ahead, the
  /// far carriageway of an interchange. The corridor removes those, but only
  /// when it is confident: with no track yet it answers "keep it".
  List<SpeedCamera> _forwardThreats({
    required double latitude,
    required double longitude,
    required double heading,
  }) {
    final List<SpeedCamera> out = <SpeedCamera>[];
    _filteredOffRoute = 0;
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
      if (!ahead) continue;
      if (!corridor.isOnRoute(latitude: c.latitude, longitude: c.longitude)) {
        _filteredOffRoute += 1;
        continue;
      }
      out.add(c);
    }
    out.sort((SpeedCamera a, SpeedCamera b) =>
        (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity));
    _forwardThreatCount = out.length;
    return out;
  }

  // ----------------------------------------------------------- alert ladder

  /// The alert ladder: 1 km, 500 m, 200 m.
  ///
  /// A gate is announced when it is **crossed**, never when it is merely
  /// satisfied, and a radar that is already inside a gate the first time we see
  /// it is recorded in silence. Both rules exist to kill the same complaint: a
  /// community report popping up next to the car used to trigger "radar 0 metres
  /// away", which tells the driver nothing he can act on.
  void _evaluateAlerts(VehicleState s) {
    final SpeedCamera? camera = s.threat;
    final double? distance = s.threatDistanceMeters;
    if (camera == null || distance == null) return;

    final double? previous = _lastDistance[camera.identityKey];
    _lastDistance[camera.identityKey] = distance;

    // First sighting: whatever gates it already sits inside were passed before
    // we knew it existed. Record the distance and stay quiet.
    if (previous == null) return;

    final bool closing = distance < previous;
    final double? crossed =
        ApproachLadder.crossedGate(previous: previous, distance: distance);

    // An average-speed marker starts a section when it goes *behind* the car,
    // not when it appears ahead: the clock must not include the approach.
    // Passed = it is now behind us. Counted once per camera, so a radar the
    // driver drives past twice in one trip is one radar.
    if (!closing) _passedRadarKeys.add(camera.identityKey);

    if (camera.type == CameraType.averageSpeed && !closing) {
      final bool opened = averageSpeed.enter(
        cameraKey: camera.identityKey,
        limitKmh: camera.maxSpeed,
        at: DateTime.now(),
        trackMeters: corridor.trackMeters,
      );
      if (opened) {
        _appendLog('Orta sürət bölməsi başladı · hədd ${camera.maxSpeed}');
        Diag.event('section', 'entered · limit ${camera.maxSpeed}');
      }
    }

    // --- voice ladder --------------------------------------------------------
    if (crossed != null && settings.voiceEnabled) {
      _appendLog('${camera.type.wire} radar ${distance.round()} m '
          '— hədd ${camera.maxSpeed}');
      final String text = camera.isTemporary
          ? 'Topluluk radarı, hədd $camera.maxSpeed'
          : '$camera.type.labelTr radar, hədd $camera.maxSpeed';

      _lastAnnouncement = AnnouncementRecord(
        at: DateTime.now(),
        text: text,
        distanceMeters: crossed,
      );
      _announcements += 1;
      // The flight recorder gets the *gate*, not the current distance: that is
      // the whole claim of the ladder, and it is what a support report verifies.
      Diag.event(
        'announce',
        '${crossed.round()} m · ${camera.type.wire} · '
            'limit ${camera.maxSpeed} · fx ${distance.round()} m',
      );
      if (ApproachLadder.isUrgent(crossed)) {
        unawaited(
          tts.announceSlowDown(
            distanceMeters: distance.round(),
            limitKmh: camera.maxSpeed,
          ),
        );
      } else {
        unawaited(
          camera.isTemporary
              ? tts.announceCommunityReport(limitKmh: camera.maxSpeed)
              : tts.announceCameraAhead(
                  limitKmh: camera.maxSpeed,
                  distanceMeters: distance.round(),
                ),
        );
      }
    }

    // --- audible/kinetic ladder ---------------------------------------------
    if (settings.beepEnabled && closing) {
      if (s.isSpeeding && distance <= AppConstants.gateMidMeters) {
        unawaited(alerts.alarm());
        if (settings.voiceEnabled && s.speedKmh > camera.maxSpeed + 12) {
          unawaited(
            tts.announceSpeeding(
              speedKmh: s.speedKmh.round(),
              limitKmh: camera.maxSpeed,
            ),
          );
        }
      } else if (distance <= AppConstants.gateNearMeters) {
        unawaited(alerts.alarm());
      } else if (ApproachLadder.isBeepGate(distance)) {
        unawaited(alerts.tick());
      }
    }
  }

  /// Samples the running section average and warns when it goes over the limit.
  ///
  /// The warning is rate-limited by [AppConstants.averageSectionWarnCooldown]
  /// because an average is a slow number: it stays over the limit for minutes,
  /// and repeating the sentence would be noise rather than help.
  void _updateAverageSection() {
    _averageReading = averageSpeed.sample(
      trackMeters: corridor.trackMeters,
      now: DateTime.now(),
    );

    final AverageSpeedReading? reading = _averageReading;
    if (reading == null || !reading.isOver) return;
    if (!settings.voiceEnabled) return;

    final DateTime now = DateTime.now();
    if (now.difference(_lastSectionWarnAt) <
        AppConstants.averageSectionWarnCooldown) {
      return;
    }
    _lastSectionWarnAt = now;
    Diag.event(
      'section',
      'average ${reading.averageLabel} km/s over limit ${reading.limitKmh} '
          '· ${reading.drivenLabel} · ${reading.elapsedLabel}',
    );
    unawaited(
      tts.announceSectionAverage(
        averageKmh: reading.averageKmh.round(),
        limitKmh: reading.limitKmh,
      ),
    );
  }

  // --------------------------------------------------------------- 60 FPS sim

  /// Advances everything that is time-based: the needle interpolation and the
  /// throttled push to the native bubble.
  ///
  /// Safe to call from several places — the dashboard's frame ticker and the
  /// engine's own [pumpInterval] timer both do — because the step is derived
  /// from the real elapsed time since the previous call, so the filter can never
  /// be double-advanced. That is what lets the bubble keep moving with no UI
  /// attached at all.
  void tick() {
    if (!_running) return;

    final DateTime now = DateTime.now();
    final double dt = now.difference(_lastTickAt).inMicroseconds / 1000000.0;
    if (dt <= 0) return;
    _lastTickAt = now;

    // Prove to the flight recorder that the pipeline is alive even when nobody
    // is looking at the screen. A missing heartbeat is how a dead background is
    // detected on the next launch.
    if (now.difference(_lastRecordedHeartbeat) >= heartbeatInterval) {
      _lastRecordedHeartbeat = now;
      Diag.heartbeat(
        'fx ${state.value.speedKmh.round()} km/s · radar ${_cache.length} · '
        'yol ${corridor.trackMeters.round()} m',
      );
    }

    interpolator.advance(dt);

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
