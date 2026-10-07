import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/vehicle_state.dart';
import '../theme/app_theme.dart';
import '../theme/status_palette.dart';

/// The NexRadar speedometer.
///
/// A 270° dial with:
/// * a track arc and a bezel tick ring (precision-instrument cue),
/// * a gradient progress arc with a glowing head dot,
/// * a limit marker that rides the dial,
/// * a pulsing outer ring while inside the warning zone,
/// * a large tabular-figure readout that never jitters while counting.
///
/// The scale (how many km/h the full arc represents) is never hard-coded: it
/// derives from the active limit and glides to its new value when the limit
/// changes, so the needle stays in a comfortable range on both a 30 zone and a
/// motorway.
class SpeedGauge extends StatefulWidget {
  const SpeedGauge({
    super.key,
    required this.speedKmh,
    required this.limitKmh,
    required this.status,
    required this.mph,
    this.hasFix = true,
    this.size = 268,
    this.subtitle,
  });

  final double speedKmh;
  final int? limitKmh;
  final DrivingStatus status;
  final bool mph;
  final bool hasFix;
  final double size;

  /// Optional caption shown in the dial's bottom gap instead of the status.
  final String? subtitle;

  @override
  State<SpeedGauge> createState() => _SpeedGaugeState();
}

class _SpeedGaugeState extends State<SpeedGauge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
  );

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant SpeedGauge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _syncPulse();
  }

  void _syncPulse() {
    if (widget.status == DrivingStatus.warning) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  double get _value =>
      widget.mph ? widget.speedKmh / 1.609344 : widget.speedKmh;

  double? get _limitValue {
    final int? limit = widget.limitKmh;
    if (limit == null || limit <= 0) return null;
    return widget.mph ? limit / 1.609344 : limit.toDouble();
  }

  /// Rounds the dial ceiling to a tidy step so ticks stay legible and the scale
  /// only jumps on meaningful limit changes.
  double _referenceTarget() {
    final double base = _limitValue ?? (widget.mph ? 80 : 120);
    final double raw = math.max(base * 1.25, widget.mph ? 75 : 120);
    final double step = widget.mph ? 5 : 10;
    return (raw / step).ceil() * step;
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = StatusPalette.of(widget.status);
    final double size = widget.size;

    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(
          begin: _referenceTarget(),
          end: _referenceTarget(),
        ),
        duration: const Duration(milliseconds: 520),
        curve: NexMotion.emphasized,
        builder: (BuildContext context, double reference, _) {
          return TweenAnimationBuilder<Color?>(
            tween: ColorTween(begin: accent, end: accent),
            duration: NexMotion.slow,
            curve: NexMotion.ease,
            builder: (BuildContext context, Color? color, _) {
              return AnimatedBuilder(
                animation: _pulse,
                builder: (BuildContext context, _) {
                  final Color tone = color ?? accent;
                  return Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _GaugePainter(
                            value: _value,
                            reference: reference,
                            limitValue: _limitValue,
                            accent: tone,
                            pulse: _pulse.value,
                            warning: widget.status == DrivingStatus.warning,
                            approaching:
                                widget.status == DrivingStatus.approaching,
                            dimmed: !widget.hasFix,
                          ),
                        ),
                      ),
                      _Readout(
                        size: size,
                        value: _value,
                        unit: widget.mph ? 'mph' : 'km/s',
                        dimmed: !widget.hasFix,
                      ),
                      Positioned(
                        bottom: size * 0.045,
                        child: _DialCaption(
                          text: widget.subtitle ??
                              (widget.hasFix
                                  ? StatusPalette.label(widget.status)
                                  : 'GPS axtarılır…'),
                          color: widget.hasFix ? tone : NexColors.textLow,
                          muted: widget.status == DrivingStatus.idle ||
                              !widget.hasFix,
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Readout extends StatelessWidget {
  const _Readout({
    required this.size,
    required this.value,
    required this.unit,
    required this.dimmed,
  });

  final double size;
  final double value;
  final String unit;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // The readout sits slightly above the geometric centre so it clears the
        // caption in the arc gap.
        SizedBox(height: size * 0.09),
        Text(
          value.round().toString(),
          style: NexText.display.copyWith(
            fontSize: size * 0.335,
            color: dimmed
                ? NexColors.textHigh.withValues(alpha: 0.35)
                : NexColors.textHigh,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          unit,
          style: TextStyle(
            fontFamily: NexFont.text,
            fontSize: size * 0.052,
            fontWeight: FontWeight.w600,
            letterSpacing: 3.0,
            color: dimmed
                ? NexColors.textLow.withValues(alpha: 0.6)
                : NexColors.textLow,
          ),
        ),
      ],
    );
  }
}

class _DialCaption extends StatelessWidget {
  const _DialCaption({
    required this.text,
    required this.color,
    required this.muted,
  });

  final String text;
  final Color color;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: (muted ? NexColors.surfaceHigh : color).withValues(
          alpha: muted ? 0.85 : 0.16,
        ),
        borderRadius: NexRadius.pillAll,
        border: Border.all(
          color: muted
              ? NexColors.borderSoft
              : color.withValues(alpha: 0.42),
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: NexFont.text,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: muted ? NexColors.textMid : color,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.value,
    required this.reference,
    required this.limitValue,
    required this.accent,
    required this.pulse,
    required this.warning,
    required this.approaching,
    required this.dimmed,
  });

  final double value;
  final double reference;
  final double? limitValue;
  final Color accent;
  final double pulse;
  final bool warning;
  final bool approaching;
  final bool dimmed;

  static const double _startDeg = 135;
  static const double _sweepDeg = 270;

  double get _fraction =>
      reference <= 0 ? 0 : (value / reference).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = math.min(size.width, size.height) / 2;
    final double start = _startDeg * math.pi / 180;
    final double sweep = _sweepDeg * math.pi / 180;

    // ---- ambient glow behind the dial --------------------------------------
    final double glowStrength = dimmed ? 0.04 : (warning ? 0.16 : 0.09);
    canvas.drawCircle(
      center,
      radius * 0.94,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            accent.withValues(alpha: glowStrength),
            accent.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius * 0.94)),
    );

    // ---- bezel ticks --------------------------------------------------------
    const int tickCount = 28;
    final double tickBase = radius * 0.845;
    final Paint tickPaint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.6;
    for (int i = 0; i <= tickCount; i++) {
      final bool major = i % 4 == 0;
      final double t = i / tickCount;
      final double angle = start + sweep * t;
      final Offset dir = Offset(math.cos(angle), math.sin(angle));
      final double inner = tickBase;
      final double outer = tickBase + radius * (major ? 0.085 : 0.045);
      tickPaint
        ..color = major
            ? NexColors.white.withValues(alpha: dimmed ? 0.10 : 0.30)
            : NexColors.white.withValues(alpha: dimmed ? 0.05 : 0.13)
        ..strokeWidth = major ? 2.0 : 1.4;
      canvas.drawLine(center + dir * inner, center + dir * outer, tickPaint);
    }

    // ---- track arc ----------------------------------------------------------
    final double ringRadius = radius * 0.70;
    final double ringWidth = radius * 0.115;
    final Rect arcRect = Rect.fromCircle(center: center, radius: ringRadius);

    canvas.drawArc(
      arcRect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..strokeCap = StrokeCap.round
        ..color = NexColors.white.withValues(alpha: dimmed ? 0.05 : 0.075),
    );

    // ---- progress -----------------------------------------------------------
    final double fraction = _fraction;
    final double progressSweep = sweep * fraction;

    if (fraction > 0.001) {
      final Paint progress = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: start,
          endAngle: start + sweep,
          colors: <Color>[
            Color.alphaBlend(
              accent.withValues(alpha: 0.55),
              NexColors.surfaceHigh,
            ),
            accent.withValues(alpha: 0.85),
            accent,
          ],
          stops: const <double>[0.0, 0.55, 1.0],
          transform: GradientRotation(start),
        ).createShader(arcRect);

      // Halo pass (cheap glow: no blur filter needed).
      canvas.drawArc(
        arcRect,
        start,
        progressSweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth * 1.9
          ..strokeCap = StrokeCap.round
          ..color = accent.withValues(alpha: warning ? 0.20 : 0.12),
      );

      canvas.drawArc(arcRect, start, progressSweep, false, progress);

      // ---- glowing head dot -------------------------------------------------
      final double headAngle = start + progressSweep;
      final Offset head = center +
          Offset(math.cos(headAngle), math.sin(headAngle)) * ringRadius;
      canvas.drawCircle(
        head,
        ringWidth * 0.62,
        Paint()..color = accent.withValues(alpha: 0.30),
      );
      canvas.drawCircle(
        head,
        ringWidth * 0.40,
        Paint()..color = NexColors.white.withValues(alpha: 0.92),
      );
    }

    // ---- limit marker -------------------------------------------------------
    final double? limit = limitValue;
    if (limit != null && reference > 0) {
      final double limitFraction = (limit / reference).clamp(0.0, 1.0);
      final double angle = start + sweep * limitFraction;
      final Offset dir = Offset(math.cos(angle), math.sin(angle));
      final Offset a = center + dir * (ringRadius - ringWidth * 0.72);
      final Offset b = center + dir * (ringRadius + ringWidth * 0.72);
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = NexColors.white.withValues(alpha: 0.9)
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round,
      );
    }

    // ---- warning pulse ring -------------------------------------------------
    if (warning) {
      canvas.drawCircle(
        center,
        radius * (0.955 + 0.02 * pulse),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..color = accent.withValues(alpha: 0.18 + 0.32 * pulse),
      );
    } else if (approaching) {
      canvas.drawCircle(
        center,
        radius * 0.955,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = accent.withValues(alpha: 0.28),
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.value != value ||
      old.reference != reference ||
      old.limitValue != limitValue ||
      old.accent != accent ||
      old.pulse != pulse ||
      old.warning != warning ||
      old.approaching != approaching ||
      old.dimmed != dimmed;
}
