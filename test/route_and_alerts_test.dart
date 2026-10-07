import 'package:flutter_test/flutter_test.dart';
import 'package:nex_radar/core/constants/app_constants.dart';
import 'package:nex_radar/core/location/approach_ladder.dart';
import 'package:nex_radar/core/location/heading_calculator.dart';
import 'package:nex_radar/core/location/route_corridor.dart';
import 'package:nex_radar/models/speed_camera.dart';
import 'package:nex_radar/models/vehicle_state.dart';

/// Two behaviours the driver asked for by name:
///
/// * **"1 km olduğunda söylemeye başlasın, sonra 500, sonra 200"** — and never
///   "0 metres to the radar" for something that appeared next to the car.
/// * **"hangi yola gittiğimi anlamalı ve radarları ona göre dizmeli"** — the
///   course comes from the road actually driven, and a radar on another street
///   is not a radar on my route.
void main() {
  // Baku, Fountain Square — the reference point the rest of the suite uses.
  const double lat = 40.3720;
  const double lon = 49.8360;

  /// One hundred meters of latitude, near enough.
  const double lat100m = 100 / 111320.0;

  /// Meters east → degrees of longitude at this latitude.
  double lonForMeters(double meters) => meters / (111320.0 * 0.76157);

  group('ApproachLadder · 1 km → 500 m → 200 m', () {
    test('a radar first seen right next to the car is never announced', () {
      // The old bug: first sighting fired the far gate immediately, so a report
      // that popped up 30 m away was spoken as "radar 0 metres away".
      expect(ApproachLadder.crossedGate(previous: null, distance: 30), isNull);
      expect(ApproachLadder.crossedGate(previous: null, distance: 0), isNull);
      expect(ApproachLadder.crossedGate(previous: null, distance: 900), isNull);
    });

    test('each gate fires once, on the fix that crosses it', () {
      expect(ApproachLadder.crossedGate(previous: 1200, distance: 900), 1000);
      expect(ApproachLadder.crossedGate(previous: 700, distance: 450), 500);
      expect(ApproachLadder.crossedGate(previous: 300, distance: 190), 200);
    });

    test('a gate that was already passed stays silent', () {
      expect(ApproachLadder.crossedGate(previous: 150, distance: 140), isNull);
      expect(ApproachLadder.crossedGate(previous: 250, distance: 210), isNull);
      expect(ApproachLadder.crossedGate(previous: 900, distance: 800), isNull);
    });

    test('driving away from a radar never announces anything', () {
      expect(ApproachLadder.crossedGate(previous: 180, distance: 260), isNull);
      expect(ApproachLadder.crossedGate(previous: 480, distance: 900), isNull);
    });

    test('a GPS gap announces only the most urgent gate it skipped', () {
      // 900 m → 50 m in one step crosses all three. Three sentences back to back
      // would still be talking when the car reaches the radar.
      expect(ApproachLadder.crossedGate(previous: 900, distance: 50), 200);
    });

    test('only the 200 m gate earns the urgent wording', () {
      expect(ApproachLadder.isUrgent(200), isTrue);
      expect(ApproachLadder.isUrgent(500), isFalse);
      expect(ApproachLadder.isUrgent(1000), isFalse);
    });

    test('the ladder runs far to near', () {
      expect(AppConstants.approachGatesMeters, <double>[1000, 500, 200]);
    });
  });

  group('VehicleState · status gates', () {
    VehicleState stateWith({
      required double speed,
      double? distance,
      int limit = 60,
    }) {
      return VehicleState(
        speedKmh: speed,
        rawSpeedKmh: speed,
        headingDegrees: 0,
        latitude: lat,
        longitude: lon,
        accuracyMeters: 5,
        timestamp: DateTime.now(),
        threat: distance == null
            ? null
            : SpeedCamera(
                latitude: lat + lat100m,
                longitude: lon,
                maxSpeed: limit,
                updatedAt: DateTime.now(),
                distanceMeters: distance,
              ),
        threatDistanceMeters: distance,
      );
    }

    test('the bubble turns amber at 1 km', () {
      expect(stateWith(speed: 60, distance: 920).status, DrivingStatus.approaching);
      expect(stateWith(speed: 60, distance: 1000).status, DrivingStatus.approaching);
    });

    test('beyond 1 km the bubble stays idle', () {
      expect(stateWith(speed: 60, distance: 1200).status, DrivingStatus.idle);
    });

    test('the red flasher waits for 200 m', () {
      expect(stateWith(speed: 60, distance: 400).status, DrivingStatus.approaching);
      expect(stateWith(speed: 60, distance: 180).status, DrivingStatus.warning);
    });
  });

  group('RouteCorridor · which road am I on', () {
    /// A corridor built from 300 m of driving due north.
    RouteCorridor droveNorth() {
      final RouteCorridor corridor = RouteCorridor();
      for (int i = 0; i <= 3; i++) {
        corridor.addFix(lat + lat100m * i, lon);
      }
      corridor.prepare(courseDegreesOfTravel: 0);
      return corridor;
    }

    test('the course comes from the driven line, not a single fix', () {
      final RouteCorridor corridor = droveNorth();
      expect(corridor.courseDegrees(), closeTo(0, 1));
    });

    test('a short track is not trusted yet', () {
      final RouteCorridor corridor = RouteCorridor();
      corridor.addFix(lat, lon);
      expect(corridor.courseDegrees(), isNull);
      expect(
        corridor.distanceToRouteMeters(latitude: lat, longitude: lon),
        isNull,
      );
      // No opinion means "keep the radar" — losing a real one is worse.
      expect(
        corridor.isOnRoute(latitude: lat + lat100m * 20, longitude: lon),
        isTrue,
      );
    });

    test('a radar straight down my own road stays', () {
      final RouteCorridor corridor = droveNorth();
      // 2 km ahead on the same line.
      final double ahead = lat + lat100m * 20;
      expect(corridor.isOnRoute(latitude: ahead, longitude: lon), isTrue);
      expect(
        corridor.distanceToRouteMeters(latitude: ahead, longitude: lon),
        lessThan(5),
      );
    });

    test('a radar on a parallel street is dropped', () {
      final RouteCorridor corridor = droveNorth();
      final double ahead = lat + lat100m * 20;
      final double beside = lon + lonForMeters(400);
      expect(corridor.isOnRoute(latitude: ahead, longitude: beside), isFalse);
      expect(
        corridor.distanceToRouteMeters(latitude: ahead, longitude: beside),
        greaterThan(300),
      );
    });

    test('a radar just off the carriageway is kept', () {
      final RouteCorridor corridor = droveNorth();
      // 100 m to the side: a wide junction or a GPS wobble, not another road.
      expect(
        corridor.isOnRoute(
          latitude: lat + lat100m * 10,
          longitude: lon + lonForMeters(100),
        ),
        isTrue,
      );
    });

    test('a radar well behind the car is not on the route', () {
      final RouteCorridor corridor = droveNorth();
      // 700 m back: the retained track starts 300 m behind the car.
      expect(
        corridor.distanceToRouteMeters(
          latitude: lat - lat100m * 3,
          longitude: lon,
        ),
        greaterThan(150),
      );
    });

    test('the track stays bounded', () {
      final RouteCorridor corridor = RouteCorridor();
      for (int i = 0; i < 400; i++) {
        corridor.addFix(lat + lat100m * i, lon);
      }
      expect(
        corridor.trackMeters,
        lessThanOrEqualTo(AppConstants.routeTrackMaxMeters + 200),
      );
    });
  });

  group('HeadingCalculator · segment geometry', () {
    test('perpendicular distance to a segment', () {
      // Segment from (0,0) to (0,0.001) is ~111 m of longitude at the equator.
      expect(
        HeadingCalculator.distanceToSegmentMeters(0.0005, 0.0005, 0, 0, 0, 0.001),
        closeTo(55.6, 1),
      );
      // Beyond the end the distance clamps to the nearest endpoint.
      expect(
        HeadingCalculator.distanceToSegmentMeters(0, 0.002, 0, 0, 0, 0.001),
        closeTo(111.3, 1),
      );
    });

    test('destination walks a known bearing', () {
      final List<double> north = HeadingCalculator.destination(lat, lon, 0, 1000);
      expect(
        HeadingCalculator.haversineMeters(lat, lon, north[0], north[1]),
        closeTo(1000, 1),
      );
      expect(north[0], greaterThan(lat));
      expect(north[1], closeTo(lon, 0.00001));
    });
  });
}
