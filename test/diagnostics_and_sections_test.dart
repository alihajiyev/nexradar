import 'package:flutter_test/flutter_test.dart';
import 'package:nex_radar/core/constants/app_constants.dart';
import 'package:nex_radar/core/location/average_speed_tracker.dart';
import 'package:nex_radar/core/services/diagnostics_service.dart';
import 'package:nex_radar/core/services/tts_service.dart';

void main() {
  // ------------------------------------------------------------- flight log

  group('DiagEntry', () {
    test('parses the native line format', () {
      final DiagEntry? entry = DiagEntry.parse(
        '1759839204123|18:53:24|service|foreground started',
      );
      expect(entry, isNotNull);
      expect(entry!.name, 'service');
      expect(entry.detail, 'foreground started');
      expect(entry.at.millisecondsSinceEpoch, 1759839204123);
      expect(entry.isHeartbeat, isFalse);
    });

    test('keeps a detail that itself contains separators', () {
      final DiagEntry? entry =
          DiagEntry.parse('1759839204123|18:53:24|hb|fx 41 km/s|extra');
      expect(entry!.detail, 'fx 41 km/s|extra');
    });

    test('rejects junk instead of throwing', () {
      expect(DiagEntry.parse(''), isNull);
      expect(DiagEntry.parse('not-a-line'), isNull);
      expect(DiagEntry.parse('abc|18:53:24|hb|'), isNull);
    });
  });

  group('SessionVerdict', () {
    final DateTime now = DateTime(2026, 10, 7, 19, 0, 0);
    String line(DateTime at, String name, [String detail = '']) =>
        '${at.millisecondsSinceEpoch}|00:00:00|$name|$detail';

    test('no records at all is unknown, not a failure', () {
      final SessionVerdict verdict = summariseSession(<String>[], now: now);
      expect(verdict.kind, SessionOutcome.unknown);
      expect(verdict.isBad, isFalse);
    });

    test('a boot with no heartbeat never started the pipeline', () {
      final SessionVerdict verdict = summariseSession(
        <String>[line(now.subtract(const Duration(minutes: 5)), 'boot', 'x')],
        now: now,
      );
      expect(verdict.kind, SessionOutcome.neverStarted);
      expect(verdict.isBad, isTrue);
    });

    test('a recent heartbeat means it is alive', () {
      final SessionVerdict verdict = summariseSession(
        <String>[
          line(now.subtract(const Duration(hours: 1)), 'boot', 'x'),
          line(now.subtract(const Duration(seconds: 12)), 'hb', 'fx 20'),
        ],
        now: now,
      );
      expect(verdict.kind, SessionOutcome.alive);
      expect(verdict.isBad, isFalse);
      expect(verdict.detail, contains('12 san'));
    });

    test('a stale heartbeat reports how long the background has been down', () {
      final SessionVerdict verdict = summariseSession(
        <String>[
          line(now.subtract(const Duration(hours: 2)), 'boot', 'x'),
          line(now.subtract(const Duration(minutes: 42)), 'hb', 'fx 20'),
        ],
        now: now,
      );
      expect(verdict.kind, SessionOutcome.died);
      expect(verdict.isBad, isTrue);
      expect(verdict.detail, contains('42 dəq'));
    });

    test('a heartbeat that is merely late is not yet a death', () {
      final SessionVerdict verdict = summariseSession(
        <String>[
          line(now.subtract(const Duration(hours: 2)), 'boot', 'x'),
          line(now.subtract(const Duration(seconds: 75)), 'hb', 'fx 20'),
        ],
        now: now,
      );
      expect(verdict.kind, SessionOutcome.alive);
    });
  });

  group('describeGap', () {
    test('scales from seconds to days', () {
      expect(describeGap(const Duration(seconds: 40)), '40 san');
      expect(describeGap(const Duration(minutes: 12)), '12 dəq');
      expect(describeGap(const Duration(hours: 5)), '5 saat');
      expect(describeGap(const Duration(days: 3)), '3 gün');
    });
  });

  // -------------------------------------------------------------- native state

  group('NativeDiagnostics', () {
    Map<Object?, Object?> healthy({Object? battery, Object? bucket}) =>
        <Object?, Object?>{
          'deviceModel': 'Google Pixel 6',
          'androidSdk': 36,
          'androidRelease': '16',
          'serviceRunning': true,
          'bubbleAttached': true,
          'lockHudConnected': true,
          'lockHudAttached': true,
          'host': 'accessibility',
          'overlayGranted': true,
          'lockHudEnabled': true,
          'notificationsEnabled': true,
          'notificationPermissionGranted': true,
          'installGranted': true,
          'batteryOptimized': battery ?? false,
          'standbyBucket': bucket ?? 10,
          'fineLocationGranted': true,
          'backgroundLocationGranted': true,
          'lastHeartbeatMs': 1759839204123,
          'sessionStartedAt': 1759839000000,
        };

    test('a healthy device has no blockers and names its host', () {
      final NativeDiagnostics state =
          NativeDiagnostics.fromMap(healthy());
      expect(state.blockers, isEmpty);
      expect(state.hostLabel, 'Kilid ekranı hostu');
      expect(state.bubbleAttached, isTrue);
      expect(state.lastHeartbeatAt, isNotNull);
    });

    test('a missing location grant is the first blocker', () {
      final Map<Object?, Object?> map = healthy();
      map['fineLocationGranted'] = false;
      final NativeDiagnostics state = NativeDiagnostics.fromMap(map);
      expect(state.blockers.first.key, 'location');
    });

    test('battery optimisation and a restricted bucket are both reported', () {
      final NativeDiagnostics state = NativeDiagnostics.fromMap(
        healthy(battery: true, bucket: 45),
      );
      final List<String> keys =
          state.blockers.map((DiagBlocker b) => b.key).toList();
      expect(keys, containsAll(<String>['battery', 'bucket']));
      expect(state.isRestrictedBucket, isTrue);
      expect(state.blockers.firstWhere((DiagBlocker b) => b.key == 'bucket')
          .detail, contains('45'));
    });

    test('no overlay grant and no lock-screen grant is one blocker', () {
      final Map<Object?, Object?> map = healthy();
      map['overlayGranted'] = false;
      map['lockHudEnabled'] = false;
      map['host'] = 'none';
      final NativeDiagnostics state = NativeDiagnostics.fromMap(map);
      expect(
        state.blockers.where((DiagBlocker b) => b.key == 'overlay').length,
        1,
      );
      expect(state.hostLabel, 'Bağlıdır');
    });

    test('a missing map is not a crash', () {
      final NativeDiagnostics state = NativeDiagnostics.fromMap(<Object?, Object?>{});
      expect(state.serviceRunning, isFalse);
      expect(state.lastHeartbeatAt, isNull);
      expect(state.androidSdk, 0);
    });
  });

  // ------------------------------------------------------- average-speed zones

  group('AverageSpeedTracker', () {
    final DateTime t0 = DateTime(2026, 10, 7, 12, 0, 0);

    test('stays silent until there is real evidence', () {
      final AverageSpeedTracker tracker = AverageSpeedTracker();
      tracker.enter(
        cameraKey: 'a',
        limitKmh: 80,
        at: t0,
        trackMeters: 1000,
      );
      // Two seconds and twenty metres later: dividing noise by noise.
      expect(
        tracker.sample(
          trackMeters: 1020,
          now: t0.add(const Duration(seconds: 2)),
        ),
        isNull,
      );
      expect(tracker.isActive, isTrue);
    });

    test('reports the average the far camera will print', () {
      final AverageSpeedTracker tracker = AverageSpeedTracker();
      tracker.enter(
        cameraKey: 'a',
        limitKmh: 80,
        at: t0,
        trackMeters: 1000,
      );
      // 1000 m in 60 s is 60 km/h.
      final AverageSpeedReading? reading = tracker.sample(
        trackMeters: 2000,
        now: t0.add(const Duration(seconds: 60)),
      );
      expect(reading, isNotNull);
      expect(reading!.averageKmh, closeTo(60, 0.01));
      expect(reading.isOver, isFalse);
      expect(reading.headroomKmh, closeTo(20, 0.01));
      expect(reading.drivenLabel, '1.0 km');
      expect(reading.elapsedLabel, '1 dəq 0 san');
    });

    test('flags an average over the limit and quantifies it', () {
      final AverageSpeedTracker tracker = AverageSpeedTracker();
      tracker.enter(
        cameraKey: 'a',
        limitKmh: 80,
        at: t0,
        trackMeters: 0,
      );
      // 1000 m in 36 s is 100 km/h in an 80 zone.
      final AverageSpeedReading reading = tracker.sample(
        trackMeters: 1000,
        now: t0.add(const Duration(seconds: 36)),
      )!;
      expect(reading.averageKmh, closeTo(100, 0.01));
      expect(reading.isOver, isTrue);
      expect(reading.overByKmh, closeTo(20, 0.01));
      expect(reading.headroomKmh, 0);
    });

    test('a hair over the limit is not a warning', () {
      final AverageSpeedTracker tracker = AverageSpeedTracker();
      tracker.enter(
        cameraKey: 'a',
        limitKmh: 80,
        at: t0,
        trackMeters: 0,
      );
      // 80.2 km/h: GPS jitter, not a ticket.
      final AverageSpeedReading reading = tracker.sample(
        trackMeters: 802,
        now: t0.add(const Duration(seconds: 36)),
      )!;
      expect(reading.isOver, isFalse);
    });

    test('the clock starts at the marker, so the approach does not flatter it', () {
      final AverageSpeedTracker tracker = AverageSpeedTracker();
      tracker.enter(
        cameraKey: 'a',
        limitKmh: 80,
        at: t0,
        trackMeters: 5000,
      );
      final AverageSpeedReading? reading = tracker.sample(
        trackMeters: 5000,
        now: t0.add(const Duration(seconds: 30)),
      );
      // Standing still inside the section: not enough distance for a verdict.
      expect(reading, isNull);
      expect(tracker.isActive, isTrue);
    });

    test('closes the section once the driver must have left it', () {
      final AverageSpeedTracker tracker = AverageSpeedTracker();
      tracker.enter(
        cameraKey: 'a',
        limitKmh: 80,
        at: t0,
        trackMeters: 0,
      );
      final AverageSpeedReading? reading = tracker.sample(
        trackMeters: AppConstants.averageSectionMaxMeters + 1,
        now: t0.add(const Duration(minutes: 3)),
      );
      expect(reading, isNull);
      expect(tracker.isActive, isFalse);
    });

    test('entering twice for the same camera logs once', () {
      final AverageSpeedTracker tracker = AverageSpeedTracker();
      expect(
        tracker.enter(cameraKey: 'a', limitKmh: 80, at: t0, trackMeters: 0),
        isTrue,
      );
      expect(
        tracker.enter(
          cameraKey: 'a',
          limitKmh: 80,
          at: t0.add(const Duration(seconds: 5)),
          trackMeters: 100,
        ),
        isFalse,
      );
      expect(tracker.active!.enteredAt, t0);
    });

    test('a second section replaces the first with a fresh clock', () {
      final AverageSpeedTracker tracker = AverageSpeedTracker();
      tracker.enter(cameraKey: 'a', limitKmh: 80, at: t0, trackMeters: 0);
      tracker.enter(
        cameraKey: 'b',
        limitKmh: 100,
        at: t0.add(const Duration(minutes: 5)),
        trackMeters: 6000,
      );
      expect(tracker.active!.cameraKey, 'b');
      expect(tracker.active!.limitKmh, 100);
      expect(tracker.active!.enteredTrackMeters, 6000);
    });

    test('leave() ends the section', () {
      final AverageSpeedTracker tracker = AverageSpeedTracker();
      tracker.enter(cameraKey: 'a', limitKmh: 80, at: t0, trackMeters: 0);
      tracker.leave();
      expect(tracker.isActive, isFalse);
      expect(
        tracker.sample(trackMeters: 900, now: t0.add(const Duration(minutes: 1))),
        isNull,
      );
    });
  });

  group('PhraseBook · section average', () {
    test('names both numbers in Azerbaijani', () {
      final String phrase =
          PhraseBook.sectionAverage('az-AZ', averageKmh: 96, limitKmh: 80);
      expect(phrase, contains('96'));
      expect(phrase, contains('80'));
    });

    test('is localized, not English, for tr and ru', () {
      expect(
        PhraseBook.sectionAverage('tr-TR', averageKmh: 96, limitKmh: 80),
        contains('Ortalama'),
      );
      expect(
        PhraseBook.sectionAverage('ru-RU', averageKmh: 96, limitKmh: 80),
        contains('средняя'),
      );
    });
  });
}
