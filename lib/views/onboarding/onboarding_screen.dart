import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/services/settings_service.dart';
import '../../main.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/widgets/brand.dart';
import '../../ui/widgets/controls.dart';
import '../../ui/widgets/surfaces.dart';

/// First-run flow: what the app does, how the driver wants it configured
/// (language + units), and the four OS grants it needs to run in the
/// background.
///
/// The permission page re-reads the system state on every resume, because two
/// of the four grants (overlay, battery) leave the app and are only confirmed
/// once the user comes back.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.services,
    required this.onFinished,
  });

  final AppServices services;
  final VoidCallback onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  final PageController _controller = PageController();
  int _page = 0;

  bool _location = false;
  bool _notification = false;
  bool _overlay = false;
  bool _battery = false;
  bool _busy = false;

  SettingsService get settings => widget.services.settings;

  static const int _pageCount = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    final bool location = await widget.services.locationService.hasPermission();
    bool notification = false;
    bool battery = false;
    try {
      notification = await Permission.notification.isGranted;
      battery = await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {
      // Permission groups are unavailable on a handful of OEM builds.
    }
    final bool overlay = widget.services.overlay.isSupported &&
        await widget.services.overlay.hasOverlayPermission();
    if (!mounted) return;
    setState(() {
      _location = location;
      _notification = notification;
      _overlay = overlay;
      _battery = battery;
    });
  }

  Future<void> _requestAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.services.locationService.ensurePermissions();
      try {
        await Permission.notification.request();
      } catch (_) {}
      if (widget.services.overlay.isSupported) {
        await widget.services.overlay.requestOverlayPermission();
      }
      await _refreshPermissions();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    await settings.setOnboarded(true);
    widget.onFinished();
  }

  void _next() {
    if (_page < _pageCount - 1) {
      _controller.nextPage(
        duration: NexMotion.slow,
        curve: NexMotion.emphasized,
      );
    } else {
      _finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: <Widget>[
          const Positioned.fill(child: _OnboardingBackdrop()),
          SafeArea(
            child: Column(
              children: <Widget>[
                Expanded(
                  child: PageView(
                    controller: _controller,
                    onPageChanged: (int i) => setState(() => _page = i),
                    children: <Widget>[
                      _HeroPage(),
                      _SetupPage(settings: settings),
                      _PermissionPage(
                        location: _location,
                        notification: _notification,
                        overlay: _overlay,
                        battery: _battery,
                        overlaySupported: widget.services.overlay.isSupported,
                        busy: _busy,
                        onRequestAll: _requestAll,
                      ),
                    ],
                  ),
                ),
                _Footer(
                  page: _page,
                  count: _pageCount,
                  label: switch (_page) {
                    0 => 'Davam et',
                    1 => 'İcazələrə keç',
                    _ => 'Başla',
                  },
                  busy: _busy,
                  onNext: _next,
                  onSkip: _page == _pageCount - 1 ? _finish : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _OnboardingBackdrop extends StatelessWidget {
  const _OnboardingBackdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0xFF08120F),
            NexColors.background,
            NexColors.background,
          ],
          stops: <double>[0.0, 0.45, 1.0],
        ),
      ),
      child: Align(
        alignment: const Alignment(0, -0.72),
        child: Container(
          width: 420,
          height: 420,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: <Color>[
                NexColors.primary.withValues(alpha: 0.13),
                NexColors.primary.withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PageShell extends StatelessWidget {
  const _PageShell({required this.children, this.scrollable = false});

  final List<Widget> children;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final List<Widget> content = <Widget>[
      const SizedBox(height: NexSpace.lg),
      ...children,
      const SizedBox(height: NexSpace.lg),
    ];
    if (scrollable) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: NexSpace.xl),
        children: content,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NexSpace.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: children,
      ),
    );
  }
}

class _HeroPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _PageShell(
      children: <Widget>[
        const Center(child: RadarSweep(size: 230)),
        const SizedBox(height: NexSpace.lg),
        const Center(child: NexWordmark(size: 46, showTagline: false)),
        const SizedBox(height: NexSpace.md),
        Text(
          'Radarları əvvəlcədən gör,\nsürətini sakit idarə et.',
          textAlign: TextAlign.center,
          style: NexText.h2.copyWith(fontSize: 24, height: 1.25),
        ),
        const SizedBox(height: NexSpace.sm),
        Text(
          'NexRadar arxa fonda işləyir: canlı sürət, səsli radar '
          'xəbərdarlığı və ekran bağlı olsa da görünən yüzen baloncuk.',
          textAlign: TextAlign.center,
          style: NexText.body,
        ),
        const SizedBox(height: NexSpace.xl),
        const Wrap(
          alignment: WrapAlignment.center,
          spacing: NexSpace.xs,
          runSpacing: NexSpace.xs,
          children: <Widget>[
            StatusPill(label: '60 FPS sürət', color: NexColors.primary, icon: Icons.speed_rounded),
            StatusPill(label: 'Səsli anons', color: NexColors.cyan, icon: Icons.record_voice_over_rounded),
            StatusPill(label: 'Kilid ekranı', color: NexColors.amber, icon: Icons.lock_outline_rounded),
            StatusPill(label: 'Offline baza', color: NexColors.primary, icon: Icons.cloud_off_rounded),
          ],
        ),
      ],
    );
  }
}

class _SetupPage extends StatelessWidget {
  const _SetupPage({required this.settings});

  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settings,
      builder: (BuildContext context, _) {
        return _PageShell(
          scrollable: true,
          children: <Widget>[
            const SizedBox(height: NexSpace.xxl),
            Text('Sənə uyğunlaşdıraq', style: NexText.h1),
            const SizedBox(height: NexSpace.xs),
            Text(
              'Bunları istənilən vaxt tənzimləmələrdən dəyişə bilərsən.',
              style: NexText.body,
            ),
            const SizedBox(height: NexSpace.xl),
            NexCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('SƏS DİLİ', style: NexText.overline),
                  const SizedBox(height: NexSpace.sm),
                  Segmented<String>(
                    value: settings.language,
                    onChanged: (String v) => settings.setLanguage(v),
                    options: const <SegmentedOption<String>>[
                      SegmentedOption<String>(value: 'az-AZ', label: 'AZ'),
                      SegmentedOption<String>(value: 'tr-TR', label: 'TR'),
                      SegmentedOption<String>(value: 'ru-RU', label: 'RU'),
                      SegmentedOption<String>(value: 'en-US', label: 'EN'),
                    ],
                  ),
                  const SizedBox(height: NexSpace.sm),
                  Text(
                    'Seçilmiş dil cihazda yoxdursa, NexRadar avtomatik '
                    'Türkcə/İngiliscə danışır.',
                    style: NexText.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(height: NexSpace.md),
            NexCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('SÜRƏT VAHİDİ', style: NexText.overline),
                  const SizedBox(height: NexSpace.sm),
                  Segmented<bool>(
                    value: settings.useMph,
                    onChanged: (bool v) => settings.setUseMph(v),
                    options: const <SegmentedOption<bool>>[
                      SegmentedOption<bool>(value: false, label: 'km/s'),
                      SegmentedOption<bool>(value: true, label: 'mph'),
                    ],
                  ),
                  const SizedBox(height: NexSpace.sm),
                  Text(
                    'Göstərici və baloncuk seçilmiş vahiddə göstərilir.',
                    style: NexText.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(height: NexSpace.md),
            NexCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('GƏLİRLƏR', style: NexText.overline),
                  const SizedBox(height: NexSpace.sm),
                  _ToggleRow(
                    icon: Icons.record_voice_over_rounded,
                    title: 'Səsli xəbərdarlıq',
                    subtitle: '400 m və 150 m qaldıqda danışır',
                    value: settings.voiceEnabled,
                    onChanged: settings.setVoiceEnabled,
                  ),
                  const NexDivider(),
                  _ToggleRow(
                    icon: Icons.graphic_eq_rounded,
                    title: 'Bip səsləri',
                    subtitle: '500 m-də yumşaq, 200 m-də həyəcan siqnalı',
                    value: settings.beepEnabled,
                    onChanged: settings.setBeepEnabled,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NexSpace.xs),
      child: Row(
        children: <Widget>[
          NexIconBadge(icon: icon, color: NexColors.primary, size: 36),
          const SizedBox(width: NexSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: NexText.bodyStrong),
                Text(subtitle, style: NexText.caption),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _PermissionPage extends StatelessWidget {
  const _PermissionPage({
    required this.location,
    required this.notification,
    required this.overlay,
    required this.battery,
    required this.overlaySupported,
    required this.busy,
    required this.onRequestAll,
  });

  final bool location;
  final bool notification;
  final bool overlay;
  final bool battery;
  final bool overlaySupported;
  final bool busy;
  final Future<void> Function() onRequestAll;

  @override
  Widget build(BuildContext context) {
    final int granted = <bool>[
      location,
      notification,
      if (overlaySupported) overlay,
      if (overlaySupported) battery,
    ].where((bool v) => v).length;
    final int total = overlaySupported ? 4 : 2;

    return _PageShell(
      scrollable: true,
      children: <Widget>[
        const SizedBox(height: NexSpace.xxl),
        Text('İcazələr', style: NexText.h1),
        const SizedBox(height: NexSpace.xs),
        Text(
          'NexRadar arxa fonda işlədiyi üçün bu icazələr vacibdir. '
          'Hamısı yalnız bu cihazda istifadə olunur.',
          style: NexText.body,
        ),
        const SizedBox(height: NexSpace.md),
        Row(
          children: <Widget>[
            StatusPill(
              label: '$granted / $total verildi',
              color: granted == total ? NexColors.primary : NexColors.amber,
              icon: granted == total
                  ? Icons.verified_rounded
                  : Icons.pending_outlined,
            ),
          ],
        ),
        const SizedBox(height: NexSpace.md),
        _PermTile(
          icon: Icons.my_location_rounded,
          title: 'Konum (GPS)',
          subtitle: 'Sürəti ölçmək və radarları tapmaq üçün zəruridir. '
              '"Həmişə icazə ver" seçsən arxa fonda da işləyir.',
          granted: location,
          mandatory: true,
        ),
        const SizedBox(height: NexSpace.sm),
        _PermTile(
          icon: Icons.notifications_active_rounded,
          title: 'Bildirişlər',
          subtitle: 'Xidmətin arxa fonda yaşaması üçün zəruri bildiriş.',
          granted: notification,
          mandatory: true,
        ),
        if (overlaySupported) ...<Widget>[
          const SizedBox(height: NexSpace.sm),
          _PermTile(
            icon: Icons.layers_rounded,
            title: 'Digər tətbiqlərin üzərində göstər',
            subtitle: 'Yüzen baloncuq üçün. Xəritə açıq olsa da görünür.',
            granted: overlay,
          ),
          const SizedBox(height: NexSpace.sm),
          _PermTile(
            icon: Icons.battery_saver_rounded,
            title: 'Batareya optimallaşdırmasını söndür',
            subtitle: 'Bəzi telefonlar arxa fon xidmətini bağlayır. '
                'Bunu söndürsən baloncuk sabit qalır.',
            granted: battery,
          ),
        ],
        const SizedBox(height: NexSpace.lg),
        Center(
          child: TextButton.icon(
            onPressed: busy ? null : () => onRequestAll(),
            icon: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.lock_open_rounded, size: 18),
            label: const Text('Bütün icazələri istə'),
          ),
        ),
      ],
    );
  }
}

class _PermTile extends StatelessWidget {
  const _PermTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.granted,
    this.mandatory = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool granted;
  final bool mandatory;

  @override
  Widget build(BuildContext context) {
    return NexCard(
      accent: granted ? NexColors.primary : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NexIconBadge(
            icon: granted ? Icons.check_rounded : icon,
            color: granted ? NexColors.primary : NexColors.textMid,
            size: 40,
          ),
          const SizedBox(width: NexSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(child: Text(title, style: NexText.bodyStrong)),
                    if (mandatory && !granted) ...<Widget>[
                      const SizedBox(width: 6),
                      Text(
                        'ZƏRURİ',
                        style: NexText.overline.copyWith(
                          fontSize: 9,
                          color: NexColors.amber,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: NexText.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.page,
    required this.count,
    required this.label,
    required this.busy,
    required this.onNext,
    this.onSkip,
  });

  final int page;
  final int count;
  final String label;
  final bool busy;
  final VoidCallback onNext;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NexSpace.xl,
        NexSpace.sm,
        NexSpace.xl,
        NexSpace.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List<Widget>.generate(count, (int i) {
              final bool active = i == page;
              return AnimatedContainer(
                duration: NexMotion.base,
                curve: NexMotion.emphasized,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: active ? 26 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: active ? NexColors.primary : NexColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          ),
          const SizedBox(height: NexSpace.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: busy ? null : onNext,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(label),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(height: NexSpace.xs),
          SizedBox(
            height: 34,
            child: onSkip == null
                ? null
                : TextButton(
                    onPressed: onSkip,
                    child: const Text('İndi yox, sonra'),
                  ),
          ),
        ],
      ),
    );
  }
}
