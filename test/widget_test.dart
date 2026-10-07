import 'package:flutter_test/flutter_test.dart';
import 'package:nex_radar/core/constants/camera_types.dart';
import 'package:nex_radar/core/location/heading_calculator.dart';
import 'package:nex_radar/core/location/speed_interpolator.dart';
import 'package:nex_radar/core/services/osm_sync_service.dart';
import 'package:nex_radar/core/services/tts_service.dart';
import 'package:nex_radar/models/speed_camera.dart';
import 'package:nex_radar/models/vehicle_state.dart';

void main() {
  // Baku, Fountain Square — a convenient reference point.
  const double lat = 40.3720;
  const double lon = 49.8360;

  group('HeadingCalculator · Haversine', () {
    test('one degree of latitude is ~111 km', () {
      final double d = HeadingCalculator.haversineMeters(0, 0, 1, 0);
      expect(d, closeTo(111195, 200));
    });

    test('identical points are zero apart', () {
      expect(HeadingCalculator.haversineMeters(lat, lon, lat, lon), 0);
    });

    test('a point 1 km north reads ~1000 m', () {
      final double north = lat + 1000 / 111320.0;
      expect(
        HeadingCalculator.haversineMeters(lat, lon, north, lon),
        closeTo(1000, 5),
      );
    });
  });

  group('HeadingCalculator · bearing', () {
    test('north / east / south / west', () {
      expect(
        HeadingCalculator.bearingDegrees(0, 0, 1, 0),
        closeTo(0, 0.5),
      );
      expect(
        HeadingCalculator.bearingDegrees(0, 0, 0, 1),
        closeTo(90, 0.5),
      );
      expect(
        HeadingCalculator.bearingDegrees(1, 0, 0, 0),
        closeTo(180, 0.5),
      );
      expect(
        HeadingCalculator.bearingDegrees(0, 1, 0, 0),
        closeTo(270, 0.5),
      );
    });

    test('angular difference wraps around 0°/360°', () {
      expect(HeadingCalculator.angularDifference(350, 10), closeTo(20, 0.001));
      expect(HeadingCalculator.angularDifference(10, 350), closeTo(20, 0.001));
      expect(HeadingCalculator.angularDifference(0, 180), closeTo(180, 0.001));
    });
  });

  group('Angular target filter (|θ_heading − θ_camera| ≤ 45°)', () {
    test('a camera straight ahead is a threat', () {
      expect(
        HeadingCalculator.isForwardThreat(
          headingDegrees: 90,
          bearingToCamera: 88,
          cameraDirection: 92,
        ),
        isTrue,
      );
    });

    test('the oncoming lane is filtered out', () {
      expect(
        HeadingCalculator.isForwardThreat(
          headingDegrees: 90,
          bearingToCamera: 270,
          cameraDirection: 270,
        ),
        isFalse,
      );
    });

    test('a perpendicular street is filtered out', () {
      expect(
        HeadingCalculator.isForwardThreat(
          headingDegrees: 0,
          bearingToCamera: 90,
          cameraDirection: 90,
        ),
        isFalse,
      );
    });

    test('a camera enforcing the other direction is dropped', () {
      expect(
        HeadingCalculator.isForwardThreat(
          headingDegrees: 0,
          bearingToCamera: 5,
          cameraDirection: 185,
        ),
        isFalse,
      );
    });

    test('an unknown camera direction only needs the approach check', () {
      expect(
        HeadingCalculator.isForwardThreat(
          headingDegrees: 120,
          bearingToCamera: 130,
        ),
        isTrue,
      );
      expect(
        HeadingCalculator.isForwardThreat(
          headingDegrees: 120,
          bearingToCamera: 220,
        ),
        isFalse,
      );
    });

    test('the tolerance is configurable', () {
      expect(
        HeadingCalculator.isForwardThreat(
          headingDegrees: 0,
          bearingToCamera: 40,
          cameraDirection: 40,
          toleranceDegrees: 20,
        ),
        isFalse,
      );
      expect(
        HeadingCalculator.isForwardThreat(
          headingDegrees: 0,
          bearingToCamera: 40,
          cameraDirection: 40,
          toleranceDegrees: 60,
        ),
        isTrue,
      );
    });
  });

  group('SpeedInterpolator · 1 Hz GPS → 60 FPS needle', () {
    test('converges on the target and clamps to it', () {
      final SpeedInterpolator interp = SpeedInterpolator(tauSeconds: 0.4);
      interp.setTarget(72);
      for (int i = 0; i < 240; i++) {
        interp.advance(1 / 60);
      }
      expect(interp.current, closeTo(72, 0.1));
      expect(interp.isSettled, isTrue);
    });

    test('is frame-rate independent', () {
      final SpeedInterpolator a = SpeedInterpolator(tauSeconds: 0.4);
      final SpeedInterpolator b = SpeedInterpolator(tauSeconds: 0.4);
      a.snapTo(0);
      b.snapTo(0);
      a.setTarget(100);
      b.setTarget(100);
      for (int i = 0; i < 30; i++) {
        a.advance(1 / 60); // 60 Hz
      }
      for (int i = 0; i < 15; i++) {
        b.advance(1 / 30); // 30 Hz
      }
      expect(a.current, closeTo(b.current, 0.05));
    });

    test('never exceeds the clamp even on a nonsense fix', () {
      final SpeedInterpolator interp = SpeedInterpolator();
      interp.setTarget(9999);
      interp.advance(0.016);
      expect(interp.target, lessThanOrEqualTo(320));
    });

    test('standstill jitter is flattened to zero', () {
      final SpeedInterpolator interp = SpeedInterpolator();
      interp.snapTo(1.2);
      interp.setTarget(1.4);
      interp.advance(0.2);
      expect(interp.current, 0);
    });
  });

  group('VehicleState · alert ladder', () {
    SpeedCamera camera({int limit = 80, double? distance = 450}) => SpeedCamera(
          latitude: lat,
          longitude: lon,
          maxSpeed: limit,
          directionBearing: 90,
          updatedAt: DateTime.now(),
          distanceMeters: distance,
        );

    VehicleState stateWith({
      required double speed,
      double? distance,
      int limit = 80,
    }) =>
        VehicleState(
          speedKmh: speed,
          rawSpeedKmh: speed,
          headingDegrees: 90,
          latitude: lat,
          longitude: lon,
          accuracyMeters: 5,
          timestamp: DateTime.now(),
          threat: distance == null ? null : camera(limit: limit, distance: distance),
          threatDistanceMeters: distance,
        );

    test('idle when nothing is nearby', () {
      expect(stateWith(speed: 60).status, DrivingStatus.idle);
    });

    test('approaching inside 500 m', () {
      expect(
        stateWith(speed: 60, distance: 420).status,
        DrivingStatus.approaching,
      );
    });

    test('warning inside 200 m', () {
      expect(
        stateWith(speed: 60, distance: 180).status,
        DrivingStatus.warning,
      );
    });

    test('speeding promotes a far camera to warning', () {
      final VehicleState state = stateWith(speed: 95, distance: 700);
      expect(state.isSpeeding, isTrue);
      expect(state.status, DrivingStatus.warning);
      expect(state.overspeedKmh, closeTo(15, 0.01));
    });

    test('GPS noise around the limit is tolerated', () {
      expect(stateWith(speed: 81, distance: 300).isSpeeding, isFalse);
    });

    test('eta is derived from the smoothed speed', () {
      // 400 m at 72 km/h (20 m/s) → 20 s.
      expect(stateWith(speed: 72, distance: 400).etaSeconds, 20);
    });

    test('overlay payload mirrors the state', () {
      final Map<String, Object?> payload =
          stateWith(speed: 95, distance: 180).toOverlayPayload();
      expect(payload['status'], 'warning');
      expect(payload['limit'], 80);
      expect(payload['distanceMeters'], 180);
      expect(payload['isSpeeding'], true);
    });
  });

  group('OSM tag parsing', () {
    test('plain km/h', () {
      expect(OsmSyncService.parseMaxSpeed('80'), 80);
      expect(OsmSyncService.parseMaxSpeed('80 km/h'), 80);
    });

    test('mph is converted', () {
      expect(OsmSyncService.parseMaxSpeed('30 mph'), 48);
    });

    test('named zones fall back to sensible values', () {
      expect(OsmSyncService.parseMaxSpeed('AZ:urban'), 60);
      expect(OsmSyncService.parseMaxSpeed('walk'), 10);
    });

    test('junk and outliers are rejected', () {
      expect(OsmSyncService.parseMaxSpeed('none'), isNull);
      expect(OsmSyncService.parseMaxSpeed('999'), isNull);
      expect(OsmSyncService.parseMaxSpeed(null), isNull);
    });

    test('direction accepts degrees and compass points', () {
      expect(OsmSyncService.parseDirection('270'), 270);
      expect(OsmSyncService.parseDirection('north'), 0);
      expect(OsmSyncService.parseDirection('SE'), 135);
      expect(OsmSyncService.parseDirection('nonsense'), isNull);
    });

    test('camera type mapping', () {
      expect(
        OsmSyncService.parseCameraType(<String, String>{'speed_camera': 'mobile'}),
        CameraType.mobile,
      );
      expect(
        OsmSyncService.parseCameraType(
          <String, String>{'enforcement': 'average_speed'},
        ),
        CameraType.averageSpeed,
      );
      expect(
        OsmSyncService.parseCameraType(
          <String, String>{'highway': 'traffic_signals'},
        ),
        CameraType.redLight,
      );
      expect(
        OsmSyncService.parseCameraType(<String, String>{}),
        CameraType.fixed,
      );
    });
  });

  group('SpeedCamera · persistence round trip', () {
    test('survives toMap → fromMap', () {
      final SpeedCamera original = SpeedCamera(
        id: 7,
        latitude: lat,
        longitude: lon,
        maxSpeed: 90,
        directionBearing: 45,
        type: CameraType.mobile,
        isTemporary: true,
        source: SpeedCamera.sourceCommunity,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(1900000000000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1800000000000),
      );
      final SpeedCamera restored = SpeedCamera.fromMap(original.toMap(includeId: true));

      expect(restored.id, 7);
      expect(restored.latitude, lat);
      expect(restored.maxSpeed, 90);
      expect(restored.directionBearing, 45);
      expect(restored.type, CameraType.mobile);
      expect(restored.isTemporary, isTrue);
      expect(restored.expiresAt!.millisecondsSinceEpoch, 1900000000000);
    });

    test('identity ignores the row id but keeps position and type', () {
      final SpeedCamera a = SpeedCamera(
        latitude: lat,
        longitude: lon,
        maxSpeed: 60,
        updatedAt: DateTime.now(),
      );
      final SpeedCamera b = a.copyWith(id: 42);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('expiry is detected', () {
      final SpeedCamera expired = SpeedCamera(
        latitude: lat,
        longitude: lon,
        maxSpeed: 60,
        isTemporary: true,
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        updatedAt: DateTime.now(),
      );
      expect(expired.isExpired, isTrue);
    });
  });

  group('PhraseBook · Azerbaijani announcements', () {
    test('mentions the limit and the distance', () {
      final String phrase = PhraseBook.cameraAhead('az-AZ', limitKmh: 80, distanceMeters: 400);
      expect(phrase, contains('80'));
      expect(phrase, contains('400'));
      expect(phrase.toLowerCase(), contains('radar'));
    });

    test('the slow-down line is localized', () {
      expect(
        PhraseBook.slowDown('tr-TR', distanceMeters: 150),
        contains('Yavaşlayın'),
      );
      expect(
        PhraseBook.slowDown('az-AZ', distanceMeters: 150),
        contains('Yavaşlayın'),
      );
      expect(
        PhraseBook.slowDown('en-US', distanceMeters: 150),
        contains('Slow down'),
      );
    });

    test('distances are rounded to a speakable bucket', () {
      // 137 m → 140 m, 438 m → 450 m, 1240 m → 1200 m.
      expect(PhraseBook.slowDown('en-US', distanceMeters: 137), contains('140'));
      expect(PhraseBook.slowDown('en-US', distanceMeters: 438), contains('450'));
      expect(PhraseBook.slowDown('en-US', distanceMeters: 1240), contains('1200'));
    });
  });
}
