import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The workhorse container: a gradient card with a hairline border, an optional
/// accent tint/glow and an optional tap target.
///
/// Everything visual about a "card" in NexRadar is decided here so the
/// dashboard, the radar list and the settings page can never drift apart.
class NexCard extends StatelessWidget {
  const NexCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(NexSpace.md),
    this.margin = EdgeInsets.zero,
    this.accent,
    this.onTap,
    this.radius = NexRadius.lg,
    this.glow = false,
    this.clip = true,
    this.tintStrength = 0.06,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  /// Tints the border/fill and (when [glow]) the shadow.
  final Color? accent;
  final VoidCallback? onTap;
  final double radius;
  final bool glow;
  final bool clip;
  final double tintStrength;

  @override
  Widget build(BuildContext context) {
    final BorderRadius shape = BorderRadius.circular(radius);
    final Color? accent = this.accent;

    Widget inner = Padding(padding: padding, child: child);

    if (onTap != null) {
      inner = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: shape,
          splashColor: (accent ?? NexColors.primary).withValues(alpha: 0.08),
          highlightColor: (accent ?? NexColors.primary).withValues(alpha: 0.05),
          child: inner,
        ),
      );
    }

    final List<Color> fill = accent == null
        ? const <Color>[NexColors.surfaceAlt, NexColors.surface]
        : <Color>[
            Color.alphaBlend(
              accent.withValues(alpha: tintStrength),
              NexColors.surfaceAlt,
            ),
            Color.alphaBlend(
              accent.withValues(alpha: tintStrength * 0.4),
              NexColors.surface,
            ),
          ];

    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: shape,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: fill,
          ),
          border: Border.all(
            color: accent?.withValues(alpha: 0.32) ?? NexColors.borderSoft,
          ),
          boxShadow: glow
              ? NexShadow.glow(accent ?? NexColors.primary, strength: 0.30)
              : NexShadow.card,
        ),
        child: ClipRRect(
          borderRadius: shape,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(gradient: NexGradients.sheen),
                  ),
                ),
              ),
              inner,
            ],
          ),
        ),
      ),
    );
  }
}

/// Uppercase eyebrow + optional trailing action, used above every card group.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(4, NexSpace.xl, 4, NexSpace.xs),
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(title.toUpperCase(), style: NexText.overline),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Small rounded status chip: a dot plus a label.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.dense = false,
    this.filled = false,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool dense;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? NexSpace.xs : NexSpace.sm,
        vertical: dense ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: filled ? 0.20 : 0.10),
        borderRadius: NexRadius.pillAll,
        border: Border.all(color: color.withValues(alpha: 0.34)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: dense ? 12 : 14, color: color),
            const SizedBox(width: 6),
          ] else ...<Widget>[
            Container(
              width: dense ? 6 : 7,
              height: dense ? 6 : 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
          ],
          Text(
            label,
            style: TextStyle(
              fontFamily: NexFont.text,
              fontSize: dense ? 11 : 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// A number with a caption under it — the dashboard's currency.
class StatBlock extends StatelessWidget {
  const StatBlock({
    super.key,
    required this.value,
    required this.label,
    this.accent,
    this.icon,
    this.align = CrossAxisAlignment.start,
  });

  final String value;
  final String label;
  final Color? accent;
  final IconData? icon;
  final CrossAxisAlignment align;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: align,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 14, color: accent ?? NexColors.textLow),
              const SizedBox(width: 6),
            ],
            Text(
              value,
              style: NexText.numeric.copyWith(
                color: accent ?? NexColors.textHigh,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(label, style: NexText.caption),
      ],
    );
  }
}

/// Boxed icon used as a leading element on settings rows and radar rows.
class NexIconBadge extends StatelessWidget {
  const NexIconBadge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 40,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.32),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Icon(icon, size: size * 0.5, color: color),
    );
  }
}

/// Thin divider that respects the design's hairline colour.
class NexDivider extends StatelessWidget {
  const NexDivider({super.key, this.indent = 0, this.endIndent = 0});

  final double indent;
  final double endIndent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent, right: endIndent),
      child: const Divider(height: 1, color: NexColors.borderSoft),
    );
  }
}
