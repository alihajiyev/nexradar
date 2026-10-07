import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart side of the health report.
///
/// Two responsibilities, deliberately kept in one small class:
///
/// * **[Diag] events** — the Dart half of the flight recorder. Every line the
///   radar pipeline writes here lands in the same file the Kotlin foreground
///   service writes to, so a support report reads as one timeline: "app started
///   18:41 → bubble shown 18:41 → first fix 18:41 → 1 km gate 18:52 → no
///   heartbeat after 19:04".
/// * **[DiagnosticsSnapshot]** — the native health report, plus the numbers the
///   engine already knows.
///
/// Nothing in here is allowed to throw into the pipeline: a diagnostics call
/// that fails must never stop a radar alert. Every platform call is wrapped.
class Diag {
  Diag._();

  /// Overridable so tests can inject a mock messenger.
  @visibleForTesting
  static const MethodChannel channel = MethodChannel('nexradar/diagnostics');

  static bool _enabled = true;

  /// Turns recording off, for tests that assert on an exact log.
  @visibleForTesting
  static set enabled(bool value) => _enabled = value;

  /// Records one event. Fire-and-forget: the caller never awaits it.
  static void event(String name, [String? detail]) {
    if (!_enabled) return;
    final Map<String, Object?> args = <String, Object?>{'name': name};
    if (detail != null) args['detail'] = detail;
    unawaited(
      channel.invokeMethod<void>('log', args).catchError((Object _) {}),
    );
  }

  /// "Still alive" marker written while the pipeline runs, with no UI attached.
  static void heartbeat(String detail) {
    if (!_enabled) return;
    unawaited(
      channel
          .invokeMethod<void>('heartbeat', <String, Object?>{'detail': detail})
          .catchError((Object _) {}),
    );
  }

  static Future<List<String>> read() async {
    try {
      final List<Object?>? lines =
          await channel.invokeMethod<List<Object?>>('read');
      return (lines ?? const <Object?>[])
          .map((Object? l) => l.toString())
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  static Future<void> clear() async {
    try {
      await channel.invokeMethod<void>('clear');
    } catch (_) {}
  }

  static Future<NativeDiagnostics?> nativeState() async {
    try {
      final Map<Object?, Object?>? raw =
          await channel.invokeMethod<Map<Object?, Object?>>('state');
      if (raw == null) return null;
      return NativeDiagnostics.fromMap(Map<Object?, Object?>.from(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> openBatterySettings() async {
    try {
      await channel.invokeMethod<void>('openBatterySettings');
    } catch (_) {}
  }

  static Future<void> openNotificationSettings() async {
    try {
      await channel.invokeMethod<void>('openNotificationSettings');
    } catch (_) {}
  }
}

/// One line of the flight recorder.
///
/// The native side writes `epochMillis|HH:mm:ss|name|detail`; parsing lives here
/// so both the diagnostics screen and the tests agree on the shape.
@immutable
class DiagEntry {
  const DiagEntry({
    required this.at,
    required this.name,
    required this.detail,
  });

  final DateTime at;
  final String name;
  final String detail;

  bool get isHeartbeat => name == 'hb';
  bool get isBoot => name == 'boot';

  static DiagEntry? parse(String line) {
    final List<String> parts = line.split('|');
    if (parts.length < 3) return null;
    final int? stamp = int.tryParse(parts[0]);
    if (stamp == null) return null;
    return DiagEntry(
      at: DateTime.fromMillisecondsSinceEpoch(stamp),
      name: parts[2],
      detail: parts.length > 3 ? parts.sublist(3).join('|') : '',
    );
  }

  String get clock =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';

  @override
  String toString() => '$clock $name $detail'.trim();
}

/// What the native process reports about itself.
@immutable
class NativeDiagnostics {
  const NativeDiagnostics({
    required this.deviceModel,
    required this.androidSdk,
    required this.androidRelease,
    required this.serviceRunning,
    required this.bubbleAttached,
    required this.lockHudConnected,
    required this.lockHudAttached,
    required this.host,
    required this.overlayGranted,
    required this.lockHudEnabled,
    required this.notificationsEnabled,
    required this.batteryOptimized,
    required this.standbyBucket,
    required this.fineLocationGranted,
    required this.backgroundLocationGranted,
    required this.notificationPermissionGranted,
    required this.installGranted,
    required this.lastHeartbeatAt,
    required this.sessionStartedAt,
  });

  final String deviceModel;
  final int androidSdk;
  final String androidRelease;

  /// Is `RadarOverlayService` alive? This is the process that keeps GPS running.
  final bool serviceRunning;

  /// Is *a* bubble on screen right now, and who is drawing it?
  final bool bubbleAttached;
  final String host;

  final bool lockHudConnected;
  final bool lockHudAttached;
  final bool lockHudEnabled;
  final bool overlayGranted;

  final bool notificationsEnabled;
  final bool notificationPermissionGranted;
  final bool installGranted;
  final bool batteryOptimized;

  /// Doze standby bucket, or -1 when unknown. 45 (`NEVER`) and 5 (`RESTRICTED`)
  /// are the two values that mean "Android has forbidden background work".
  final int standbyBucket;

  final bool fineLocationGranted;
  final bool backgroundLocationGranted;

  /// Written by whichever layer ticked last; a stale value is the fingerprint of
  /// a killed pipeline.
  final DateTime? lastHeartbeatAt;
  final DateTime? sessionStartedAt;

  bool get isRestrictedBucket => standbyBucket == 45 || standbyBucket == 5;

  /// Whole list of the things that silently break the background, in the order
  /// they matter.
  List<DiagBlocker> get blockers => <DiagBlocker>[
        if (!fineLocationGranted)
          const DiagBlocker(
            key: 'location',
            title: 'Konum icazəsi yoxdur',
            detail: 'GPS olmadan radar hesablanmır.',
          ),
        if (!overlayGranted && !lockHudEnabled)
          const DiagBlocker(
            key: 'overlay',
            title: 'Üzərdə göstərmə icazəsi yoxdur',
            detail: '"Digər tətbiqlərin üzərində göstər" verilməlidir.',
          ),
        if (!notificationsEnabled || !notificationPermissionGranted)
          const DiagBlocker(
            key: 'notifications',
            title: 'Bildirişlər söndürülüb',
            detail: 'Servis görünməz olur və sistem onu daha asan öldürür.',
          ),
        if (batteryOptimized)
          const DiagBlocker(
            key: 'battery',
            title: 'Batareya optimallaşdırması aktiv',
            detail: 'Telefon arxa fonu dayandıra bilər.',
          ),
        if (isRestrictedBucket)
          DiagBlocker(
            key: 'bucket',
            title: 'Tətbiq məhdud rejimdədir',
            detail: 'Sistem arxa fon işini qadağan edib '
                '(bucket $standbyBucket).',
          ),
        if (fineLocationGranted && !backgroundLocationGranted)
          const DiagBlocker(
            key: 'background-location',
            title: 'Arxa fon konum icazəsi yoxdur',
            detail: 'Ekran bağlıykən GPS dəqiq işləməyə bilər.',
          ),
      ];

  static NativeDiagnostics fromMap(Map<Object?, Object?> map) {
    DateTime? time(Object? raw) {
      final int? ms = (raw as num?)?.toInt();
      if (ms == null || ms <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }

    return NativeDiagnostics(
      deviceModel: (map['deviceModel'] as String?) ?? '—',
      androidSdk: (map['androidSdk'] as num?)?.toInt() ?? 0,
      androidRelease: (map['androidRelease'] as String?) ?? '—',
      serviceRunning: map['serviceRunning'] == true,
      bubbleAttached: map['bubbleAttached'] == true,
      lockHudConnected: map['lockHudConnected'] == true,
      lockHudAttached: map['lockHudAttached'] == true,
      host: (map['host'] as String?) ?? 'none',
      overlayGranted: map['overlayGranted'] == true,
      lockHudEnabled: map['lockHudEnabled'] == true,
      notificationsEnabled: map['notificationsEnabled'] == true,
      installGranted: map['installGranted'] == true,
      batteryOptimized: map['batteryOptimized'] == true,
      standbyBucket: (map['standbyBucket'] as num?)?.toInt() ?? -1,
      fineLocationGranted: map['fineLocationGranted'] == true,
      backgroundLocationGranted: map['backgroundLocationGranted'] == true,
      notificationPermissionGranted:
          map['notificationPermissionGranted'] == true,
      lastHeartbeatAt: time(map['lastHeartbeatMs']),
      sessionStartedAt: time(map['sessionStartedAt']),
    );
  }

  /// The host name as the driver should read it.
  String get hostLabel {
    switch (host) {
      case 'accessibility':
        return 'Kilid ekranı hostu';
      case 'overlay':
        return 'Üzərdə pəncərə';
      default:
        return 'Bağlıdır';
    }
  }
}

@immutable
class DiagBlocker {
  const DiagBlocker({
    required this.key,
    required this.title,
    required this.detail,
  });

  final String key;
  final String title;
  final String detail;
}

/// The complete picture the diagnostics screen renders: one native heartbeat
/// plus everything the Dart engine can answer about itself.
@immutable
class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.native,
    required this.engineRunning,
    required this.lastFixAt,
    required this.lastFixAge,
    required this.trackMeters,
    required this.camerasInCache,
    required this.camerasInRange,
    required this.forwardThreats,
    required this.filteredOffRoute,
    required this.lastAnnouncement,
    required this.announcements,
    required this.sessionStarted,
    required this.log,
  });

  final NativeDiagnostics? native;

  final bool engineRunning;
  final DateTime? lastFixAt;
  final Duration? lastFixAge;

  /// How much of the road the corridor has actually seen.
  final double trackMeters;

  final int camerasInCache;
  final int camerasInRange;
  final int forwardThreats;
  final int filteredOffRoute;

  final AnnouncementRecord? lastAnnouncement;
  final int announcements;

  final DateTime? sessionStarted;
  final List<DiagEntry> log;

  /// A fix older than this while the engine says it is running is the signature
  /// of a GPS stream that has been cut — the exact failure the driver reports as
  /// "it stopped working".
  static const Duration staleFix = Duration(seconds: 45);

  bool get fixIsStale {
    if (!engineRunning) return false;
    final Duration? age = lastFixAge;
    return age == null || age > staleFix;
  }

  /// The one-line verdict shown at the top of the screen.
  String get verdict {
    if (native == null) return 'Native tərəf cavab vermir';
    if (!engineRunning) return 'Mühərrik dayanıb — sürüş başlamayıb';
    if (native!.blockers.isNotEmpty) {
      return '${native!.blockers.length} maneə arxa fonu poza bilər';
    }
    if (fixIsStale) return 'Konum axını kəsilib';
    return 'Hər şey işləyir';
  }

  static DiagnosticsSnapshot unknown() => const DiagnosticsSnapshot(
        native: null,
        engineRunning: false,
        lastFixAt: null,
        lastFixAge: null,
        trackMeters: 0,
        camerasInCache: 0,
        camerasInRange: 0,
        forwardThreats: 0,
        filteredOffRoute: 0,
        lastAnnouncement: null,
        announcements: 0,
        sessionStarted: null,
        log: <DiagEntry>[],
      );
}

/// One announcement, kept so the driver (and support) can see the ladder working
/// with real numbers instead of trusting it.
@immutable
class AnnouncementRecord {
  const AnnouncementRecord({
    required this.at,
    required this.text,
    required this.distanceMeters,
  });

  final DateTime at;
  final String text;
  final double distanceMeters;

  String get clock =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';

  /// `18:52:04 · 1000 m`
  String get summary => '$clock · ${distanceMeters.round()} m';
}

/// Formats a gap between two moments the way a driver reads it.
String describeGap(Duration gap) {
  if (gap.inSeconds < 60) return '${gap.inSeconds} san';
  if (gap.inMinutes < 60) return '${gap.inMinutes} dəq';
  if (gap.inHours < 24) return '${gap.inHours} saat';
  return '${gap.inDays} gün';
}

/// Reads a flight-recorder file and answers the only question that matters after
/// a silent failure: did the pipeline keep ticking, or did it stop — and when?
///
/// Pure function, so the whole "why did it die" story is unit-testable.
SessionVerdict summariseSession(List<String> rawLines, {DateTime? now}) {
  final DateTime at = now ?? DateTime.now();
  final List<DiagEntry> entries = rawLines
      .map(DiagEntry.parse)
      .whereType<DiagEntry>()
      .toList(growable: false);

  if (entries.isEmpty) {
    return const SessionVerdict(
      kind: SessionOutcome.unknown,
      detail: 'Qeyd yoxdur',
    );
  }

  final List<DiagEntry> heartbeats =
      entries.where((DiagEntry e) => e.isHeartbeat).toList(growable: false);
  final DiagEntry boot = entries.lastWhere(
    (DiagEntry e) => e.isBoot,
    orElse: () => entries.first,
  );

  if (heartbeats.isEmpty) {
    return SessionVerdict(
      kind: SessionOutcome.neverStarted,
      at: boot.at,
      detail: 'Mühərrik heç vaxt işə düşməyib',
    );
  }

  final DiagEntry last = heartbeats.last;
  final Duration gap = at.difference(last.at);

  // Two missed heartbeats in a row is the point where "slow" becomes "dead".
  if (gap > const Duration(seconds: 90)) {
    return SessionVerdict(
      kind: SessionOutcome.died,
      at: last.at,
      detail: 'Arxa fon ${describeGap(gap)} əvvəl kəsildi',
      lastHeartbeatAt: last.at,
      gap: gap,
    );
  }

  return SessionVerdict(
    kind: SessionOutcome.alive,
    at: last.at,
    detail: '${describeGap(gap)} əvvəl işləyirdi',
    lastHeartbeatAt: last.at,
    gap: gap,
  );
}

enum SessionOutcome { alive, died, neverStarted, unknown }

@immutable
class SessionVerdict {
  const SessionVerdict({
    required this.kind,
    required this.detail,
    this.at,
    this.lastHeartbeatAt,
    this.gap,
  });

  final SessionOutcome kind;
  final String detail;
  final DateTime? at;
  final DateTime? lastHeartbeatAt;
  final Duration? gap;

  bool get isBad =>
      kind == SessionOutcome.died || kind == SessionOutcome.neverStarted;
}
