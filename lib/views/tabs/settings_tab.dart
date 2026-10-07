import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/database/db_helper.dart';
import '../../core/services/osm_sync_service.dart';
import '../../main.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/theme/status_palette.dart';
import '../../ui/widgets/app_header.dart';
import '../../ui/widgets/brand.dart';
import '../../ui/widgets/controls.dart';
import '../../ui/widgets/setting_tiles.dart';
import '../../ui/widgets/surfaces.dart';
import '../../ui/widgets/update_card.dart';

/// Settings, grouped by the question the driver is asking rather than by the
/// implementation: sound, display, detection, overlay, community, data.
class SettingsTab extends StatefulWidget {
  const SettingsTab({
    super.key,
    required this.services,
    required this.onOpenRadars,
  });

  final AppServices services;
  final VoidCallback onOpenRadars;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> with WidgetsBindingObserver {
  late final TextEditingController _firebaseController;
  int _cameraCount = 0;
  int _temporaryCount = 0;
  bool _busy = false;

  /// Lock-screen HUD: granted in the system settings, and actually drawing.
  bool _lockHudEnabled = false;
  bool _lockHudActive = false;

  AppServices get services => widget.services;

  @override
  void initState() {
    super.initState();
    _firebaseController =
        TextEditingController(text: services.settings.firebaseUrl);
    _refreshCounts();
    WidgetsBinding.instance.addObserver(this);
    _refreshLockHud();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _firebaseController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from Settings → Accessibility is the only way this grant can
    // change, so re-read it rather than trusting a cached value.
    if (state == AppLifecycleState.resumed) _refreshLockHud();
  }

  Future<void> _refreshLockHud() async {
    final bool enabled = await services.overlay.lockHudEnabled();
    final bool active = await services.overlay.lockHudActive();
    if (!mounted) return;
    if (enabled == _lockHudEnabled && active == _lockHudActive) return;
    setState(() {
      _lockHudEnabled = enabled;
      _lockHudActive = active;
    });
  }

  Future<void> _openLockHudSettings() async {
    await services.overlay.openLockHudSettings();
    await _refreshLockHud();
  }

  Future<void> _refreshCounts() async {
    final int total = await services.repository.count();
    final int temporary = await services.repository.countTemporary();
    if (!mounted) return;
    setState(() {
      _cameraCount = total;
      _temporaryCount = temporary;
    });
  }

  void _notify(String message) => services.lastNotice.value = message;

  Future<void> _sync() async {
    setState(() => _busy = true);
    final SyncResult result = await services.engine.syncOsmCameras();
    await _refreshCounts();
    if (!mounted) return;
    setState(() => _busy = false);
    _notify(result.message);
  }

  Future<void> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    required Future<void> Function() action,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Ləğv et'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: NexColors.danger,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 42),
            ),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (ok == true) await action();
  }

  Future<void> _pickLanguage() async {
    final String current = services.settings.language;
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  NexSpace.lg,
                  NexSpace.xs,
                  NexSpace.lg,
                  NexSpace.xs,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Səs dili', style: NexText.h3),
                ),
              ),
              for (final (String code, String label) in _languages)
                ListTile(
                  title: Text(label),
                  trailing: code == current
                      ? const Icon(
                          Icons.check_circle_rounded,
                          color: NexColors.primary,
                        )
                      : null,
                  onTap: () => Navigator.of(context).pop(code),
                ),
              const SizedBox(height: NexSpace.sm),
            ],
          ),
        );
      },
    );
    if (picked != null) await services.settings.setLanguage(picked);
  }

  static const List<(String, String)> _languages = <(String, String)>[
    ('az-AZ', 'Azərbaycan dili'),
    ('tr-TR', 'Türkçe'),
    ('ru-RU', 'Русский'),
    ('en-US', 'English'),
  ];

  static String _languageName(String code) {
    for (final (String, String) entry in _languages) {
      if (entry.$1 == code) return entry.$2;
    }
    return 'English';
  }

  @override
  Widget build(BuildContext context) {
    final s = services.settings;

    return SafeArea(
      bottom: false,
      child: AnimatedBuilder(
        animation: s,
        builder: (BuildContext context, _) {
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
                subtitle: 'NexRadar v${AppConstants.appVersion}',
                leading: NexLogo(size: 42),
              ),

              // ------------------------------------------------------- sound
              SettingGroup(
                title: 'Səs və anons',
                children: <Widget>[
                  SettingSwitch(
                    icon: Icons.record_voice_over_rounded,
                    title: 'Səsli xəbərdarlıq',
                    subtitle: '400 m və 150 m qaldıqda danışır',
                    value: s.voiceEnabled,
                    onChanged: s.setVoiceEnabled,
                  ),
                  SettingTile(
                    icon: Icons.translate_rounded,
                    title: 'Dil',
                    subtitle: '${_languageName(s.language)} · aktiv səs: '
                        '${services.tts.effectiveLanguage}',
                    accent: NexColors.cyan,
                    onTap: _pickLanguage,
                  ),
                  SettingSwitch(
                    icon: Icons.graphic_eq_rounded,
                    title: 'Bip səsləri',
                    subtitle: '500 m-də yumşaq, 200 m-də həyəcan siqnalı',
                    value: s.beepEnabled,
                    onChanged: s.setBeepEnabled,
                  ),
                  SettingTile(
                    icon: Icons.play_circle_outline_rounded,
                    title: 'Səsi sına',
                    subtitle: 'Nümunə anonsu oxuyur',
                    accent: NexColors.amber,
                    onTap: () => services.tts.announceCameraAhead(
                      limitKmh: 80,
                      distanceMeters: 400,
                    ),
                  ),
                ],
              ),

              // ----------------------------------------------------- display
              SettingGroup(
                title: 'Göstəriş',
                children: <Widget>[
                  SettingTile(
                    icon: Icons.straighten_rounded,
                    title: 'Sürət vahidi',
                    subtitle: 'Göstərici və baloncuk üçün',
                    trailing: SizedBox(
                      width: 124,
                      child: Segmented<bool>(
                        value: s.useMph,
                        onChanged: (bool v) => s.setUseMph(v),
                        options: const <SegmentedOption<bool>>[
                          SegmentedOption<bool>(value: false, label: 'km/s'),
                          SegmentedOption<bool>(value: true, label: 'mph'),
                        ],
                      ),
                    ),
                  ),
                  SettingSwitch(
                    icon: Icons.straighten_outlined,
                    title: 'Baloncukda qalan məsafə',
                    subtitle: 'Limit ilə birlikdə "350 m" göstərilir',
                    value: s.showRemaining,
                    onChanged: s.setShowRemaining,
                  ),
                ],
              ),

              // --------------------------------------------------- detection
              SettingGroup(
                title: 'Radar aşkarlama',
                footer: 'Açısal filtr qarşı şeridi və perpendikulyar küçələri '
                    'süzgəcdən keçirir: böyük dəyər = daha çox xəbərdarlıq, '
                    'kiçik dəyər = yalnız öz istiqamətin.',

                children: <Widget>[
                  SettingSlider(
                    icon: Icons.screen_rotation_alt_rounded,
                    title: 'Açısal filtr',
                    subtitle: 'θ_heading − θ_radar',
                    value: s.angularTolerance,
                    min: 15,
                    max: 90,
                    divisions: 15,
                    display: '${s.angularTolerance.round()}°',
                    accent: NexColors.amber,
                    onChanged: s.setAngularTolerance,
                  ),
                  const SettingTile(
                    icon: Icons.radar_rounded,
                    title: 'Radar ufqu: 5 km',
                    subtitle: 'NexRadar həmişə düz 5 km qabağa baxır və '
                        'ən yaxın radarı göstərir — nə az, nə çox.',
                    accent: NexColors.cyan,
                    trailing: StatusPill(
                      label: 'SABİT',
                      color: NexColors.cyan,
                      dense: true,
                    ),
                  ),
                ],
              ),

              // ----------------------------------------------------- overlay
              SettingGroup(
                title: 'Yüzen baloncuk',
                children: <Widget>[
                  SettingSwitch(
                    icon: s.overlayEnabled
                        ? Icons.layers_rounded
                        : Icons.layers_outlined,
                    title: 'Baloncuğu göstər',
                    subtitle: services.overlay.isSupported
                        ? 'Digər tətbiqlərin üzərində və kilid ekranında görünür'
                        : 'Yalnız Android dəstəklənir',
                    value: s.overlayEnabled,
                    onChanged: (bool v) =>
                        services.setOverlayEnabled(v),
                  ),
                  SettingSlider(
                    icon: Icons.photo_size_select_small_rounded,
                    title: 'Baloncuk ölçüsü',
                    value: s.overlayScale,
                    min: 0.7,
                    max: 1.6,
                    divisions: 18,
                    display: '${(s.overlayScale * 100).round()}%',
                    hint: 'Baloncukda iki dəfə toxunaraq da dəyişə bilərsən.',
                    onChanged: (double v) {
                      s.setOverlayScale(v);
                      services.overlay.setScale(v);
                    },
                  ),
                ],
              ),

              // ------------------------------------------------ lock screen
              // Android hides every ordinary overlay window as soon as the
              // keyguard comes up, so the lock-screen bubble is drawn by a
              // dedicated accessibility window instead. That grant can only be
              // given in the system settings, hence the deep link.
              SettingGroup(
                title: 'Kilid ekranı',
                footer: 'Kilid ekranında sürət, sürət limiti və radara qalan '
                    'məsafə hər zaman görünür. HUD üçün icazə verilməyibsə, '
                    'rəsmi bildiriş kartı eyni məlumatı göstərir.',
                children: <Widget>[
                  LockHudTile(
                    granted: _lockHudEnabled,
                    active: _lockHudActive,
                    onTap: _openLockHudSettings,
                  ),
                ],
              ),

              // --------------------------------------------------- community
              SettingGroup(
                title: 'Topluluk',
                footer: 'Ünvan boş qalsa bildirişlər yalnız bu cihazda '
                    'saxlanılır və şəbəkə olduqda göndərilir.',
                children: <Widget>[
                  SettingTile(
                    icon: Icons.public_rounded,
                    title: 'Firebase Realtime Database URL',
                    subtitle: s.firebaseUrl.isEmpty
                        ? 'Konfiqurasiya edilməyib — yalnız yerli rejim'
                        : s.firebaseUrl,
                    accent: NexColors.cyan,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      NexSpace.md,
                      0,
                      NexSpace.md,
                      NexSpace.sm,
                    ),
                    child: Column(
                      children: <Widget>[
                        TextField(
                          controller: _firebaseController,
                          decoration: const InputDecoration(
                            hintText: 'https://your-app.firebaseio.com',
                          ),
                          onSubmitted: (String v) =>
                              services.settings.setFirebaseUrl(v),
                        ),
                        const SizedBox(height: NexSpace.xs),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: FilledButton.tonal(
                                onPressed: () async {
                                  await services.settings
                                      .setFirebaseUrl(_firebaseController.text);
                                  if (!context.mounted) return;
                                  _notify('Ünvan yadda saxlanıldı');
                                },
                                child: const Text('Yadda saxla'),
                              ),
                            ),
                            const SizedBox(width: NexSpace.xs),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () async {
                                  await services.crowd.flushPendingQueue();
                                  if (!context.mounted) return;
                                  _notify('Gözləyən bildirişlər göndərildi');
                                },
                                child: const Text('Növbəni göndər'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // -------------------------------------------------------- data
              SettingGroup(
                title: 'Verilənlər bazası',
                children: <Widget>[
                  SettingTile(
                    icon: Icons.storage_rounded,
                    title: '$_cameraCount radar yaddaşda',
                    subtitle: '$_temporaryCount topluluk bildirişi · '
                        'son sinxronizasiya: '
                        '${Fmt.ago(s.lastSync)}',
                    accent: NexColors.primary,
                    onTap: widget.onOpenRadars,
                  ),
                  SettingSlider(
                    icon: Icons.zoom_out_map_rounded,
                    title: 'Sinxronizasiya radiusu',
                    subtitle: 'Overpass API-dən yüklənən ərazi',
                    value: s.syncRadius,
                    min: 2000,
                    max: AppConstants.maxSyncRadiusMeters,
                    divisions: 29,
                    display: '${(s.syncRadius / 1000).toStringAsFixed(0)} km',
                    accent: NexColors.amber,
                    onChanged: s.setSyncRadius,
                  ),
                  SettingTile(
                    icon: Icons.cloud_download_outlined,
                    title: 'OSM-dən yenilə',
                    subtitle: _busy ? 'Sorğu göndərilir…' : 'Radarları indi yüklə',
                    accent: NexColors.cyan,
                    trailing: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: _busy ? null : _sync,
                  ),
                  SettingTile(
                    icon: Icons.cleaning_services_outlined,
                    title: 'Vaxtı keçmiş bildirişləri sil',
                    subtitle: 'İki saatdan köhnə topluluk bildirişləri',
                    onTap: () async {
                      final int removed = await services.crowd.purgeExpired();
                      await _refreshCounts();
                      if (!mounted) return;
                      _notify('$removed bildiriş silindi');
                    },
                  ),
                  SettingTile(
                    icon: Icons.delete_sweep_outlined,
                    title: 'Yerli keşi təmizlə',
                    subtitle: 'Bütün radarlar və gözləyən bildirişlər silinir',
                    danger: true,
                    onTap: () => _confirm(
                      title: 'Keşi təmizləyək?',
                      body: 'Yaddaşdaki bütün radarlar və göndərilməmiş '
                          'bildirişlər silinəcək. Bu əməliyyat geri '
                          'qaytarıla bilməz.',
                      confirmLabel: 'Sil',
                      action: () async {
                        await DbHelper.instance.wipe();
                        await _refreshCounts();
                        if (!mounted) return;
                        _notify('Yerli keş təmizləndi');
                      },
                    ),
                  ),
                ],
              ),

              // ----------------------------------------------------- updates
              const SectionHeader(title: 'Yeniləmə'),
              UpdateCard(services: services),

              // ------------------------------------------------------- about
              SettingGroup(
                title: 'Haqqında',
                children: <Widget>[
                  const SettingTile(
                    icon: Icons.info_outline_rounded,
                    title: '${AppConstants.appName} v${AppConstants.appVersion}',
                    subtitle: 'Arxa fonda işləyən radar & sürət HUD · '
                        'Android MVP',
                  ),
                  SettingTile(
                    icon: Icons.favorite_outline_rounded,
                    title: 'Məlumat mənbələri',
                    subtitle: 'OpenStreetMap (Overpass API) və sürücü '
                        'bildirişləri. Xəbərdarlıqlar köməkçidir — '
                        'yol nişanlarına həmişə etibar et.',
                    accent: NexColors.danger,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
