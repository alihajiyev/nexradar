import 'dart:math' as math;

import '../../models/speed_camera.dart';

/// All the pure geo math lives here: distance, bearing and the angular target
/// filter that weeds out oncoming traffic and perpendicular streets.
///
/// Every method is static and side-effect free, which makes the filter trivial
/// to unit test without a device or a database.
class HeadingCalculator {
  HeadingCalculator._();

  static const double earthRadiusMeters = 6371008.8;

  static double toRadians(double degrees) => degrees * math.pi / 180.0;

  static double toDegrees(double radians) => radians * 180.0 / math.pi;

  /// Normalizes any angle into [0, 360).
  static double normalizeDegrees(double degrees) {
    final double d = degrees % 360.0;
    return d < 0 ? d + 360.0 : d;
  }

  /// Great-circle distance in meters (Haversine).
  static double haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final double dLat = toRadians(lat2 - lat1);
    final double dLon = toRadians(lon2 - lon1);
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(toRadians(lat1)) *
            math.cos(toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  /// Initial bearing (forward azimuth) from point 1 to point 2, in [0, 360).
  static double bearingDegrees(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final double phi1 = toRadians(lat1);
    final double phi2 = toRadians(lat2);
    final double dLon = toRadians(lon2 - lon1);
    final double y = math.sin(dLon) * math.cos(phi2);
    final double x = math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(dLon);
    return normalizeDegrees(toDegrees(math.atan2(y, x)));
  }

  /// Smallest absolute difference between two headings, in [0, 180].
  static double angularDifference(double a, double b) {
    final double diff = (normalizeDegrees(a) - normalizeDegrees(b)).abs() % 360;
    return diff > 180 ? 360 - diff : diff;
  }

  /// True when two headings point "the same way down the road".
  static bool headingsAligned(double a, double b, double toleranceDegrees) =>
      angularDifference(a, b) <= toleranceDegrees;

  /// The core angular target filter.
  ///
  /// * [headingDegrees] — where the vehicle is heading (θ_heading).
  /// * [bearingToCamera] — the compass bearing from the vehicle to the camera.
  /// * [cameraDirection] — the direction the radar itself faces (θ_camera), may
  ///   be unknown for community reports.
  ///
  /// A camera counts as a forward threat when it is physically ahead of us
  /// **and**, if we know which way it faces, it is enforcing *our* direction of
  /// travel. That single rule removes oncoming lanes (180° off) and cross
  /// streets (90° off).
  static bool isForwardThreat({
    required double headingDegrees,
    required double bearingToCamera,
    double? cameraDirection,
    double toleranceDegrees = 45.0,
    double approachToleranceDegrees = 55.0,
  }) {
    final bool ahead =
        angularDifference(headingDegrees, bearingToCamera) <=
            approachToleranceDegrees;
    if (!ahead) return false;

    if (cameraDirection == null) return true;
    return headingsAligned(headingDegrees, cameraDirection, toleranceDegrees);
  }

  /// Convenience wrapper for a real [SpeedCamera] instance.
  static bool isCameraAForwardThreat({
    required double headingDegrees,
    required SpeedCamera camera,
    required double vehicleLatitude,
    required double vehicleLongitude,
    double toleranceDegrees = 45.0,
    double approachToleranceDegrees = 55.0,
  }) {
    final double bearing = bearingDegrees(
      vehicleLatitude,
      vehicleLongitude,
      camera.latitude,
      camera.longitude,
    );
    return isForwardThreat(
      headingDegrees: headingDegrees,
      bearingToCamera: bearing,
      cameraDirection: camera.directionBearing,
      toleranceDegrees: toleranceDegrees,
      approachToleranceDegrees: approachToleranceDegrees,
    );
  }

  /// Lat/lng bounding box used to narrow the SQL query before the precise
  /// haversine filtering happens in Dart.
  static BoundingBox boundingBox({
    required double latitude,
    required double longitude,
    required double radiusMeters,
  }) {
    final double latDelta = radiusMeters / 111320.0;
    final double cosLat = math.cos(toRadians(latitude)).abs();
    // Guard the poles so we never divide by ~0.
    final double lonDelta =
        radiusMeters / (111320.0 * (cosLat < 1e-6 ? 1e-6 : cosLat));
    return BoundingBox(
      minLat: latitude - latDelta,
      maxLat: latitude + latDelta,
      minLon: longitude - lonDelta,
      maxLon: longitude + lonDelta,
    );
  }
}

/// Plain lat/lng window used by the SQL pre-filter.
class BoundingBox {
  const BoundingBox({
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
  });

  final double minLat;
  final double maxLat;
  final double minLon;
  final double maxLon;
}
