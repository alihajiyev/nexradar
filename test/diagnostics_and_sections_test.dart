import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nex_radar/core/constants/app_constants.dart';
import 'package:nex_radar/core/location/average_speed_tracker.dart';
import 'package:nex_radar/core/services/diagnostics_service.dart';
import 'package:nex_radar/core/services/overlay_service.dart';
import 'package:nex_radar/core/services/settings_service.dart';
import 'package:nex_radar/core/services/warning_silence.dart';
import 'package:nex_radar/core/services/drive_report.dart';
import 'package:nex_radar/core/services/update_service.dart';
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
          'mediaPanelActive': true,
          'keyguardLocked': false,
          'screenOn': true,
          'warningsSilenced': false,
          'silenceUntilMs': 0,
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
      expect(state.mediaPanelActive, isFalse);
      expect(state.silenceUntilAt, isNull);
    });

    test('the lock screen is described from what the system reports', () {
      expect(
        NativeDiagnostics.fromMap(healthy()).lockScreenLabel,
        'Kilid açıq · panel hazırdır',
      );

      final Map<Object?, Object?> locked = healthy();
      locked['keyguardLocked'] = true;
      expect(
        NativeDiagnostics.fromMap(locked).lockScreenLabel,
        'Kilid bağlı · panel kiliddədir',
      );

      // No panel while locked is the one combination the driver must be told
      // about: the keyguard hides every overlay window, so nothing is on screen.
      final Map<Object?, Object?> blind = healthy();
      blind['keyguardLocked'] = true;
      blind['mediaPanelActive'] = false;
      expect(
        NativeDiagnostics.fromMap(blind).lockScreenLabel,
        'Kilid bağlı · panel yoxdur',
      );

      final Map<Object?, Object?> off = healthy();
      off['screenOn'] = false;
      expect(NativeDiagnostics.fromMap(off).lockScreenLabel, 'Ekran bağlıdır');
    });

    test('the silence window comes back off the wire with its deadline', () {
      final Map<Object?, Object?> map = healthy();
      map['warningsSilenced'] = true;
      map['silenceUntilMs'] = 1759839500000;
      final NativeDiagnostics state = NativeDiagnostics.fromMap(map);
      expect(state.nativeSilenced, isTrue);
      expect(state.silenceUntilAt, isNotNull);
      expect(
        state.silenceUntilAt!.millisecondsSinceEpoch,
        1759839500000,
      );
    });
  });

  // ------------------------------------------------------------ silence window

  group('WarningSilence · bounded by design', () {
    final DateTime t0 = DateTime(2026, 10, 9, 18, 0, 0);

    test('off means the warnings are live', () {
      expect(WarningSilence.off.isActive, isFalse);
      expect(WarningSilence.off.remainingSeconds(t0), 0);
      expect(WarningSilence.off.isExpired(t0), isFalse);
      expect(WarningSilence.off.endsAtMillis(t0), 0);
      expect(WarningSilence.off.normalised(t0), WarningSilence.off);
      expect(WarningSilence.off.countdownLabel(t0), '0:00');
    });

    test('counts down and prints the label the panel shows', () {
      final WarningSilence silence = WarningSilence.startingAt(t0);
      expect(silence.isActive, isTrue);
      expect(silence.remainingSeconds(t0), WarningSilence.window.inSeconds);
      expect(silence.countdownLabel(t0), '5:00');
      expect(
        silence.countdownLabel(t0.add(const Duration(seconds: 48))),
        '4:12',
      );
    });

    test('expires exactly at the end of the window, and clamps at zero', () {
      final WarningSilence silence = WarningSilence.startingAt(t0);
      final DateTime end = t0.add(WarningSilence.window);
      expect(
        silence.isExpired(end.subtract(const Duration(milliseconds: 1))),
        isFalse,
      );
      expect(silence.isExpired(end), isTrue);
      expect(silence.remainingSeconds(end.add(const Duration(hours: 2))), 0);
      expect(silence.countdownLabel(end), '0:00');
      expect(silence.normalised(end), WarningSilence.off);
    });

    test('a clock that jumps backwards cannot stretch the window', () {
      final DateTime future = t0.add(const Duration(days: 1));
      final WarningSilence silence = WarningSilence.startingAt(future);
      expect(
        silence.remainingSeconds(t0),
        WarningSilence.window.inSeconds,
        reason: 'the remaining time is clamped to the window itself',
      );
      expect(silence.isActive, isTrue,
          reason: 'it is still a pause, just a young one');
    });

    test('endsAtMillis is the deadline the native panel counts down from', () {
      expect(
        WarningSilence.startingAt(t0).endsAtMillis(t0),
        t0.add(WarningSilence.window).millisecondsSinceEpoch,
      );
      expect(WarningSilence.off.endsAtMillis(t0), 0);
    });
  });

  group('SettingsService · the silence survives a restart', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('a live window is restored, an expired one is dropped', () async {
      final SettingsService settings = SettingsService.instance;
      await settings.load();
      expect(settings.warningsPaused, isFalse);

      await settings.setWarningSilence(WarningSilence.startingAt(DateTime.now()));
      expect(settings.warningsPaused, isTrue);

      // Same storage, fresh process: the window is still open.
      await settings.load();
      expect(settings.warningsPaused, isTrue,
          reason: 'a restart must not silently un-mute the radar');

      // A window that ran out while the app was closed is not restored: this is
      // what stops a forgotten pause from covering a whole trip.
      SharedPreferences.setMockInitialValues(<String, Object>{
        AppConstants.prefWarningsPaused: true,
        AppConstants.prefWarningsPausedAt: DateTime.now()
            .subtract(WarningSilence.window * 2)
            .millisecondsSinceEpoch,
      });
      await settings.load();
      expect(settings.warningsPaused, isFalse);

      // And closing the window by hand clears the stored deadline too.
      await settings.setWarningSilence(WarningSilence.startingAt(DateTime.now()));
      await settings.setWarningSilence(WarningSilence.off);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppConstants.prefWarningsPaused), isFalse);
      expect(prefs.getInt(AppConstants.prefWarningsPausedAt), isNull);
    });
  });

  // --------------------------------------------------- lock-screen panel events

  group('OverlayEvent · lock-screen buttons', () {
    test('the media panel buttons arrive as intents', () {
      expect(
        OverlayEvent.fromMap(<Object?, Object?>{'type': 'pauseWarnings'})
            .isSilenceRequest,
        isTrue,
      );
      expect(
        OverlayEvent.fromMap(<Object?, Object?>{'type': 'resumeWarnings'})
            .isResumeRequest,
        isTrue,
      );
      expect(
        OverlayEvent.fromMap(<Object?, Object?>{'type': 'toggleVoice'})
            .isVoiceToggle,
        isTrue,
      );
      expect(
        OverlayEvent.fromMap(<Object?, Object?>{'type': 'addRadar'})
            .isReportRequest,
        isTrue,
      );
    });

    test('an ordinary bubble tap is not mistaken for a button', () {
      final OverlayEvent tap =
          OverlayEvent.fromMap(<Object?, Object?>{'type': 'tapped'});
      expect(tap.isSilenceRequest, isFalse);
      expect(tap.isResumeRequest, isFalse);
      expect(tap.isVoiceToggle, isFalse);
      expect(tap.isReportRequest, isFalse);
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

  // ------------------------------------------------------------ silent updates

  group('silent update routing', () {
    test('no Shizuku at all keeps the system installer', () {
      const ShizukuState state = ShizukuState();
      expect(state.usable, isFalse);
      expect(state.needsGrant, isFalse);
      expect(chooseInstallRoute(state), InstallRoute.installer);
    });

    test('Shizuku without the grant still uses the system installer', () {
      const ShizukuState state = ShizukuState(available: true);
      expect(state.needsGrant, isTrue);
      expect(
        chooseInstallRoute(state),
        InstallRoute.installer,
        reason: 'an optimistic silent install would fail with an error instead '
            'of the dialog the driver expects',
      );
    });

    test('granted Shizuku installs silently', () {
      const ShizukuState state =
          ShizukuState(available: true, granted: true);
      expect(state.usable, isTrue);
      expect(chooseInstallRoute(state), InstallRoute.silent);
    });

    test('a grant without a running service is not enough', () {
      const ShizukuState state = ShizukuState(granted: true);
      expect(state.usable, isFalse);
      expect(chooseInstallRoute(state), InstallRoute.installer);
    });
  });

  // -------------------------------------------------------------- drive report

  group('DriveReport', () {
    final DateTime start = DateTime(2026, 10, 7, 8, 0, 0);

    DriveReport build({
      double meters = 10000,
      Duration drive = const Duration(minutes: 10),
      double maxSpeed = 96,
      int overLimit = 0,
      int announcements = 3,
      int passed = 2,
    }) =>
        DriveReport(
          startedAt: start,
          endedAt: start.add(drive),
          distanceMeters: meters,
          maxSpeedKmh: maxSpeed,
          overLimitSeconds: overLimit,
          announcements: announcements,
          radarsPassed: passed,
          camerasSeen: 12,
        );

    test('an untouched engine reports nothing', () {
      final DriveReport report = DriveReport.empty();
      expect(report.isEmpty, isTrue);
      expect(report.elapsed, Duration.zero);
      expect(report.averageSpeedKmh, 0);
      expect(report.verdict, 'Hələ sürüş qeydə alınmayıb');
    });

    test('average speed is distance over time, like the camera computes it', () {
      // 10 km in 10 minutes is 60 km/h.
      expect(build().averageSpeedKmh, closeTo(60, 0.01));
      expect(build().averageSpeedLabel, '60');
      expect(build().distanceLabel, '10.0 km');
      expect(build().durationLabel, '10 dəq 0 san');
    });

    test('a clean drive says so', () {
      final DriveReport report = build();
      expect(report.overLimitShare, 0);
      expect(report.verdict, contains('Təmiz sürüş'));
      expect(report.timeline, contains('Keçilən radar: 2'));
      expect(report.timeline.any((String l) => l.startsWith('Limit üstü')),
          isFalse);
    });

    test('a brief overshoot is reported without alarm', () {
      // 30 s over the limit out of 10 minutes is 5%. 29 s is under the 5% line.
      final DriveReport report = build(overLimit: 20);
      expect(report.overLimitShare, closeTo(0.033, 0.005));
      expect(report.verdict, contains('Yaxşı sürüş'));
      expect(report.verdict, contains('20 san'));
    });

    test('a long overshoot is quantified, not scolded', () {
      final DriveReport report = build(overLimit: 180);
      expect(report.overLimitShare, closeTo(0.3, 0.01));
      expect(report.verdict, contains('3 dəq 0 san'));
      expect(report.verdict, contains('30%'));
      expect(report.overLimitLabel, '3 dəq 0 san');
    });

    test('a drive that never moved says so instead of averaging zero', () {
      final DriveReport report = build(meters: 20);
      expect(report.isMoving, isFalse);
      expect(report.verdict, contains('hərəkət yoxdur'));
    });

    test('an open drive keeps counting from the start', () {
      final DriveReport report = DriveReport(
        startedAt: DateTime.now().subtract(const Duration(minutes: 2)),
        endedAt: null,
        distanceMeters: 1500,
        maxSpeedKmh: 70,
        overLimitSeconds: 0,
        announcements: 1,
        radarsPassed: 1,
        camerasSeen: 5,
      );
      expect(report.elapsed.inMinutes, 2);
      expect(report.distanceLabel, '1.5 km');
    });

    test('a clock that runs backwards cannot produce a negative drive', () {
      final DriveReport report = DriveReport(
        startedAt: start,
        endedAt: start.subtract(const Duration(minutes: 5)),
        distanceMeters: 500,
        maxSpeedKmh: 40,
        overLimitSeconds: 0,
        announcements: 0,
        radarsPassed: 0,
        camerasSeen: 0,
      );
      expect(report.elapsed, Duration.zero);
      expect(report.averageSpeedKmh, 0);
    });
  });
}
