// A development-only design gallery.
//
// This entrypoint renders the NexRadar design system with canned data so the UI
// can be reviewed in a browser without an Android device. It is never
// referenced from `lib/main.dart`, so it is tree-shaken out of the release APK.
//
//   flutter run -d chrome -t lib/dev/preview_main.dart
import 'package:flutter/material.dart';

import '../core/constants/camera_types.dart';
import '../models/speed_camera.dart';
import '../models/vehicle_state.dart';
import '../ui/theme/app_theme.dart';
import '../ui/theme/status_palette.dart';
import '../ui/widgets/app_header.dart';
import '../ui/widgets/brand.dart';
import '../ui/widgets/controls.dart';
import '../ui/widgets/setting_tiles.dart';
import '../ui/widgets/speed_gauge.dart';
import '../ui/widgets/surfaces.dart';
import '../views/overlay/floating_radar_bubble.dart';

void main() {
  runApp(
    MaterialApp(
      title: 'NexRadar Design',
      debugShowCheckedModeBanner: false,
      theme: NexTheme.dark(),
      home: const DesignGallery(),
    ),
  );
}

/// The full design-system gallery. Public so `test/design_test.dart` can render
/// it headlessly and catch layout overflows at real phone sizes.
class DesignGallery extends StatelessWidget {
  const DesignGallery({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020405),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(NexSpace.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const NexLogo(size: 46),
                const SizedBox(width: NexSpace.sm),
                Text('NexRadar — UI/UX redesign', style: NexText.h1),
              ],
            ),
            const SizedBox(height: NexSpace.xs),
            Text(
              'Bu ekran dizayn sistemini göstərir. Telefon çərçivələrindəki '
              'hər şey real widget-lardır.',
              style: NexText.body,
            ),
            const SizedBox(height: NexSpace.xl),
            Wrap(
              spacing: NexSpace.xl,
              runSpacing: NexSpace.xl,
              crossAxisAlignment: WrapCrossAlignment.start,
              children: <Widget>[
                _Frame(
                  label: '1 · Sürüş paneli',
                  child: const DashboardMock(),
                ),
                _Frame(
                  label: '2 · Gösterge halları',
                  child: const GaugeStates(),
                ),
                _Frame(
                  label: '3 · Radarlar',
                  child: const RadarsMock(),
                ),
                _Frame(
                  label: '4 · Ayarlar',
                  child: const SettingsMock(),
                ),
                _Frame(
                  label: '5 · Baloncuk & naviqasiya',
                  child: const BubbleMock(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A 390×844 phone viewport so spacing reads at the real density.
class _Frame extends StatelessWidget {
  const _Frame({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label.toUpperCase(), style: NexText.overline),
        const SizedBox(height: NexSpace.xs),
        Container(
          width: 390,
          height: 844,
          decoration: BoxDecoration(
            color: NexColors.background,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: NexColors.border),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 40,
                offset: const Offset(0, 20),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(29),
            child: SafeArea(
              top: false,
              bottom: false,
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 1 · Dashboard
// ---------------------------------------------------------------------------

class DashboardMock extends StatelessWidget {
  const DashboardMock({super.key});

  @override
  Widget build(BuildContext context) {
    final VehicleState state = _threatState(
      speed: 132,
      limit: 80,
      distance: 168,
      heading: 92,
    );
    final Color tone = StatusPalette.of(state.status);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NexSpace.page,
        NexSpace.sm,
        NexSpace.page,
        NexSpace.xxl,
      ),
      children: <Widget>[
        NexHeader(
          title: 'NexRadar',
          subtitle: 'İzləmə aktiv · 128 radar yaddaşda',
          leading: const NexLogo(size: 42),
          actions: <Widget>[
            NexIconButton(
              icon: Icons.layers_rounded,
              accent: NexColors.primary,
              onPressed: () {},
            ),
          ],
        ),
        NexCard(
          padding: const EdgeInsets.symmetric(
            horizontal: NexSpace.md,
            vertical: NexSpace.sm,
          ),
          child: const Row(
            children: <Widget>[
              Expanded(
                child: StatBlock(
                  value: '±4 m',
                  label: 'GPS dəqiqliyi',
                  accent: NexColors.primary,
                  icon: Icons.my_location_rounded,
                ),
              ),
              _VDivider(),
              Expanded(
                child: StatBlock(
                  value: 'Şərq',
                  label: 'İstiqamət',
                  icon: Icons.explore_rounded,
                ),
              ),
              _VDivider(),
              Expanded(
                child: StatBlock(
                  value: '128',
                  label: 'Bazada radar',
                  accent: NexColors.primary,
                  icon: Icons.radar_rounded,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: NexSpace.sm),
        NexCard(
          accent: tone,
          glow: true,
          tintStrength: 0.05,
          padding: const EdgeInsets.fromLTRB(
            NexSpace.md,
            NexSpace.sm,
            NexSpace.md,
            NexSpace.md,
          ),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  const StatusPill(
                    dense: true,
                    label: 'AKTİV',
                    color: NexColors.primary,
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 138,
                    child: Segmented<bool>(
                      value: false,
                      onChanged: (bool _) {},
                      options: const <SegmentedOption<bool>>[
                        SegmentedOption<bool>(value: false, label: 'km/s'),
                        SegmentedOption<bool>(value: true, label: 'mph'),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: NexSpace.xs),
              SpeedGauge(
                speedKmh: state.speedKmh,
                limitKmh: state.speedLimit,
                status: state.status,
                mph: false,
                size: 288,
              ),
            ],
          ),
        ),
        const SizedBox(height: NexSpace.sm),
        NexCard(
          accent: tone,
          tintStrength: 0.08,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const NexIconBadge(
                    icon: Icons.local_police_outlined,
                    color: NexColors.danger,
                    size: 42,
                  ),
                  const SizedBox(width: NexSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('Mobil YPX', style: NexText.bodyStrong),
                        const SizedBox(height: 2),
                        Row(
                          children: const <Widget>[
                            StatusPill(
                              dense: true,
                              label: 'Topluluk',
                              color: NexColors.cyan,
                            ),
                            SizedBox(width: 6),
                            StatusPill(
                              dense: true,
                              label: 'Limit 80',
                              color: NexColors.amber,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const StatusPill(
                    label: '+52',
                    color: NexColors.danger,
                    icon: Icons.trending_up_rounded,
                  ),
                ],
              ),
              const SizedBox(height: NexSpace.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text('168 m', style: NexText.h1.copyWith(fontSize: 30)),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('qalıb', style: NexText.caption),
                  ),
                  const Spacer(),
                  const StatusPill(
                    label: '~5s',
                    color: NexColors.textMid,
                    icon: Icons.schedule_rounded,
                    dense: true,
                  ),
                ],
              ),
              const SizedBox(height: NexSpace.xs),
              const NexProgressRail(value: 0.66, color: NexColors.danger),
            ],
          ),
        ),
        const SizedBox(height: NexSpace.md),
        const _PrimaryActionMock(),
        const SizedBox(height: NexSpace.md),
        NexCard(
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
                  onPressed: () {},
                ),
              ),
              Expanded(
                child: NexActionTile(
                  icon: Icons.layers_rounded,
                  label: 'Baloncuk',
                  accent: NexColors.primary,
                  active: true,
                  onPressed: () {},
                ),
              ),
              Expanded(
                child: NexActionTile(
                  icon: Icons.cloud_sync_outlined,
                  label: 'Sinxronla',
                  accent: NexColors.cyan,
                  onPressed: () {},
                ),
              ),
              Expanded(
                child: NexActionTile(
                  icon: Icons.visibility_outlined,
                  label: 'Önizləmə',
                  accent: NexColors.amber,
                  onPressed: () {},
                ),
              ),
            ],
          ),
        ),
      ],
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

class _PrimaryActionMock extends StatelessWidget {
  const _PrimaryActionMock();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NexRadius.pillAll,
        boxShadow: NexShadow.glow(NexColors.danger, strength: 0.28),
      ),
      child: Material(
        color: NexColors.danger,
        borderRadius: NexRadius.pillAll,
        child: InkWell(
          onTap: () {},
          borderRadius: NexRadius.pillAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 17),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(
                  Icons.stop_rounded,
                  color: Color(0xFF2B0509),
                  size: 24,
                ),
                const SizedBox(width: NexSpace.xs),
                Text(
                  'Sürüşü dayandır',
                  style: TextStyle(
                    fontFamily: NexFont.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: const Color(0xFF2B0509),
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
// 2 · Gauge states
// ---------------------------------------------------------------------------

class GaugeStates extends StatelessWidget {
  const GaugeStates({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(NexSpace.page),
      children: <Widget>[
        Text('GÖSTERGE HALLARI', style: NexText.overline),
        const SizedBox(height: NexSpace.md),
        _gaugeBlock('Yol təmizdir — 0 km/s, limit yoxdur', 0, null, DrivingStatus.idle, false),
        _gaugeBlock('Yaxınlaşır — 88 km/s, limit 80', 88, 80, DrivingStatus.approaching, false),
        _gaugeBlock('XƏBƏRDARLIQ — 132 km/s, limit 80', 132, 80, DrivingStatus.warning, false),
        _gaugeBlock('mph rejimi — 62 mph, limit 55 mph', 99.8, 88, DrivingStatus.approaching, true),
      ],
    );
  }

  Widget _gaugeBlock(
    String label,
    double speed,
    int? limit,
    DrivingStatus status,
    bool mph,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NexSpace.lg),
      child: Column(
        children: <Widget>[
          Text(label, style: NexText.title, textAlign: TextAlign.center),
          const SizedBox(height: NexSpace.xs),
          SpeedGauge(
            speedKmh: speed,
            limitKmh: limit,
            status: status,
            mph: mph,
            size: 320,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3 · Radars
// ---------------------------------------------------------------------------

class RadarsMock extends StatelessWidget {
  const RadarsMock({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NexSpace.page,
        NexSpace.sm,
        NexSpace.page,
        NexSpace.xxl,
      ),
      children: <Widget>[
        NexHeader(
          title: 'Radarlar',
          subtitle: '42 yaxında · 1286 bazada',
          leading: const NexLogo(size: 42),
          actions: <Widget>[
            NexIconButton(icon: Icons.refresh_rounded, onPressed: () {}),
          ],
        ),
        const NexCard(
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: StatBlock(
                      value: '1286',
                      label: 'Yaddaşdaki radar',
                      accent: NexColors.primary,
                      icon: Icons.storage_rounded,
                    ),
                  ),
                  SizedBox(width: NexSpace.xs),
                  Expanded(
                    child: StatBlock(
                      value: '42',
                      label: 'Yaxınlıqda',
                      accent: NexColors.amber,
                      icon: Icons.near_me_rounded,
                    ),
                  ),
                  SizedBox(width: NexSpace.xs),
                  Expanded(
                    child: StatBlock(
                      value: '7',
                      label: 'Topluluk',
                      accent: NexColors.cyan,
                      icon: Icons.groups_rounded,
                    ),
                  ),
                ],
              ),
              SizedBox(height: NexSpace.sm),
              NexDivider(),
              SizedBox(height: NexSpace.xs),
              Row(
                children: <Widget>[
                  Icon(
                    Icons.cloud_done_outlined,
                    size: 14,
                    color: NexColors.textLow,
                  ),
                  SizedBox(width: 6),
                  Text(
                    'Son sinxronizasiya: 12 dəq əvvəl',
                    style: NexText.caption,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: NexSpace.sm),
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.cloud_download_outlined, size: 19),
                label: const Text('OSM-dən sinxronlaşdır'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
              ),
            ),
            const SizedBox(width: NexSpace.xs),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.add_location_alt_outlined, size: 19),
                label: const Text('Radar bildir'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 50),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: NexSpace.md),
        Segmented<int>(
          value: 0,
          onChanged: (int _) {},
          options: const <SegmentedOption<int>>[
            SegmentedOption<int>(value: 0, label: 'Hamısı'),
            SegmentedOption<int>(value: 1, label: 'Sabit'),
            SegmentedOption<int>(value: 2, label: 'Mobil'),
            SegmentedOption<int>(value: 3, label: 'Digər'),
          ],
        ),
        const SizedBox(height: NexSpace.md),
        _radarRow('Sabit radar', 'OSM', '2 dəq əvvəl', 180, 60,
            Icons.photo_camera_outlined, NexColors.amber,
            distance: '180 m'),
        _radarRow('Mobil YPX', 'Topluluk', '5 dəq əvvəl', 340, 80,
            Icons.local_police_outlined, NexColors.danger,
            distance: '340 m'),
        _radarRow('İşıqfor radarı', 'OSM', '1 saat əvvəl', 720, 50,
            Icons.traffic_outlined, const Color(0xFFB08CFF),
            distance: '720 m'),
        _radarRow('Orta sürət ölçmə', 'OSM', '3 saat əvvəl', 1240, 90,
            Icons.timeline_outlined, NexColors.cyan,
            distance: '1.2 km'),
      ],
    );
  }

  Widget _radarRow(
    String title,
    String source,
    String age,
    double meters,
    int limit,
    IconData icon,
    Color color, {
    required String distance,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NexSpace.xs),
      child: NexCard(
        onTap: () {},
        padding: const EdgeInsets.symmetric(
          horizontal: NexSpace.md,
          vertical: NexSpace.sm,
        ),
        child: Row(
          children: <Widget>[
            NexIconBadge(icon: icon, color: color, size: 42),
            const SizedBox(width: NexSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: NexText.bodyStrong),
                  const SizedBox(height: 3),
                  Row(
                    children: <Widget>[
                      StatusPill(
                        dense: true,
                        label: source,
                        color: source == 'Topluluk'
                            ? NexColors.cyan
                            : NexColors.textLow,
                      ),
                      const SizedBox(width: 6),
                      Text(age, style: NexText.caption),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: NexSpace.xs),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(distance, style: NexText.numeric),
                const SizedBox(height: 2),
                Text('Limit $limit km/s', style: NexText.caption),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 4 · Settings
// ---------------------------------------------------------------------------

class SettingsMock extends StatelessWidget {
  const SettingsMock({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NexSpace.page,
        0,
        NexSpace.page,
        NexSpace.xxl,
      ),
      children: <Widget>[
        const NexHeader(
          title: 'Ayarlar',
          subtitle: 'NexRadar v1.0.0',
          leading: NexLogo(size: 42),
        ),
        SettingGroup(
          title: 'Səs və anons',
          children: <Widget>[
            SettingSwitch(
              icon: Icons.record_voice_over_rounded,
              title: 'Səsli xəbərdarlıq',
              subtitle: '400 m və 150 m qaldıqda danışır',
              value: true,
              onChanged: (bool _) {},
            ),
            SettingTile(
              icon: Icons.translate_rounded,
              title: 'Dil',
              subtitle: 'Azərbaycan dili · aktiv səs: az-AZ',
              accent: NexColors.cyan,
              onTap: () {},
            ),
            SettingSwitch(
              icon: Icons.graphic_eq_rounded,
              title: 'Bip səsləri',
              subtitle: '500 m-də yumşaq, 200 m-də həyəcan siqnalı',
              value: false,
              onChanged: (bool _) {},
            ),
          ],
        ),
        SettingGroup(
          title: 'Göstəriş',
          footer: 'Açısal filtr qarşı şeridi və perpendikulyar küçələri '
              'süzgəcdən keçirir.',
          children: <Widget>[
            SettingTile(
              icon: Icons.straighten_rounded,
              title: 'Sürət vahidi',
              subtitle: 'Göstərici və baloncuk üçün',
              trailing: SizedBox(
                width: 124,
                child: Segmented<bool>(
                  value: false,
                  onChanged: (bool _) {},
                  options: const <SegmentedOption<bool>>[
                    SegmentedOption<bool>(value: false, label: 'km/s'),
                    SegmentedOption<bool>(value: true, label: 'mph'),
                  ],
                ),
              ),
            ),
            SettingSlider(
              icon: Icons.screen_rotation_alt_rounded,
              title: 'Açısal filtr',
              subtitle: 'θ_heading − θ_radar',
              value: 45,
              min: 15,
              max: 90,
              divisions: 15,
              display: '45°',
              accent: NexColors.amber,
              onChanged: (double _) {},
            ),
          ],
        ),
        SettingGroup(
          title: 'Yüzen baloncuk',
          children: <Widget>[
            SettingSwitch(
              icon: Icons.layers_rounded,
              title: 'Baloncuğu göstər',
              subtitle: 'Digər tətbiqlərin üzərində və kilid ekranında görünür',
              value: true,
              onChanged: (bool _) {},
            ),
            SettingTile(
              icon: Icons.lock_outline_rounded,
              title: 'Kilid ekranı dəstəyi',
              subtitle: 'Ekranı yandırdıqda baloncuk şifrə istəmədən görünür',
              accent: NexColors.primary,
              trailing: const StatusPill(
                label: 'AKTİV',
                color: NexColors.primary,
                dense: true,
              ),
            ),
            const SettingTile(
              icon: Icons.delete_sweep_outlined,
              title: 'Yerli keşi təmizlə',
              subtitle: 'Bütün radarlar və gözləyən bildirişlər silinir',
              danger: true,
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 5 · Bubble + navigation + type
// ---------------------------------------------------------------------------

class BubbleMock extends StatelessWidget {
  const BubbleMock({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(NexSpace.page),
      children: <Widget>[
        Text('BALONCUK', style: NexText.overline),
        const SizedBox(height: NexSpace.md),
        Row(
          children: <Widget>[
            FloatingRadarBubble(
              state: _threatState(
                speed: 44,
                limit: null,
                distance: null,
                heading: 0,
              ),
              size: 150,
              canvas: 165,
            ),
            const SizedBox(width: NexSpace.sm),
            FloatingRadarBubble(
              state: _threatState(
                speed: 74,
                limit: 80,
                distance: 380,
                heading: 90,
              ),
              size: 150,
              canvas: 165,
              onReportRadar: () {},
            ),
          ],
        ),
        const SizedBox(height: NexSpace.md),
        FloatingRadarBubble(
          state: _threatState(
            speed: 118,
            limit: 80,
            distance: 160,
            heading: 90,
          ),
          size: 200,
          canvas: 340,
          onReportRadar: () {},
        ),
        const SizedBox(height: NexSpace.xl),
        Text('NAVİQASİYA', style: NexText.overline),
        const SizedBox(height: NexSpace.sm),
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: NexColors.surfaceAlt,
            borderRadius: BorderRadius.circular(NexRadius.xl),
            border: Border.all(color: NexColors.borderSoft),
            boxShadow: NexShadow.card,
          ),
          child: Row(
            children: <Widget>[
              _navItem(Icons.speed_rounded, 'Sürüş', true),
              _navItem(Icons.radar_outlined, 'Radarlar', false),
              _navItem(Icons.tune_outlined, 'Ayarlar', false),
            ],
          ),
        ),
        const SizedBox(height: NexSpace.xl),
        Text('TİPOQRAFİYA', style: NexText.overline),
        const SizedBox(height: NexSpace.sm),
        Text('Aa — H1 başlıq', style: NexText.h1),
        Text('Aa — H2 başlıq', style: NexText.h2),
        Text('Aa — H3 başlıq', style: NexText.h3),
        Text('Aa — body mətni', style: NexText.body),
        Text('Aa — caption', style: NexText.caption),
        Text('Aa — 0123456789', style: NexText.numeric),
        const SizedBox(height: NexSpace.md),
        Text('İKONLAR', style: NexText.overline),
        const SizedBox(height: NexSpace.sm),
        const Wrap(
          spacing: NexSpace.xs,
          runSpacing: NexSpace.xs,
          children: <Widget>[
            NexIconBadge(icon: Icons.photo_camera_outlined, color: NexColors.amber),
            NexIconBadge(icon: Icons.local_police_outlined, color: NexColors.danger),
            NexIconBadge(icon: Icons.traffic_outlined, color: Color(0xFFB08CFF)),
            NexIconBadge(icon: Icons.timeline_outlined, color: NexColors.cyan),
            NexIconBadge(icon: Icons.radar_rounded, color: NexColors.primary),
          ],
        ),
        const SizedBox(height: NexSpace.lg),
        const Center(child: RadarSweep(size: 190)),
      ],
    );
  }

  Widget _navItem(IconData icon, String label, bool active) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: active
              ? NexColors.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(NexRadius.lg),
          border: Border.all(
            color: active
                ? NexColors.primary.withValues(alpha: 0.30)
                : Colors.transparent,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 22,
              color: active ? NexColors.primary : NexColors.textLow,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontFamily: NexFont.text,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: active ? NexColors.textHigh : NexColors.textLow,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

VehicleState _threatState({
  required double speed,
  required int? limit,
  required double? distance,
  required double heading,
}) {
  // The posted limit lives on the threat camera, exactly like in production.
  final SpeedCamera? camera = (limit == null || distance == null)
      ? null
      : SpeedCamera(
          latitude: 40.4120,
          longitude: 49.8671,
          maxSpeed: limit,
          directionBearing: heading,
          type: CameraType.mobile,
          updatedAt: DateTime.now(),
          distanceMeters: distance,
        );
  return VehicleState(
    speedKmh: speed,
    rawSpeedKmh: speed,
    headingDegrees: heading,
    latitude: 40.4093,
    longitude: 49.8671,
    accuracyMeters: 4,
    timestamp: DateTime.now(),
    threat: camera,
    threatDistanceMeters: distance,
    camerasInRange: 128,
  );
}
