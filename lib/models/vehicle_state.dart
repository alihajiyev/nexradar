import '../core/constants/app_constants.dart';
import 'speed_camera.dart';

/// The three visual states the floating bubble can be in.
enum DrivingStatus {
  /// No threat nearby — the bubble shows the speed only.
  idle,

  /// 1 km → 200 m from a confirmed forward threat: amber, blinking limit.
  approaching,

  /// Inside 200 m, or over the posted limit: red flasher + alarm.
  warning;

  bool get isThreat => this != DrivingStatus.idle;
}

/// The complete, immutable snapshot of "what the driver needs to know right
/// now". Everything (bubble, gauge, TTS, logs) renders from this one object.
class VehicleState {
  const VehicleState({
    required this.speedKmh,
    required this.rawSpeedKmh,
    required this.headingDegrees,
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.timestamp,
    this.threat,
    this.threatDistanceMeters,
    this.threatBearingDegrees,
    this.hasFix = true,
    this.camerasInRange = 0,
  });

  /// Smoothed value actually painted on the needle (60 FPS interpolation of the
  /// 1 Hz GPS chip).
  final double speedKmh;

  /// The last value the GPS chip reported, unmodified.
  final double rawSpeedKmh;

  final double headingDegrees;
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime timestamp;

  /// Nearest camera that survived the angular filter, if any.
  final SpeedCamera? threat;
  final double? threatDistanceMeters;
  final double? threatBearingDegrees;

  final bool hasFix;

  /// How many raw cameras were inside the horizon (before the angle filter) —
  /// handy for the debug pane.
  final int camerasInRange;

  static VehicleState empty() => VehicleState(
        speedKmh: 0,
        rawSpeedKmh: 0,
        headingDegrees: 0,
        latitude: 0,
        longitude: 0,
        accuracyMeters: 0,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        hasFix: false,
      );

  bool get isStale =>
      DateTime.now().difference(timestamp) > AppConstants.gpsStaleAfter;

  int? get speedLimit => threat?.maxSpeed;

  bool get isSpeeding {
    final int? limit = speedLimit;
    if (limit == null || limit <= 0) return false;
    return speedKmh > limit + 1.5; // 1.5 km/h tolerance for GPS noise
  }

  double get overspeedKmh {
    final int? limit = speedLimit;
    if (limit == null) return 0;
    final double over = speedKmh - limit;
    return over > 0 ? over : 0;
  }

  DrivingStatus get status {
    final double? d = threatDistanceMeters;
    if (threat == null || d == null) return DrivingStatus.idle;
    if (d <= AppConstants.gateNearMeters || isSpeeding) {
      return DrivingStatus.warning;
    }
    if (d <= AppConstants.gateFarMeters) {
      return DrivingStatus.approaching;
    }
    return DrivingStatus.idle;
  }

  /// Seconds until we reach the threat, using the current (smoothed) speed.
  int? get etaSeconds {
    final double? d = threatDistanceMeters;
    if (d == null) return null;
    final double ms = speedKmh / 3.6;
    if (ms < 1.0) return null;
    return (d / ms).round();
  }

  VehicleState copyWith({
    double? speedKmh,
    double? rawSpeedKmh,
    double? headingDegrees,
    double? latitude,
    double? longitude,
    double? accuracyMeters,
    DateTime? timestamp,
    SpeedCamera? threat,
    bool clearThreat = false,
    double? threatDistanceMeters,
    double? threatBearingDegrees,
    bool? hasFix,
    int? camerasInRange,
  }) {
    return VehicleState(
      speedKmh: speedKmh ?? this.speedKmh,
      rawSpeedKmh: rawSpeedKmh ?? this.rawSpeedKmh,
      headingDegrees: headingDegrees ?? this.headingDegrees,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      accuracyMeters: accuracyMeters ?? this.accuracyMeters,
      timestamp: timestamp ?? this.timestamp,
      threat: clearThreat ? null : (threat ?? this.threat),
      threatDistanceMeters:
          clearThreat ? null : (threatDistanceMeters ?? this.threatDistanceMeters),
      threatBearingDegrees:
          clearThreat ? null : (threatBearingDegrees ?? this.threatBearingDegrees),
      hasFix: hasFix ?? this.hasFix,
      camerasInRange: camerasInRange ?? this.camerasInRange,
    );
  }

  /// Where the nearest radar sits relative to the car's nose: 0° = straight
  /// ahead, +90° = to the right, -90° = to the left.
  double? get threatRelativeBearing {
    final double? bearing = threatBearingDegrees;
    if (bearing == null) return null;
    double delta = (bearing - headingDegrees) % 360;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    return delta;
  }

  /// Compact payload pushed to the native overlay and the lock-screen card.
  Map<String, Object?> toOverlayPayload() => <String, Object?>{
        'speedKmh': speedKmh,
        'limit': speedLimit ?? AppConstants.unknownLimit,
        'status': status.name,
        'distanceMeters': threatDistanceMeters?.round() ?? -1,
        'cameraType': threat?.type.wire,
        'isTemporary': threat?.isTemporary ?? false,
        'isSpeeding': isSpeeding,
        'etaSeconds': etaSeconds ?? -1,
        'bearingDelta': threatRelativeBearing?.round() ?? -999,
        'hasFix': hasFix,
      };

  @override
  String toString() =>
      'VehicleState(${speedKmh.toStringAsFixed(1)} km/h, hdg '
      '${headingDegrees.toStringAsFixed(0)}°, ${status.name}, '
      'threat=${threatDistanceMeters?.toStringAsFixed(0) ?? '-'} m)';
}
