import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/services/update_service.dart';
import '../../main.dart';
import '../theme/app_theme.dart';
import '../theme/status_palette.dart';
import 'controls.dart';
import 'surfaces.dart';

/// The whole self-update flow, in one card.
///
/// States, in the order the driver sees them:
/// idle → checking → available → downloading (with a progress rail) → handing
/// the file to the system installer. Every failure is explained in place
/// instead of being swallowed, because "the update button does nothing" is the
/// worst possible outcome for an app that is side-loaded by hand.
class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key, required this.services});

  final AppServices services;

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

enum _Phase { idle, checking, downloading, handingOff }

class _UpdateCardState extends State<UpdateCard> {
  _Phase _phase = _Phase.idle;

  String _installed = '—';
  String? _message;
  ReleaseInfo? _release;
  double _progress = 0;

  /// Silent updates are possible only with Shizuku; it is checked once per
  /// build of this card and defaults to "not available".
  ShizukuState _shizuku = const ShizukuState();

  UpdateService get updates => widget.services.updates;

  @override
  void initState() {
    super.initState();
    _loadInstalled();
    unawaited(_loadShizuku());
  }

  Future<void> _loadShizuku() async {
    final ShizukuState state = await updates.shizukuState();
    if (!mounted) return;
    setState(() => _shizuku = state);
  }

  Future<void> _loadInstalled() async {
    final String version = await updates.installedVersion();
    if (!mounted) return;
    setState(() => _installed = version);
  }

  void _notify(String message) => widget.services.lastNotice.value = message;

  Future<void> _check() async {
    if (_phase != _Phase.idle) return;
    setState(() {
      _phase = _Phase.checking;
      _message = null;
    });
    final UpdateCheckResult result = await widget.services.checkForUpdates();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _release = result.hasUpdate ? result.release : null;
      _installed = result.installedVersion;
      _message = result.message;
    });
  }

  Future<void> _downloadAndInstall() async {
    final ReleaseInfo? release = _release;
    if (release == null || _phase != _Phase.idle) return;

    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _message = 'Endirilir: ${release.apkName} (${release.sizeLabel})';
    });

    try {
      final String path = await updates.download(
        release,
        onProgress: (double value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      if (!mounted) return;

      // The silent route is taken only when it is genuinely available; any
      // failure falls through to the installer rather than leaving the driver
      // with an error and no update.
      if (chooseInstallRoute(_shizuku) == InstallRoute.silent) {
        setState(() {
          _phase = _Phase.handingOff;
          _message = 'Sükutla quraşdırılır…';
        });
        final SilentInstallResult silent =
            await updates.installApkViaShizuku(path);
        if (!mounted) return;
        if (silent.ok) {
          setState(() {
            _phase = _Phase.idle;
            _message = 'Yeniləmə sükutla quraşdırıldı.';
          });
          _notify('Yeniləmə quraşdırıldı');
          return;
        }
        _notify('Sükutla quraşdırılmadı — qurşadırıcı açılır');
      }

      setState(() {
        _phase = _Phase.handingOff;
        _message = 'Qurşadırıcı açılır…';
      });

      final bool started = await updates.installApk(path);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _message = started
            ? 'Qurşadırıcıda "Qur" düyməsini təsdiqləyin.'
            : '"Naməlum mənbələrdən quraşdırma" icazəsini verin, sonra '
                'yenidən cəhd edin.';
      });
      if (!started) _notify('Quraşdırma icazəsi tələb olunur');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _message = 'Endirmə alınmadı: $e';
      });
      _notify('Güncəlləmə endirilə bilmədi');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ReleaseInfo? release = _release;
    final bool busy = _phase != _Phase.idle;

    return AnimatedBuilder(
      animation: widget.services.settings,
      builder: (BuildContext context, _) {
        final settings = widget.services.settings;
        return NexCard(
          accent: release != null ? NexColors.primary : null,
          glow: release != null,
          tintStrength: 0.06,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  NexIconBadge(
                    icon: release != null
                        ? Icons.system_update_alt_rounded
                        : Icons.verified_rounded,
                    color: release != null
                        ? NexColors.primary
                        : NexColors.textMid,
                    size: 42,
                  ),
                  const SizedBox(width: NexSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          release != null
                              ? 'Yeni sürüm: v${release.version}'
                              : 'Quraşdırılmış sürüm: v$_installed',
                          style: NexText.bodyStrong,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          release != null
                              ? release.headline
                              : 'Son yoxlama: '
                                  '${Fmt.ago(settings.lastUpdateCheck)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: NexText.caption,
                        ),
                      ],
                    ),
                  ),
                  if (release != null)
                    StatusPill(
                      dense: true,
                      label: release.sizeLabel,
                      color: NexColors.cyan,
                    ),
                ],
              ),

              if (_message != null) ...<Widget>[
                const SizedBox(height: NexSpace.sm),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(NexSpace.sm),
                  decoration: BoxDecoration(
                    color: NexColors.backgroundLift,
                    borderRadius: NexRadius.mdAll,
                    border: Border.all(color: NexColors.borderSoft),
                  ),
                  child: Text(
                    _message!,
                    style: NexText.caption.copyWith(color: NexColors.textMid),
                  ),
                ),
              ],

              if (_phase == _Phase.downloading) ...<Widget>[
                const SizedBox(height: NexSpace.sm),
                NexProgressRail(
                  value: _progress,
                  color: NexColors.primary,
                  height: 8,
                ),
                const SizedBox(height: 6),
                Text(
                  '${(_progress * 100).round()}%',
                  style: NexText.numericSmall.copyWith(
                    color: NexColors.primary,
                  ),
                ),
              ],

              const SizedBox(height: NexSpace.md),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: busy
                          ? null
                          : (release != null ? _downloadAndInstall : _check),
                      icon: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              release != null
                                  ? Icons.download_rounded
                                  : Icons.refresh_rounded,
                              size: 19,
                            ),
                      label: Text(
                        release != null
                            ? (_phase == _Phase.downloading
                                ? 'Endirilir…'
                                : 'Endir və quraşdır')
                            : (_phase == _Phase.checking
                                ? 'Yoxlanılır…'
                                : 'Yeniləməni yoxla'),
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 50),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: NexSpace.sm),
              const NexDivider(),
              const SizedBox(height: NexSpace.xs),

              _row(
                icon: Icons.autorenew_rounded,
                title: 'Açılışda avtomatik yoxla',
                subtitle: 'Hər dəfə tətbiq açılanda GitHub-a baxılır',
                trailing: Switch(
                  value: settings.autoUpdateCheck,
                  onChanged: settings.setAutoUpdateCheck,
                ),
              ),

              if (Platform.isAndroid)
                _row(
                  icon: Icons.security_rounded,
                  title: 'Quraşdırma icazəsi',
                  subtitle: 'APK quraşdırmaq üçün "naməlum mənbələr" icazəsi '
                      'lazımdır',
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: NexColors.textLow,
                    size: 20,
                  ),
                  onTap: updates.openInstallPermissionSettings,
                ),

              Padding(
                padding: const EdgeInsets.only(
                  top: NexSpace.xs,
                  left: NexSpace.xxs,
                ),
                child: Text(
                  'Mənbə: github.com/${updates.repoSlug}',
                  style: NexText.caption.copyWith(fontSize: 11),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: NexRadius.mdAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: NexSpace.xs),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: NexColors.textMid),
            const SizedBox(width: NexSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: NexText.bodyStrong.copyWith(fontSize: 13.5)),
                  Text(subtitle, style: NexText.caption.copyWith(fontSize: 11)),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
