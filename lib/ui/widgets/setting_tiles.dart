import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'surfaces.dart';

/// A titled group of settings rows, rendered as one card with hairline
/// separators. This is the only layout the settings page uses, which is what
/// makes the page scan vertically without effort.
class SettingGroup extends StatelessWidget {
  const SettingGroup({
    super.key,
    required this.title,
    required this.children,
    this.footer,
  });

  final String title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      if (i > 0) rows.add(const NexDivider(indent: 62));
      rows.add(children[i]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionHeader(
          title: title,
          padding: const EdgeInsets.fromLTRB(4, NexSpace.xl, 4, NexSpace.xs),
        ),
        NexCard(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(children: rows),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, NexSpace.xs, 6, 0),
            child: Text(footer!, style: NexText.caption),
          ),
      ],
    );
  }
}

/// A settings row: icon badge, title, subtitle and a trailing widget.
class SettingTile extends StatelessWidget {
  const SettingTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.accent = NexColors.textMid,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color accent;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color tone = danger ? NexColors.danger : accent;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NexSpace.md,
          vertical: NexSpace.sm,
        ),
        child: Row(
          children: <Widget>[
            NexIconBadge(icon: icon, color: tone, size: 36),
            const SizedBox(width: NexSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: NexText.bodyStrong.copyWith(
                      color: danger ? NexColors.danger : NexColors.textHigh,
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: NexText.caption),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: NexSpace.xs),
              trailing!,
            ] else if (onTap != null)
              const Icon(
                Icons.chevron_right_rounded,
                color: NexColors.textLow,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}

/// The lock-screen HUD row.
///
/// Android hides every ordinary overlay window the moment the keyguard comes up,
/// so the lock-screen bubble is drawn by an accessibility window instead. That
/// grant can only be given in the system settings, which is why this row is a
/// deep link rather than a switch — the app can read the state but never set it.
class LockHudTile extends StatelessWidget {
  const LockHudTile({
    super.key,
    required this.granted,
    required this.active,
    required this.onTap,
  });

  /// NexRadar is switched on under Settings → Accessibility.
  final bool granted;

  /// The service is bound right now: the bubble is really above the keyguard.
  final bool active;

  /// Opens the system accessibility settings.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color tone = active
        ? NexColors.primary
        : (granted ? NexColors.amber : NexColors.textMid);

    return SettingTile(
      icon: active ? Icons.lock_rounded : Icons.lock_outline_rounded,
      title: 'Kilid ekranı HUD',
      subtitle: active
          ? 'Baloncuk kilid ekranının üstündə çəkilir'
          : granted
              ? 'İcazə verilib — baloncuk göstəriləndə aktivləşir'
              : 'Sürət, limit və məsafə üçün erişilebilirlik icazəsi ver',
      accent: tone,
      trailing: StatusPill(
        label: active ? 'AKTİV' : (granted ? 'HAZIR' : 'İCAZƏ VER'),
        color: tone,
        dense: true,
      ),
      onTap: onTap,
    );
  }
}

class SettingSwitch extends StatelessWidget {
  const SettingSwitch({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.accent = NexColors.primary,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      accent: accent,
      trailing: Switch(value: value, onChanged: onChanged),
      onTap: () => onChanged(!value),
    );
  }
}

/// A labelled slider with a live value readout and an explanatory hint.
class SettingSlider extends StatelessWidget {
  const SettingSlider({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
    this.subtitle,
    this.hint,
    this.accent = NexColors.primary,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? hint;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NexSpace.md,
        NexSpace.sm,
        NexSpace.md,
        NexSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              NexIconBadge(icon: icon, color: accent, size: 36),
              const SizedBox(width: NexSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: NexText.bodyStrong),
                    if (subtitle != null)
                      Text(subtitle!, style: NexText.caption),
                  ],
                ),
              ),
              const SizedBox(width: NexSpace.xs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: NexRadius.smAll,
                  border: Border.all(color: accent.withValues(alpha: 0.28)),
                ),
                child: Text(
                  display,
                  style: NexText.numericSmall.copyWith(
                    fontSize: 13,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
          if (hint != null)
            Text(hint!, style: NexText.caption.copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}
