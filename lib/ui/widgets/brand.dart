import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The NexRadar mark: a radar dish made of three arcs, a sweep needle and a
/// contact blip. Drawn with paths so it stays crisp at any size and needs no
/// raster asset.
class NexLogo extends StatelessWidget {
  const NexLogo({
    super.key,
    this.size = 44,
    this.color = NexColors.primary,
    this.background = true,
  });

  final double size;
  final Color color;
  final bool background;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _LogoPainter(color: color, background: background),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter({required this.color, required this.background});

  final Color color;
  final bool background;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = math.min(size.width, size.height);
    final Offset c = Offset(size.width / 2, size.height / 2);
    final Rect box = Rect.fromCenter(center: c, width: s, height: s);

    if (background) {
      final Paint bg = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            color.withValues(alpha: 0.20),
            color.withValues(alpha: 0.05),
          ],
        ).createShader(box);
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(s * 0.30)),
        bg,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(s * 0.30)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.34),
      );
    }

    final Offset origin = Offset(c.dx - s * 0.20, c.dy + s * 0.20);
    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s * 0.055
      ..color = color;

    // Three concentric sweeps, fading as they grow.
    for (int i = 1; i <= 3; i++) {
      arc.color = color.withValues(alpha: 0.95 - i * 0.22);
      canvas.drawArc(
        Rect.fromCircle(center: origin, radius: s * 0.16 * i),
        -math.pi / 2,
        math.pi / 2,
        false,
        arc,
      );
    }

    // Sweep needle at 45°.
    canvas.drawLine(
      origin,
      origin + Offset(s * 0.40, -s * 0.40) * 0.99,
      Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = s * 0.05
        ..color = color,
    );

    // Contact blip.
    canvas.drawCircle(
      origin + Offset(s * 0.22, -s * 0.26),
      s * 0.062,
      Paint()..color = color,
    );
    canvas.drawCircle(
      origin + Offset(s * 0.22, -s * 0.26),
      s * 0.12,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.028
        ..color = color.withValues(alpha: 0.45),
    );

    // Origin dot.
    canvas.drawCircle(origin, s * 0.045, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_LogoPainter old) =>
      old.color != color || old.background != background;
}

/// Brand lockup: mark + wordmark + tagline.
class NexWordmark extends StatelessWidget {
  const NexWordmark({
    super.key,
    this.size = 42,
    this.showTagline = true,
    this.tagline = 'Radar & sürət HUD',
  });

  final double size;
  final bool showTagline;
  final String tagline;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        NexLogo(size: size),
        const SizedBox(width: NexSpace.sm),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'NexRadar',
              style: NexText.h3.copyWith(
                fontSize: size * 0.42,
                letterSpacing: -0.6,
              ),
            ),
            if (showTagline)
              Text(
                tagline,
                style: NexText.caption.copyWith(fontSize: size * 0.25),
              ),
          ],
        ),
      ],
    );
  }
}

/// A continuously sweeping radar animation. Used on the onboarding hero and as
/// the backdrop of empty states so "nothing found" still feels alive.
class RadarSweep extends StatefulWidget {
  const RadarSweep({
    super.key,
    this.size = 220,
    this.color = NexColors.primary,
    this.active = true,
  });

  final double size;
  final Color color;
  final bool active;

  @override
  State<RadarSweep> createState() => _RadarSweepState();
}

class _RadarSweepState extends State<RadarSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant RadarSweep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, _) => CustomPaint(
          painter: _RadarSweepPainter(
            progress: _controller.value,
            color: widget.color,
          ),
        ),
      ),
    );
  }
}

class _RadarSweepPainter extends CustomPainter {
  _RadarSweepPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = math.min(size.width, size.height) / 2 - 2;

    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    for (int i = 1; i <= 4; i++) {
      ring.color = color.withValues(alpha: 0.16 - i * 0.022);
      canvas.drawCircle(center, radius * i / 4, ring);
    }

    // Cross hairs.
    ring.color = color.withValues(alpha: 0.10);
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      ring,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      ring,
    );

    // Sweep wedge.
    final double angle = progress * 2 * math.pi - math.pi / 2;
    final Paint wedge = Paint()
      ..shader = SweepGradient(
        startAngle: angle - math.pi * 0.5,
        endAngle: angle,
        colors: <Color>[
          color.withValues(alpha: 0.0),
          color.withValues(alpha: 0.34),
        ],
        transform: GradientRotation(angle - math.pi * 0.5),
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      angle - math.pi * 0.5,
      math.pi * 0.5,
      true,
      wedge,
    );

    // Leading edge + blip.
    canvas.drawLine(
      center,
      center + Offset(math.cos(angle), math.sin(angle)) * radius,
      Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.85),
    );
    canvas.drawCircle(center, 3.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RadarSweepPainter old) => old.progress != progress;
}
