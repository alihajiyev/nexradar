import 'dart:math' as math;

import '../constants/app_constants.dart';

/// The average-speed section the driver is inside right now.
///
/// A section camera does not measure speed at a point — it divides the distance
/// between two markers by the time you took to cover it. So the only honest thing
/// the app can show is the number that camera would compute: the average since
/// the entry marker.
///
/// Two deliberate choices make that number trustworthy:
///
/// * the **odometer** comes from [RouteCorridor]'s driven line, not from the
///   straight-line distance between two fixes. A section with a bend in it would
///   otherwise read short, and a short distance divided by the same time reads as
///   a *lower* average — the driver would be told he is fine while being fined;
/// * the **clock** starts when the entry camera is *passed*, not when it is first
///   seen. Approaching a marker is not being inside the section, and counting
///   that time would flatter the average.
class AverageSpeedSection {
  const AverageSpeedSection({
    required this.cameraKey,
    required this.limitKmh,
    required this.enteredAt,
    required this.enteredTrackMeters,
  });

  final String cameraKey;
  final int limitKmh;
  final DateTime enteredAt;
  final double enteredTrackMeters;

  /// Metres driven inside the section, never negative.
  double distanceMeters(double trackMeters) =>
      math.max(0, trackMeters - enteredTrackMeters);

  Duration elapsed(DateTime now) => now.difference(enteredAt);
}

/// A single sample of the running section average.
///
/// `averageKmh` is exactly what the camera on the far side will print.
class AverageSpeedReading {
  const AverageSpeedReading({
    required this.averageKmh,
    required this.drivenMeters,
    required this.elapsed,
    required this.limitKmh,
  });

  final double averageKmh;
  final double drivenMeters;
  final Duration elapsed;
  final int limitKmh;

  /// A 0.5 km/h cushion keeps GPS jitter from triggering a warning the driver
  /// cannot act on.
  bool get isOver => averageKmh > limitKmh + 0.5;

  double get overByKmh => math.max(0, averageKmh - limitKmh);
  double get headroomKmh => math.max(0, limitKmh - averageKmh);

  String get averageLabel => averageKmh.toStringAsFixed(0);

  String get drivenLabel => drivenMeters >= 1000
      ? '${(drivenMeters / 1000).toStringAsFixed(1)} km'
      : '${drivenMeters.round()} m';

  String get elapsedLabel {
    final int minutes = elapsed.inMinutes;
    final int seconds = elapsed.inSeconds % 60;
    return minutes > 0 ? '$minutes dəq $seconds san' : '$seconds san';
  }
}

/// Tracks the driver's progress through average-speed sections.
///
/// Deliberately has no idea where the section *ends*: OSM gives one node, and
/// inventing an exit would produce a fake "you must average X" number. So the
/// tracker reports the running average — the value the camera will use — and
/// closes the section once the driver must have left it
/// ([AppConstants.averageSectionMaxMeters]).
class AverageSpeedTracker {
  AverageSpeedSection? _active;

  AverageSpeedSection? get active => _active;
  bool get isActive => _active != null;

  /// Starts the clock. Returns true only when this actually opened a section, so
  /// the caller can log it exactly once per camera.
  bool enter({
    required String cameraKey,
    required int limitKmh,
    required DateTime at,
    required double trackMeters,
  }) {
    if (_active?.cameraKey == cameraKey) return false;
    _active = AverageSpeedSection(
      cameraKey: cameraKey,
      limitKmh: limitKmh,
      enteredAt: at,
      enteredTrackMeters: trackMeters,
    );
    return true;
  }

  void leave() => _active = null;

  /// Samples the running average.
  ///
  /// Returns null when there is not enough evidence yet — a section sampled after
  /// two seconds and five metres divides noise by noise — and also when the
  /// driver must have left the section, which closes it.
  AverageSpeedReading? sample({
    required double trackMeters,
    required DateTime now,
  }) {
    final AverageSpeedSection? section = _active;
    if (section == null) return null;

    final double driven = section.distanceMeters(trackMeters);
    if (driven > AppConstants.averageSectionMaxMeters) {
      _active = null;
      return null;
    }

    final Duration elapsed = section.elapsed(now);
    if (elapsed.inMilliseconds <
            AppConstants.averageSectionMinSeconds * 1000 ||
        driven < AppConstants.averageSectionMinMeters) {
      return null;
    }

    // m/ms × 3600 = km/h.
    final double kmh = driven / elapsed.inMilliseconds * 3600.0;
    return AverageSpeedReading(
      averageKmh: kmh,
      drivenMeters: driven,
      elapsed: elapsed,
      limitKmh: section.limitKmh,
    );
  }
}
