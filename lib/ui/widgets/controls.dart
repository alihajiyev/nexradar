import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One option of a [Segmented] control.
class SegmentedOption<T> {
  const SegmentedOption({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// A pill-shaped segmented control with a sliding indicator.
///
/// Material's `SegmentedButton` is visually heavy for a dark HUD; this version
/// keeps the same affordance with a much lighter footprint.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.accent = NexColors.primary,
  }) : assert(options.length > 0);

  final List<SegmentedOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final int index = options.indexWhere((SegmentedOption<T> o) => o.value == value);
    final int active = index < 0 ? 0 : index;

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: NexColors.backgroundLift,
        borderRadius: NexRadius.pillAll,
        border: Border.all(color: NexColors.borderSoft),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double each = constraints.maxWidth / options.length;
          return Stack(
            children: <Widget>[
              AnimatedPositioned(
                duration: NexMotion.base,
                curve: NexMotion.emphasized,
                left: active * each,
                top: 0,
                bottom: 0,
                width: each,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    borderRadius: NexRadius.pillAll,
                    border: Border.all(color: accent.withValues(alpha: 0.42)),
                  ),
                ),
              ),
              Row(
                children: options.map((SegmentedOption<T> o) {
                  final bool selected = o.value == value;
                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onChanged(o.value),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            if (o.icon != null) ...<Widget>[
                              Icon(
                                o.icon,
                                size: 15,
                                color: selected ? accent : NexColors.textLow,
                              ),
                              const SizedBox(width: 6),
                            ],
                            Flexible(
                              child: Text(
                                o.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: NexFont.text,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: selected
                                      ? NexColors.textHigh
                                      : NexColors.textLow,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(growable: false),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Circular glass icon button used in headers and on top of cards.
class NexIconButton extends StatelessWidget {
  const NexIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.accent,
    this.size = 42,
    this.badge,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? accent;
  final double size;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final Color color = accent ?? NexColors.textMid;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Tooltip(
          message: tooltip ?? '',
          child: Material(
            color: NexColors.surfaceAlt,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(size * 0.34),
              side: const BorderSide(color: NexColors.borderSoft),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(
                  icon,
                  size: size * 0.48,
                  color: onPressed == null
                      ? NexColors.textLow.withValues(alpha: 0.4)
                      : color,
                ),
              ),
            ),
          ),
        ),
        if (badge != null)
          Positioned(right: -3, top: -3, child: badge!),
      ],
    );
  }
}

/// Vertical icon + label action. Used for the secondary actions on the
/// dashboard where a full button would steal attention from "start driving".
class NexActionTile extends StatelessWidget {
  const NexActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.accent = NexColors.textMid,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color accent;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    final Color tone = enabled ? accent : NexColors.textLow.withValues(alpha: 0.5);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: NexRadius.mdAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: NexSpace.xs,
            horizontal: NexSpace.xxs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AnimatedContainer(
                duration: NexMotion.fast,
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: enabled
                      ? tone.withValues(alpha: active ? 0.20 : 0.10)
                      : NexColors.surface,
                  border: Border.all(
                    color: enabled
                        ? tone.withValues(alpha: active ? 0.55 : 0.26)
                        : NexColors.borderSoft,
                  ),
                ),
                child: Icon(icon, size: 21, color: tone),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: NexFont.text,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: enabled ? NexColors.textMid : NexColors.textLow,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rounded progress rail used for "distance to threat" and similar values.
class NexProgressRail extends StatelessWidget {
  const NexProgressRail({
    super.key,
    required this.value,
    required this.color,
    this.height = 6,
  });

  /// 0…1
  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Stack(
        children: <Widget>[
          Container(height: height, color: NexColors.surfaceHigh),
          FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            child: AnimatedContainer(
              duration: NexMotion.base,
              height: height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(height),
                gradient: LinearGradient(
                  colors: <Color>[color.withValues(alpha: 0.55), color],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
