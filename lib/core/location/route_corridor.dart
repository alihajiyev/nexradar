import 'dart:math' as math;

import '../constants/app_constants.dart';
import 'heading_calculator.dart';

/// One retained point of the driven track.
class TrackPoint {
  const TrackPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  @override
  String toString() => 'TrackPoint($latitude, $longitude)';
}

/// Answers the two questions a driver actually asks: *which way is my road
/// going?* and *is that radar on my road?*
///
/// Both come from the track the car has really driven rather than from the
/// instantaneous GPS bearing:
///
/// * **A stable course over ground.** `Position.heading` is unreliable below
///   walking pace and twitches between fixes. The bearing across the last ~60 m
///   of the driven line is a much better estimate of where the road goes, and it
///   follows gentle curves for free — so the angular filter stops flickering and
///   stops dragging radars from the next street into view.
/// * **A road corridor.** The driven track continued ahead along that course.
///   A radar far off that line is on a different road — a parallel street, the
///   far carriageway, a side road the driver will never reach — even when it
///   happens to sit inside the angular cone, which is the classic false positive
///   of a pure bearing filter.
///  /// The class is deliberately conservative: [distanceToRouteMeters] returns
  /// `null` until there is enough track to be worth trusting, and callers must
  /// then fall back to plain angular filtering. Losing a real radar is far worse
  /// than keeping an extra one.
class RouteCorridor {
  final List<TrackPoint> _track = <TrackPoint>[];

  /// Corridor segments as flat `[aLat, aLon, bLat, bLon]` quadruples, rebuilt
  /// once per fix by [prepare]. Allocating them once keeps the per-camera test
  /// down to a few subtractions.
  List<double> _segments = const <double>[];

  List<TrackPoint> get track => List<TrackPoint>.unmodifiable(_track);

  int get length => _track.length;

  bool get isEmpty => _track.isEmpty;

  void reset() {
    _track.clear();
    _segments = const <double>[];
  }

  /// Total length of the retained track, in meters.
  double get trackMeters {
    double total = 0;
    for (int i = 1; i < _track.length; i++) {
      total += HeadingCalculator.haversineMeters(
        _track[i - 1].latitude,
        _track[i - 1].longitude,
        _track[i].latitude,
        _track[i].longitude,
      );
    }
    return total;
  }

  /// Appends a fix once the car has moved [AppConstants.routeTrackSpacingMeters]
  /// away from the last retained point, then trims the oldest points so the
  /// corridor forgets a road we left a while ago.
  void addFix(double latitude, double longitude) {
    if (_track.isEmpty) {
      _track.add(TrackPoint(latitude, longitude));
      return;
    }

    final TrackPoint last = _track.last;
    final double moved = HeadingCalculator.haversineMeters(
      last.latitude,
      last.longitude,
      latitude,
      longitude,
    );
    if (moved < AppConstants.routeTrackSpacingMeters) return;

    _track.add(TrackPoint(latitude, longitude));
    while (_track.length > 2 &&
        trackMeters > AppConstants.routeTrackMaxMeters) {
      _track.removeAt(0);
    }
  }

  /// The bearing of the road under the car: from the point roughly
  /// [lookBackMeters] back along the track to the newest fix.
  ///
  /// Returns null until the track is long enough for the estimate to mean
  /// anything — the caller then keeps using its own (noisier) heading.
  double? courseDegrees({
    double lookBackMeters = AppConstants.routeCourseMinTrackMeters,
  }) {
    if (_track.length < 2) return null;

    final TrackPoint head = _track.last;
    TrackPoint anchor = _track.first;
    for (int i = _track.length - 2; i >= 0; i--) {
      anchor = _track[i];
      final double behind = HeadingCalculator.haversineMeters(
        _track[i].latitude,
        _track[i].longitude,
        head.latitude,
        head.longitude,
      );
      if (behind >= lookBackMeters) break;
    }

    final double span = HeadingCalculator.haversineMeters(
      anchor.latitude,
      anchor.longitude,
      head.latitude,
      head.longitude,
    );
    if (span < AppConstants.routeCourseMinTrackMeters) return null;

    return HeadingCalculator.bearingDegrees(
      anchor.latitude,
      anchor.longitude,
      head.latitude,
      head.longitude,
    );
  }

  /// Rebuilds the corridor for the current fix: the retained track, continued
  /// ahead of the car along [courseDegreesOfTravel] out to [forwardMeters].
  ///
  /// The continuation matters: the retained track only covers the road *behind*
  /// the car, so without it every radar ahead would look like it were off path.
  void prepare({
    required double courseDegreesOfTravel,
    double forwardMeters = AppConstants.radarHorizonMeters,
    double sampleMeters = 200,
  }) {
    if (_track.length < 2) {
      _segments = const <double>[];
      return;
    }

    final List<double> segments = <double>[];
    for (int i = 1; i < _track.length; i++) {
      segments.addAll(<double>[
        _track[i - 1].latitude,
        _track[i - 1].longitude,
        _track[i].latitude,
        _track[i].longitude,
      ]);
    }

    final TrackPoint head = _track.last;
    final int samples =
        math.max(1, (forwardMeters / math.max(50, sampleMeters)).ceil());
    double previousLat = head.latitude;
    double previousLon = head.longitude;
    for (int i = 1; i <= samples; i++) {
      final List<double> next = HeadingCalculator.destination(
        head.latitude,
        head.longitude,
        courseDegreesOfTravel,
        forwardMeters * i / samples,
      );
      segments.addAll(<double>[
        previousLat,
        previousLon,
        next[0],
        next[1],
      ]);
      previousLat = next[0];
      previousLon = next[1];
    }
    _segments = segments;
  }

  /// Distance from (lat, lon) to the corridor, or `null` when there is no
  /// corridor to measure against yet.
  ///
  /// This is the *lateral* distance for anything alongside the retained track,
  /// and the plain distance to the nearest end for anything before the start of
  /// it — which is the right answer for a radar behind the car: the corridor
  /// only means the stretch of road being driven.
  double? distanceToRouteMeters({
    required double latitude,
    required double longitude,
  }) {
    if (_segments.length < 4) return null;

    double best = double.infinity;
    for (int i = 0; i + 3 < _segments.length; i += 4) {
      final double d = HeadingCalculator.distanceToSegmentMeters(
        latitude,
        longitude,
        _segments[i],
        _segments[i + 1],
        _segments[i + 2],
        _segments[i + 3],
      );
      if (d < best) best = d;
    }
    return best;
  }

  /// True when the radar sits on the road the driver is on, or when the corridor
  /// cannot say — in which case the caller keeps the radar.
  bool isOnRoute({required double latitude, required double longitude}) {
    final double? distance = distanceToRouteMeters(
      latitude: latitude,
      longitude: longitude,
    );
    if (distance == null) return true;
    return distance <= AppConstants.routeCorridorToleranceMeters;
  }
}
