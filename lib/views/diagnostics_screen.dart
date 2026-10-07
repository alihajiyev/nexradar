import 'dart:async';

import 'package:flutter/material.dart';

import 'package:nex_radar/main.dart';

import '../core/services/diagnostics_service.dart';
import '../ui/theme/app_theme.dart';
import '../ui/widgets/app_header.dart';
import '../ui/widgets/controls.dart';
import '../ui/widgets/setting_tiles.dart';
import '../ui/widgets/surfaces.dart';

/// The health screen.
///
/// NexRadar's whole value depends on something the driver can never see: a
/// foreground service that must stay alive after the app is closed, behind a
/// lock screen, through an OEM battery manager. When that silently stops — and
/// on some ROMs it will — "the app is broken" is the only feedback a driver can
/// give.
///
/// This screen turns that into a list of answerable questions: is the service
/// alive, which host is drawing the bubble, how old is the last GPS fix, how
/// long ago did the pipeline last prove it was alive, and what exactly did it
/// announce on the way here.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  /// Live values refresh every second; the log is heavier, so it lags.
  static const Duration _liveInterval = Duration(seconds: 1);
  static const Duration _logInterval = Duration(seconds: 5);

  Timer? _liveTimer;
  Timer? _logTimer;

  NativeDiagnostics? _native;
  List<DiagEntry> _entries = const <DiagEntry>[];

  /// The raw file, kept so the session verdict reads the exact bytes the native
  /// side wrote instead of a re-serialised copy.
  List<String> _raw = const <String>[];
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshLive());
    unawaited(_refreshLog());
    _liveTimer = Timer.periodic(_liveInterval, (_) => unawaited(_refreshLive()));
    _logTimer = Timer.periodic(_logInterval, (_) => unawaited(_refreshLog()));
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _logTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshLive() async {
    final NativeDiagnostics? next = await Diag.nativeState();
    if (!mounted) return;
    setState(() => _native = next);
  }

  Future<void> _refreshLog() async {
    final List<String> raw = await Diag.read();
    final List<DiagEntry> next = raw
        .map(DiagEntry.parse)
        .whereType<DiagEntry>()
        .toList(growable: false);
    if (!mounted) return;
    setState(() {
      _raw = raw;
      _entries = next;
    });
  }

  DiagnosticsSnapshot get _snapshot {
    final RadarEngineRef engine = RadarEngineRef(widget.services);
    final DateTime now = DateTime.now();
    return DiagnosticsSnapshot(
      native: _native,
      engineRunning: engine.isRunning,
      lastFixAt: engine.lastFixAt,
      lastFixAge: engine.lastFixAt == null
          ? null
          : now.difference(engine.lastFixAt!),
      trackMeters: engine.trackMeters,
      camerasInCache: engine.camerasInCache,
      camerasInRange: engine.camerasInRange,
      forwardThreats: engine.forwardThreats,
      filteredOffRoute: engine.filteredOffRoute,
      lastAnnouncement: engine.lastAnnouncement,
      announcements: engine.announcements,
      sessionStarted: engine.sessionStarted,
      log: _entries,
    );
  }

  @override
  Widget build(BuildContext context) {
    final DiagnosticsSnapshot snapshot = _snapshot;
    final SessionVerdict verdict = summariseSession(_raw, now: DateTime.now());

    return Scaffold(
      backgroundColor: NexColors.background,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          NexSpace.page,
          0,
          NexSpace.page,
          NexSpace.xxl,
        ),
        children: <Widget>[
          NexHeader(
            title: 'Diaqnostika',
            subtitle: snapshot.native == null
                ? 'Native tərəf gözlənilir'
                : '${snapshot.native!.deviceModel} · Android '
                    '${snapshot.native!.androidRelease} '
                    '(API ${snapshot.native!.androidSdk})',
            leading: _BackButton(onTap: () => Navigator.of(context).maybePop()),
            actions: <Widget>[
              NexIconButton(
                icon: Icons.refresh_rounded,
                onPressed: () {
                  unawaited(_refreshLive());
                  unawaited(_refreshLog());
                },
              ),
            ],
          ),
          _VerdictCard(snapshot: snapshot, verdict: verdict),
          const SizedBox(height: NexSpace.sm),
          _LiveCard(snapshot: snapshot),
          const SizedBox(height: NexSpace.sm),
          _BackgroundCard(snapshot: snapshot),
          const SizedBox(height: NexSpace.sm),
          if (snapshot.native != null && snapshot.native!.blockers.isNotEmpty)
            _BlockersCard(
              blockers: snapshot.native!.blockers,
              onFix: _fix,
            ),
          _LogCard(
            entries: _entries,
            clearing: _clearing,
            onClear: _clear,
          ),
        ],
      ),
    );
  }

  Future<void> _clear() async {
    setState(() => _clearing = true);
    await Diag.clear();
    await _refreshLog();
    if (mounted) setState(() => _clearing = false);
  }

  /// Sends the driver to the one screen that can grant whatever is missing.
  Future<void> _fix(DiagBlocker blocker) async {
    switch (blocker.key) {
      case 'location':
      case 'background-location':
        await widget.services.locationService.ensurePermissions();
      case 'overlay':
        await widget.services.overlay.requestOverlayPermission();
      case 'lockhud':
        await widget.services.overlay.openLockHudSettings();
      case 'battery':
        await Diag.openBatterySettings();
      case 'notifications':
        await Diag.openNotificationSettings();
      default:
        return;
    }
    await _refreshLive();
  }
}

/// The engine getters the screen reads, gathered in one place so the screen never
/// touches the engine's internals directly.
class RadarEngineRef {
  RadarEngineRef(this.services);

  final AppServices services;

  bool get isRunning => services.engine.isRunning;
  DateTime? get lastFixAt => services.engine.lastFixAt;
  double get trackMeters => services.engine.corridor.trackMeters;
  int get camerasInCache => services.engine.cameraCacheSize;
  int get camerasInRange => services.engine.camerasInRange;
  int get forwardThreats => services.engine.forwardThreatCount;
  int get filteredOffRoute => services.engine.filteredOffRoute;
  AnnouncementRecord? get lastAnnouncement => services.engine.lastAnnouncement;
  int get announcements => services.engine.announcements;
  DateTime? get sessionStarted => services.engine.sessionStarted;
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return NexIconButton(
      icon: Icons.arrow_back_rounded,
      onPressed: onTap,
    );
  }
}

class _VerdictCard extends StatelessWidget {
  const _VerdictCard({required this.snapshot, required this.verdict});

  final DiagnosticsSnapshot snapshot;
  final SessionVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final bool ok = !verdict.isBad && snapshot.native != null;
    final Color tone = ok ? NexColors.primary : NexColors.danger;

    return NexCard(
      accent: tone,
      glow: true,
      tintStrength: 0.06,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              NexIconBadge(
                icon: ok ? Icons.verified_rounded : Icons.error_outline_rounded,
                color: tone,
                size: 44,
              ),
              const SizedBox(width: NexSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(snapshot.verdict, style: NexText.bodyStrong),
                    const SizedBox(height: 3),
                    Text(verdict.detail, style: NexText.caption),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LiveCard extends StatelessWidget {
  const _LiveCard({required this.snapshot});

  final DiagnosticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final String fixAge = snapshot.lastFixAge == null
        ? '—'
        : describeGap(snapshot.lastFixAge!);
    final Color fixTone =
        snapshot.fixIsStale ? NexColors.danger : NexColors.primary;
    final AnnouncementRecord? last = snapshot.lastAnnouncement;

    return NexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('CANLI', style: NexText.overline),
          const SizedBox(height: NexSpace.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: StatBlock(
                  value: snapshot.engineRunning ? 'AKTİV' : 'DAYANIB',
                  label: 'Mühərrik',
                  accent: snapshot.engineRunning
                      ? NexColors.primary
                      : NexColors.danger,
                  icon: Icons.memory_rounded,
                ),
              ),
              const _VDivider(),
              Expanded(
                child: StatBlock(
                  value: fixAge,
                  label: 'Son konum',
                  accent: fixTone,
                  icon: Icons.my_location_rounded,
                ),
              ),
              const _VDivider(),
              Expanded(
                child: StatBlock(
                  value: '${snapshot.trackMeters.round()} m',
                  label: 'Yol koridoru',
                  icon: Icons.alt_route_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: NexSpace.sm),
          NexDivider(),
          const SizedBox(height: NexSpace.xs),
          Row(
            children: <Widget>[
              Expanded(
                child: StatBlock(
                  value: '${snapshot.camerasInRange}',
                  label: '5 km-də radar',
                  accent: NexColors.amber,
                  icon: Icons.radar_rounded,
                ),
              ),
              const _VDivider(),
              Expanded(
                child: StatBlock(
                  value: '${snapshot.forwardThreats}',
                  label: 'Qarşıda',
                  icon: Icons.straight_rounded,
                ),
              ),
              const _VDivider(),
              Expanded(
                child: StatBlock(
                  value: '${snapshot.filteredOffRoute}',
                  label: 'Başqa yolda',
                  icon: Icons.call_split_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: NexSpace.sm),
          NexDivider(),
          const SizedBox(height: NexSpace.xs),
          Row(
            children: <Widget>[
              Icon(
                Icons.record_voice_over_rounded,
                size: 15,
                color: NexColors.textLow,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  last == null
                      ? 'Hələ anons yoxdur '
                          '(${snapshot.announcements})'
                      : 'Son anons ${last.summary} · ${last.text}',
                  style: NexText.caption,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BackgroundCard extends StatelessWidget {
  const _BackgroundCard({required this.snapshot});

  final DiagnosticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final NativeDiagnostics? n = snapshot.native;
    if (n == null) {
      return const NexCard(child: Text('Native məlumat yoxdur'));
    }

    return NexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('ARXA FON', style: NexText.overline),
          const SizedBox(height: NexSpace.sm),
          _flag('Servis işləyir', n.serviceRunning),
          _flag('Baloncuk ekrandadır', n.bubbleAttached,
              detail: n.hostLabel),
          _flag('Kilid ekranı icazəsi', n.lockHudEnabled,
              detail: n.lockHudAttached ? 'çəkiliş aktiv' : 'gözləyir'),
          _flag('Üzərdə göstərmə', n.overlayGranted),
          _flag('Bildirişlər', n.notificationsEnabled && n.notificationPermissionGranted),
          _flag('Batareya optimallaşdırması', !n.batteryOptimized,
              detail: n.batteryOptimized ? 'söndürülməlidir' : null),
          _flag('Arxa fon konumu', n.backgroundLocationGranted),
          // Not a problem when false: most phones have no Shizuku, and the
          // updater simply uses the system installer.
          _flag('Sükutla yeniləmə (Shizuku)', n.silentUpdate,
              detail: n.shizukuAvailable
                  ? (n.shizukuGranted ? 'aktiv' : 'icazə gözləyir')
                  : 'yoxdur — qurşadırıcı işlədilir'),
        ],
      ),
    );
  }

  Widget _flag(String label, bool ok, {String? detail}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: <Widget>[
          Icon(
            ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
            size: 16,
            color: ok ? NexColors.primary : NexColors.danger,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: NexText.body)),
          if (detail != null)
            Text(detail, style: NexText.caption)
          else
            StatusPill(
              dense: true,
              label: ok ? 'HAZIR' : 'YOX',
              color: ok ? NexColors.primary : NexColors.danger,
            ),
        ],
      ),
    );
  }
}

class _BlockersCard extends StatelessWidget {
  const _BlockersCard({required this.blockers, required this.onFix});

  final List<DiagBlocker> blockers;
  final Future<void> Function(DiagBlocker blocker) onFix;

  @override
  Widget build(BuildContext context) {
    return NexCard(
      accent: NexColors.danger,
      tintStrength: 0.08,
      padding: const EdgeInsets.fromLTRB(
        NexSpace.sm,
        NexSpace.sm,
        NexSpace.sm,
        4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: NexSpace.xs),
            child: Text('DÜZƏLTMƏK LAZIMDIR', style: NexText.overline),
          ),
          const SizedBox(height: NexSpace.xs),
          for (final DiagBlocker b in blockers)
            SettingTile(
              icon: Icons.report_gmailerrorred_rounded,
              title: b.title,
              subtitle: b.detail,
              accent: NexColors.danger,
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: NexColors.textLow,
              ),
              onTap: () => unawaited(onFix(b)),
            ),
        ],
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({
    required this.entries,
    required this.clearing,
    required this.onClear,
  });

  final List<DiagEntry> entries;
  final bool clearing;
  final Future<void> Function() onClear;

  @override
  Widget build(BuildContext context) {
    // Newest first, and the newest 60 lines are all a driver ever needs to see.
    final List<DiagEntry> shown = entries.reversed
        .where((DiagEntry e) => !e.isHeartbeat)
        .take(60)
        .toList(growable: false);

    return NexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('UÇUŞ QEYDİ', style: NexText.overline),
              const Spacer(),
              Text(
                '${entries.length} sətir',
                style: NexText.caption,
              ),
              const SizedBox(width: NexSpace.xs),
              if (clearing)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                GestureDetector(
                  onTap: () => unawaited(onClear()),
                  child: const Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: NexColors.textLow,
                  ),
                ),
            ],
          ),
          const SizedBox(height: NexSpace.xs),
          if (shown.isEmpty)
            Text('Qeyd boşdur', style: NexText.caption)
          else
            for (final DiagEntry e in shown) _LogRow(entry: e),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final DiagEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 58,
            child: Text(entry.clock, style: NexText.caption),
          ),
          Container(
            width: 62,
            margin: const EdgeInsets.only(right: 6),
            child: Text(
              entry.name,
              style: NexText.caption.copyWith(
                color: _tone(entry.name),
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(entry.detail, style: NexText.caption),
          ),
        ],
      ),
    );
  }

  Color _tone(String name) {
    switch (name) {
      case 'boot':
        return NexColors.cyan;
      case 'announce':
        return NexColors.amber;
      case 'lockHud':
        return NexColors.primary;
      default:
        return NexColors.textMid;
    }
  }
}

class _VDivider extends StatelessWidget {
  const _VDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: NexSpace.xs),
      color: NexColors.borderSoft,
    );
  }
}
