import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/location/average_speed_tracker.dart';
import '../../core/services/crowdsourced_radar_service.dart';
import '../../core/services/osm_sync_service.dart';
import '../../core/services/radar_engine.dart';
import '../../core/services/update_service.dart';
import '../../main.dart';
import '../../models/speed_camera.dart';
import '../../models/vehicle_state.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/theme/status_palette.dart';
import '../../ui/widgets/app_header.dart';
import '../../ui/widgets/brand.dart';
import '../../ui/widgets/controls.dart';
import '../../ui/widgets/speed_gauge.dart';
import '../../ui/widgets/surfaces.dart';
import '../overlay/floating_radar_bubble.dart';

/// The dashboard: everything a driver needs in the ten seconds before the phone
/// goes into the cradle.
///
/// Order of importance, top to bottom: is it running → how fast am I going →
/// what is ahead → start/stop → everything else.
class DriveTab extends StatefulWidget {
  const DriveTab({
    super.key,
    required this.services,
    required this.onOpenSettings,
    required this.onRadarsChanged,
  });

  final AppServices services;
  final VoidCallback onOpenSettings;
  final VoidCallback onRadarsChanged;

  @override
  State<DriveTab> createState() => _DriveTabState();
}

class _DriveTabState extends State<DriveTab> {
  bool _busy = false;

  AppServices get services => widget.services;
  RadarEngine get engine => widget.services.engine;

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _report() async {
    final ReportResult result = await engine.reportTemporaryRadar();
    services.lastNotice.value = result.message;
    widget.onRadarsChanged();
  }

  Future<void> _sync() async {
    final SyncResult result = await engine.syncOsmCameras();
    services.lastNotice.value = result.message;
    widget.onRadarsChanged();
  }

  void _showBubblePreview(VehicleState state) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            NexSpace.lg,
            NexSpace.xs,
            NexSpace.lg,
            NexSpace.xxl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Yüzen baloncuk', style: NexText.h2),
              const SizedBox(height: NexSpace.xxs),
              Text(
                'Ekranda necə görünəcək. Sürüklə, ölçünü dəyişmək üçün '
                'iki dəfə toxun.',
                style: NexText.body,
              ),
              const SizedBox(height: NexSpace.md),
              SizedBox(
                height: 230,
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: <Widget>[
                    FloatingRadarBubble(
                      state: state.hasFix ? state : demoThreatState(),
                      showRemaining: services.settings.showRemaining,
                      useMph: services.settings.useMph,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ValueListenableBuilder<VehicleState>(
        valueListenable: engine.state,
        builder: (BuildContext context, VehicleState state, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              NexSpace.page,
              0,
              NexSpace.page,
              NexSpace.xxl,
            ),
            children: <Widget>[
              NexHeader(
                title: 'NexRadar',
                subtitle: _statusText(state),
                leading: const NexLogo(size: 42),
                actions: <Widget>[
                  NexIconButton(
                    icon: services.settings.overlayEnabled
                        ? Icons.layers_rounded
                        : Icons.layers_outlined,
                    accent: NexColors.primary,
                    tooltip: 'Yüzen baloncuk',
                    onPressed: _busy
                        ? null
                        : () => _guard(
                              () => services.setOverlayEnabled(
                                !services.settings.overlayEnabled,
                              ),
                            ),
                  ),
                ],
              ),
              _UpdateBanner(
                services: services,
                onOpenSettings: widget.onOpenSettings,
              ),
              _TelemetryRow(services: services, state: state),
              const SizedBox(height: NexSpace.sm),
              _GaugeCard(services: services, state: state),
              const SizedBox(height: NexSpace.sm),
              _ThreatPanel(services: services, state: state),
              if (engine.averageReading != null) ...<Widget>[
                const SizedBox(height: NexSpace.sm),
                _SectionCard(reading: engine.averageReading!),
              ],
              const SizedBox(height: NexSpace.md),
              _PrimaryAction(
                running: engine.isRunning,
                busy: _busy,
                onPressed: () => _guard(
                  engine.isRunning ? services.stopDriving : services.startDriving,
                ),
              ),
              const SizedBox(height: NexSpace.md),
              _QuickActions(
                services: services,
                state: state,
                busy: _busy,
                onReport: () => _guard(_report),
                onSync: () => _guard(_sync),
                onPreview: () => _showBubblePreview(state),
              ),
              const SizedBox(height: NexSpace.md),
              _LogCard(services: services, engine: engine),
              const SizedBox(height: NexSpace.md),
              _AboutStrip(onOpenSettings: widget.onOpenSettings),
            ],
          );
        },
      ),
    );
  }

  String _statusText(VehicleState state) {
    if (!engine.isRunning) return 'Hazır · sürüşə başlamağı gözləyir';
    if (!state.hasFix) return 'GPS siqnalı gözlənilir…';
    if (state.isStale) return 'GPS siqnalı zəif';
    return 'İzləmə aktiv · ${state.camerasInRange} radar yaddaşda';
  }
}

/// Plausible "approaching a camera" frame, used before the first GPS fix so the
/// preview is never an empty hole.
VehicleState demoThreatState() => VehicleState(
      speedKmh: 74,
      rawSpeedKmh: 74,
      headingDegrees: 90,
      latitude: 40.4093,
      longitude: 49.8671,
      accuracyMeters: 6,
      timestamp: DateTime.now(),
      hasFix: false,
      threatDistanceMeters: 420,
    );

// ---------------------------------------------------------------------------

class _TelemetryRow extends StatelessWidget {
  const _TelemetryRow({required this.services, required this.state});

  final AppServices services;
  final VehicleState state;

  @override
  Widget build(BuildContext context) {
    final bool running = services.engine.isRunning;
    final Color gpsColor = !state.hasFix
        ? NexColors.textLow
        : state.isStale
            ? NexColors.amber
            : NexColors.primary;

    return NexCard(
      padding: const EdgeInsets.symmetric(
        horizontal: NexSpace.md,
        vertical: NexSpace.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: StatBlock(
              value: state.hasFix ? Fmt.accuracy(state.accuracyMeters) : '—',
              label: 'GPS dəqiqliyi',
              accent: gpsColor,
              icon: Icons.my_location_rounded,
            ),
          ),
          const _VDivider(),
          Expanded(
            child: StatBlock(
              value: state.hasFix ? Fmt.compass(state.headingDegrees) : '—',
              label: 'İstiqamət',
              icon: Icons.explore_rounded,
            ),
          ),
          const _VDivider(),
          Expanded(
            child: StatBlock(
              value: '${state.camerasInRange}',
              label: 'Bazada radar',
              accent: running ? NexColors.primary : null,
              icon: Icons.radar_rounded,
            ),
          ),
        ],
      ),
    );
  }
}

class _VDivider extends StatelessWidget {
  const _VDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 30,
      margin: const EdgeInsets.symmetric(horizontal: NexSpace.xs),
      color: NexColors.borderSoft,
    );
  }
}

// ---------------------------------------------------------------------------

class _GaugeCard extends StatelessWidget {
  const _GaugeCard({required this.services, required this.state});

  final AppServices services;
  final VehicleState state;

  @override
  Widget build(BuildContext context) {
    final bool running = services.engine.isRunning;
    final Color tone = StatusPalette.of(state.status);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double gauge = math.min(constraints.maxWidth - NexSpace.xxl, 290);
        return NexCard(
          padding: const EdgeInsets.fromLTRB(
            NexSpace.md,
            NexSpace.sm,
            NexSpace.md,
            NexSpace.md,
          ),
          accent: state.status == DrivingStatus.idle ? null : tone,
          glow: state.status == DrivingStatus.warning,
          tintStrength: 0.05,
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  StatusPill(
                    dense: true,
                    label: running ? 'AKTİV' : 'DAYANIB',
                    color: running ? NexColors.primary : NexColors.textLow,
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 138,
                    child: AnimatedBuilder(
                      animation: services.settings,
                      builder: (BuildContext context, _) => Segmented<bool>(
                        value: services.settings.useMph,
                        onChanged: (bool v) => services.settings.setUseMph(v),
                        options: const <SegmentedOption<bool>>[
                          SegmentedOption<bool>(value: false, label: 'km/s'),
                          SegmentedOption<bool>(value: true, label: 'mph'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: NexSpace.xs),
              SpeedGauge(
                speedKmh: state.speedKmh,
                limitKmh: state.speedLimit,
                status: state.hasFix ? state.status : DrivingStatus.idle,
                mph: services.settings.useMph,
                hasFix: state.hasFix,
                size: gauge,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------

/// The average-speed section the driver is inside right now.
///
/// This panel exists because a section camera judges a number the speedometer
/// never shows: the average since the entry marker. A driver watching only the
/// needle cannot know he is about to be fined for a fast first kilometre, so the
/// panel shows exactly what the camera on the far side will print.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.reading});

  final AverageSpeedReading reading;

  @override
  Widget build(BuildContext context) {
    final Color tone = reading.isOver ? NexColors.danger : NexColors.cyan;

    return NexCard(
      accent: tone,
      tintStrength: 0.07,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              NexIconBadge(
                icon: reading.isOver
                    ? Icons.trending_up_rounded
                    : Icons.timeline_outlined,
                color: tone,
                size: 40,
              ),
              const SizedBox(width: NexSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Orta sürət bölməsi', style: NexText.bodyStrong),
                    const SizedBox(height: 3),
                    Text(
                      'Bölməyə girəndən bəri '
                      '${reading.drivenLabel} · ${reading.elapsedLabel}',
                      style: NexText.caption,
                    ),
                  ],
                ),
              ),
              StatusPill(
                label: 'HƏDD ${reading.limitKmh}',
                color: NexColors.amber,
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: NexSpace.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                reading.averageLabel,
                style: NexText.h1.copyWith(fontSize: 30, color: tone),
              ),
              const SizedBox(width: 5),
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text('km/s ortalama', style: NexText.caption),
              ),
              const Spacer(),
              if (reading.isOver)
                StatusPill(
                  label: '+${reading.overByKmh.round()}',
                  color: NexColors.danger,
                  icon: Icons.error_outline_rounded,
                )
              else
                StatusPill(
                  label: '${reading.headroomKmh.round()} km/s ehtiyat',
                  color: NexColors.primary,
                  icon: Icons.check_circle_outline_rounded,
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: NexSpace.xs),
          NexProgressRail(
            value: (reading.averageKmh / (reading.limitKmh * 1.4)).clamp(0.0, 1.0),
            color: tone,
          ),
        ],
      ),
    );
  }
}

class _ThreatPanel extends StatelessWidget {
  const _ThreatPanel({required this.services, required this.state});

  final AppServices services;
  final VehicleState state;

  @override
  Widget build(BuildContext context) {
    final SpeedCamera? threat = state.threat;
    final double? distance = state.threatDistanceMeters;

    if (threat == null || distance == null) {
      return NexCard(
        child: Row(
          children: <Widget>[
            const NexIconBadge(
              icon: Icons.shield_outlined,
              color: NexColors.primary,
            ),
            const SizedBox(width: NexSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    state.hasFix
                        ? 'Qarşıda radar yoxdur'
                        : 'Konum gözlənilir',
                    style: NexText.bodyStrong,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    state.hasFix
                        ? 'Yol təmizdir. Radar aşkar olunanda burada '
                            'görünəcək.'
                        : 'GPS fiksi alınan kimi radarlar yoxlanılacaq.',
                    style: NexText.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final Color tone = StatusPalette.of(state.status);
    final Color typeColor = StatusPalette.ofCamera(threat.type);
    // 500 m is the "approaching" gate — the rail visualises that budget.
    final double progress = (1 - distance / 500).clamp(0.0, 1.0);

    return NexCard(
      accent: tone,
      tintStrength: 0.08,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              NexIconBadge(
                icon: threat.type.icon,
                color: typeColor,
                size: 42,
              ),
              const SizedBox(width: NexSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(threat.type.label('az'), style: NexText.bodyStrong),
                    const SizedBox(height: 2),
                    Row(
                      children: <Widget>[
                        StatusPill(
                          dense: true,
                          label: threat.isTemporary ? 'Topluluk' : 'OSM bazası',
                          color: threat.isTemporary
                              ? NexColors.cyan
                              : NexColors.textLow,
                        ),
                        const SizedBox(width: 6),
                        StatusPill(
                          dense: true,
                          label: 'Limit ${Fmt.limit(kmh: threat.maxSpeed, mph: services.settings.useMph)}',
                          color: NexColors.amber,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (state.isSpeeding)
                StatusPill(
                  label: '+${state.overspeedKmh.round()}',
                  color: NexColors.danger,
                  icon: Icons.trending_up_rounded,
                ),
            ],
          ),
          const SizedBox(height: NexSpace.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                Fmt.distance(distance),
                style: NexText.h1.copyWith(fontSize: 30),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('qalıb', style: NexText.caption),
              ),
              const Spacer(),
              if (state.etaSeconds != null)
                StatusPill(
                  label: '~${Fmt.eta(state.etaSeconds)}',
                  color: NexColors.textMid,
                  icon: Icons.schedule_rounded,
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: NexSpace.xs),
          NexProgressRail(value: progress, color: tone),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.running,
    required this.busy,
    required this.onPressed,
  });

  final bool running;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Color tone = running ? NexColors.danger : NexColors.primary;
    final Color ink = running ? const Color(0xFF2B0509) : NexColors.primaryInk;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NexRadius.pillAll,
        boxShadow: NexShadow.glow(tone, strength: 0.28),
      ),
      child: Material(
        color: tone,
        borderRadius: NexRadius.pillAll,
        child: InkWell(
          onTap: busy ? null : onPressed,
          borderRadius: NexRadius.pillAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 17),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (busy)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ink,
                    ),
                  )
                else
                  Icon(
                    running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    color: ink,
                    size: 24,
                  ),
                const SizedBox(width: NexSpace.xs),
                Text(
                  running ? 'Sürüşü dayandır' : 'Sürüşü başlat',
                  style: TextStyle(
                    fontFamily: NexFont.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.services,
    required this.state,
    required this.busy,
    required this.onReport,
    required this.onSync,
    required this.onPreview,
  });

  final AppServices services;
  final VehicleState state;
  final bool busy;
  final VoidCallback onReport;
  final VoidCallback onSync;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final bool overlayOn = services.settings.overlayEnabled;
    final bool canReport = !busy && state.hasFix;

    return NexCard(
      padding: const EdgeInsets.symmetric(
        horizontal: NexSpace.xs,
        vertical: NexSpace.xs,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: NexActionTile(
              icon: Icons.add_location_alt_outlined,
              label: 'Radar bildir',
              accent: NexColors.danger,
              onPressed: canReport ? onReport : null,
            ),
          ),
          Expanded(
            child: NexActionTile(
              icon: overlayOn ? Icons.layers_rounded : Icons.layers_outlined,
              label: 'Baloncuk',
              accent: NexColors.primary,
              active: overlayOn,
              onPressed: busy
                  ? null
                  : () => services.setOverlayEnabled(!overlayOn),
            ),
          ),
          Expanded(
            child: NexActionTile(
              icon: Icons.cloud_sync_outlined,
              label: 'Sinxronla',
              accent: NexColors.cyan,
              onPressed: busy ? null : onSync,
            ),
          ),
          Expanded(
            child: NexActionTile(
              icon: Icons.visibility_outlined,
              label: 'Önizləmə',
              accent: NexColors.amber,
              onPressed: onPreview,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _LogCard extends StatelessWidget {
  const _LogCard({required this.services, required this.engine});

  final AppServices services;
  final RadarEngine engine;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: services.settings,
      builder: (BuildContext context, _) {
        final bool expanded = services.settings.logExpanded;
        return NexCard(
          padding: const EdgeInsets.fromLTRB(
            NexSpace.md,
            NexSpace.xs,
            NexSpace.xs,
            NexSpace.xs,
          ),
          child: Column(
            children: <Widget>[
              InkWell(
                onTap: () =>
                    services.settings.setLogExpanded(!expanded),
                borderRadius: NexRadius.mdAll,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: NexSpace.xs),
                  child: Row(
                    children: <Widget>[
                      const NexIconBadge(
                        icon: Icons.terminal_rounded,
                        color: NexColors.cyan,
                        size: 36,
                      ),
                      const SizedBox(width: NexSpace.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('Canlı jurnal', style: NexText.bodyStrong),
                            ValueListenableBuilder<List<EngineLogEntry>>(
                              valueListenable: engine.log,
                              builder: (BuildContext context,
                                  List<EngineLogEntry> entries, _) {
                                return Text(
                                  entries.isEmpty
                                      ? 'Hələ hadisə yoxdur'
                                      : '${entries.length} qeyd',
                                  style: NexText.caption,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: NexMotion.base,
                        child: const Padding(
                          padding: EdgeInsets.only(right: NexSpace.xs),
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: NexColors.textLow,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedCrossFade(
                duration: NexMotion.base,
                crossFadeState: expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Padding(
                  padding: const EdgeInsets.only(
                    left: NexSpace.xxs,
                    right: NexSpace.sm,
                    bottom: NexSpace.xs,
                  ),
                  child: ValueListenableBuilder<List<EngineLogEntry>>(
                    valueListenable: engine.log,
                    builder: (BuildContext context,
                        List<EngineLogEntry> entries, _) {
                      if (entries.isEmpty) {
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Mühərrik işə salınanda hadisələr burada görünür.',
                            style: NexText.caption,
                          ),
                        );
                      }
                      return Column(
                        children: entries
                            .take(8)
                            .map((EngineLogEntry e) => _LogRow(entry: e))
                            .toList(growable: false),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final EngineLogEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            entry.clock,
            style: NexText.numericSmall.copyWith(
              fontSize: 11.5,
              color: NexColors.primary,
            ),
          ),
          const SizedBox(width: NexSpace.xs),
          Expanded(
            child: Text(
              entry.message,
              style: NexText.caption.copyWith(color: NexColors.textMid),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _AboutStrip extends StatelessWidget {
  const _AboutStrip({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Icon(Icons.info_outline_rounded, size: 14, color: NexColors.textLow),
        const SizedBox(width: NexSpace.xs),
        Expanded(
          child: Text(
            'Radar məlumatları OpenStreetMap və sürücü bildirişlərinə '
            'əsaslanır. Diqqətli sürün.',
            style: NexText.caption.copyWith(fontSize: 11),
          ),
        ),
        TextButton(
          onPressed: onOpenSettings,
          child: const Text('Ayarlar'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

/// Appears only while a newer GitHub release is waiting to be installed.
///
/// Kept at the very top of the dashboard: the whole point of in-app updates is
/// that the driver never has to be told to fetch an APK by hand.
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.services, required this.onOpenSettings});

  final AppServices services;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReleaseInfo?>(
      valueListenable: services.availableUpdate,
      builder: (BuildContext context, ReleaseInfo? release, _) {
        if (release == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: NexSpace.sm),
          child: NexCard(
            accent: NexColors.primary,
            glow: true,
            tintStrength: 0.08,
            onTap: onOpenSettings,
            padding: const EdgeInsets.symmetric(
              horizontal: NexSpace.md,
              vertical: NexSpace.sm,
            ),
            child: Row(
              children: <Widget>[
                const NexIconBadge(
                  icon: Icons.system_update_alt_rounded,
                  color: NexColors.primary,
                  size: 38,
                ),
                const SizedBox(width: NexSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Yeniləmə mövcuddur: v${release.version}',
                        style: NexText.bodyStrong,
                      ),
                      Text(
                        release.headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NexText.caption,
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: NexColors.textLow,
                  size: 20,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
