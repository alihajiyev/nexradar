import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/vehicle_state.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/theme/status_palette.dart';

/// The floating bubble, rendered in Flutter.
///
/// On Android the *production* bubble is drawn natively by `SpeedBubbleView.kt`
/// inside a `WindowManager` overlay — that is what keeps it on screen (and on
/// the lock screen) while the Flutter engine is paused.
///
/// This widget mirrors that design 1:1 and is used for:
/// * the live preview sheet, so the driver can check colours and size before
///   granting the overlay permission;
/// * the visual contract for the native view — if the two ever drift apart,
///   the preview shows it immediately.
///
/// It is fully interactive: drag it around, double-tap to cycle the size.
class FloatingRadarBubble extends StatefulWidget {
  const FloatingRadarBubble({
    super.key,
    required this.state,
    this.size = 168,
    this.showRemaining = true,
    this.useMph = false,
    this.onReportRadar,
    this.canvas,
  });

  final VehicleState state;
  final double size;
  final bool showRemaining;
  final bool useMph;
  final VoidCallback? onReportRadar;

  /// Side of the square the bubble can be dragged inside. Defaults to 1.7× the
  /// bubble side, which leaves a little grab room around it.
  ///
  /// This is a real size, not a hint: the widget owns its box so it can be
  /// dropped into a `Row` or a `Wrap` without a wrapping `SizedBox`.
  final double? canvas;

  @override
  State<FloatingRadarBubble> createState() => _FloatingRadarBubbleState();
}

class _FloatingRadarBubbleState extends State<FloatingRadarBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  double _scale = 1.0;
  Offset _offset = Offset.zero;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _syncBlink();
  }

  @override
  void didUpdateWidget(covariant FloatingRadarBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.status != widget.state.status) _syncBlink();
  }

  void _syncBlink() {
    if (widget.state.status == DrivingStatus.warning) {
      if (!_blink.isAnimating) _blink.repeat(reverse: true);
    } else {
      _blink.stop();
      _blink.value = 0;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  Color get _accent => StatusPalette.of(widget.state.status);

  void _cycleScale() {
    setState(() {
      if (_scale < 0.9) {
        _scale = 1.0;
      } else if (_scale < 1.1) {
        _scale = 1.25;
      } else {
        _scale = 0.78;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final double side = widget.size * _scale;
    final double canvas = widget.canvas ?? widget.size * 1.7;
    final bool mph = widget.useMph;
    final VehicleState state = widget.state;

    return SizedBox(
      width: canvas,
      height: canvas,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
        Positioned(
          left: _offset.dx,
          top: _offset.dy,
          child: GestureDetector(
            onPanStart: (_) => setState(() => _dragging = true),
            onPanUpdate: (DragUpdateDetails d) =>
                setState(() => _offset += d.delta),
            onPanEnd: (_) => setState(() => _dragging = false),
            onDoubleTap: _cycleScale,
            child: AnimatedBuilder(
              animation: _blink,
              builder: (BuildContext context, _) {
                final double flash =
                    state.status == DrivingStatus.warning ? _blink.value : 0;
                return AnimatedScale(
                  scale: _dragging ? 1.045 : 1.0,
                  duration: NexMotion.fast,
                  child: CustomPaint(
                    size: Size(side, side),
                    painter: _BubblePainter(
                      speedText: Fmt.speed(state.speedKmh, mph: mph),
                      unit: Fmt.unitLabel(mph: mph),
                      limit: state.speedLimit,
                      distance: state.threatDistanceMeters,
                      status: state.status,
                      accent: _accent,
                      flash: flash,
                      showRemaining: widget.showRemaining,
                      hasFix: state.hasFix,
                      bearingDelta: state.threatRelativeBearing,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
          if (widget.onReportRadar != null)
            Positioned(
              left: _offset.dx + side * 0.70,
              top: _offset.dy + side * 0.04,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onReportRadar,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: side * 0.22,
                    height: side * 0.22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: NexGradients.brand,
                      boxShadow:
                          NexShadow.glow(NexColors.primary, strength: 0.4),
                    ),
                    child: Icon(
                      Icons.add_rounded,
                      color: NexColors.primaryInk,
                      size: side * 0.14,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _BubblePainter extends CustomPainter {
  _BubblePainter({
    required this.speedText,
    required this.unit,
    required this.limit,
    required this.distance,
    required this.status,
    required this.accent,
    required this.flash,
    required this.showRemaining,
    required this.hasFix,
    required this.bearingDelta,
  });

  final String speedText;
  final String unit;
  final int? limit;
  final double? distance;
  final DrivingStatus status;
  final Color accent;
  final double flash;
  final bool showRemaining;
  final bool hasFix;

  /// Radar bearing relative to the car's nose: 0° = straight ahead.
  final double? bearingDelta;

  static const double _startDeg = 135;
  static const double _sweepDeg = 270;

  @override
  void paint(Canvas canvas, Size size) {
    final double side = math.min(size.width, size.height);
    // Geometry mirrors `SpeedBubbleView.kt` exactly: the two bubbles are the
    // same product and must not drift apart.
    final Offset center = Offset(size.width / 2, side * 0.415);
    final double radius = side * 0.355;
    final bool warning = status == DrivingStatus.warning;
    final bool idle = status == DrivingStatus.idle;

    // ---- ambient glow -------------------------------------------------------
    canvas.drawCircle(
      center,
      radius * 1.28,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            accent.withValues(alpha: idle ? 0.10 : 0.22 + 0.14 * flash),
            accent.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius * 1.28)),
    );

    // ---- glass body ---------------------------------------------------------
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.45, -0.6),
          radius: 1.15,
          colors: <Color>[
            Color.alphaBlend(
              accent.withValues(alpha: idle ? 0.14 : 0.26),
              const Color(0xFF0A1215),
            ),
            const Color(0xF20A1215),
            const Color(0xFA060B0D),
          ],
          stops: const <double>[0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = NexColors.white.withValues(alpha: 0.10),
    );

    // ---- state ring ---------------------------------------------------------
    if (!idle) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = side * 0.018
          ..color = accent.withValues(alpha: warning ? 0.35 + 0.55 * flash : 0.7),
      );
    }

    // ---- bezel ticks --------------------------------------------------------
    final double tickBase = radius * 1.02;
    for (int i = 0; i <= 27; i++) {
      final bool major = i % 4 == 0;
      final double angle = (135 + 270 * i / 27) * math.pi / 180;
      final Offset dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + dir * tickBase,
        center + dir * (tickBase + radius * (major ? 0.10 : 0.055)),
        Paint()
          ..color = NexColors.white.withValues(alpha: major ? 0.28 : 0.12)
          ..strokeWidth = major ? 1.6 : 1.1
          ..strokeCap = StrokeCap.round,
      );
    }

    // ---- gauge arc ----------------------------------------------------------
    final double arcR = radius * 0.80;
    final Rect arc = Rect.fromCircle(center: center, radius: arcR);
    final double start = _startDeg * math.pi / 180;
    final double sweep = _sweepDeg * math.pi / 180;
    final double stroke = side * 0.028;

    canvas.drawArc(
      arc,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke
        ..color = NexColors.white.withValues(alpha: 0.11),
    );

    final double shownSpeed = double.tryParse(speedText) ?? 0;
    final double reference = (limit == null || limit! <= 0)
        ? (unit == 'mph' ? 100 : 160)
        : limit!.toDouble();
    final double ceiling = math.max(reference * 1.25, unit == 'mph' ? 75 : 120);
    final double fraction = (shownSpeed / ceiling).clamp(0.0, 1.0);

    if (fraction > 0.001) {
      canvas.drawArc(
        arc,
        start,
        sweep * fraction,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke
          ..shader = SweepGradient(
            startAngle: start,
            endAngle: start + sweep,
            colors: <Color>[
              accent.withValues(alpha: 0.45),
              accent,
            ],
            transform: GradientRotation(start),
          ).createShader(arc),
      );

      final double headAngle = start + sweep * fraction;
      final Offset head = center +
          Offset(math.cos(headAngle), math.sin(headAngle)) * arcR;
      canvas.drawCircle(head, stroke * 0.42, Paint()..color = Colors.white);
    }

    // ---- limit tick ---------------------------------------------------------
    if (limit != null && limit! > 0) {
      final double limitFraction = (reference / ceiling).clamp(0.0, 1.0);
      final double angle = start + sweep * limitFraction;
      final Offset dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + dir * (arcR - stroke),
        center + dir * (arcR + stroke),
        Paint()
          ..color = NexColors.white.withValues(alpha: 0.85)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }

    // ---- readout ------------------------------------------------------------
    _text(
      canvas,
      speedText,
      center.translate(0, -radius * 0.05),
      radius * 0.86,
      hasFix ? NexColors.textHigh : NexColors.textHigh.withValues(alpha: 0.45),
      FontWeight.w800,
      family: NexFont.display,
      letterSpacing: -1.6,
    );
    _text(
      canvas,
      unit,
      center.translate(0, radius * 0.52),
      radius * 0.25,
      NexColors.textLow,
      FontWeight.w600,
      letterSpacing: 1.6,
    );

    // ---- limit sign ---------------------------------------------------------
    // A European-style speed-limit sign reads faster at a glance than the word
    // "Limit", and it is the one symbol every driver already knows.
    final bool hasLimit = limit != null && limit! > 0;
    if (hasLimit) {
      final Offset sign = Offset(side * 0.175, side * 0.815);
      final double signR = side * 0.115;
      canvas.drawCircle(
        sign,
        signR,
        Paint()..color = NexColors.white.withValues(alpha: 0.95),
      );
      canvas.drawCircle(
        sign,
        signR - signR * 0.15,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = signR * 0.30
          ..color = const Color(0xFFE12B3A),
      );
      final String limitText = Fmt.limit(kmh: limit, mph: unit == 'mph');
      _text(
        canvas,
        limitText,
        sign,
        signR * (limitText.length > 2 ? 0.88 : 1.12),
        const Color(0xFF10171A),
        FontWeight.w800,
        letterSpacing: -0.4,
      );
    }

    // ---- distance chip ------------------------------------------------------
    final Rect chip = Rect.fromLTRB(
      hasLimit ? side * 0.335 : side * 0.05,
      side * 0.715,
      side * 0.955,
      side * 0.915,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(chip, Radius.circular(chip.height / 2)),
      Paint()
        ..color = idle
            ? NexColors.surfaceHigh.withValues(alpha: 0.92)
            : accent.withValues(alpha: 0.24),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(chip, Radius.circular(chip.height / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = idle
            ? NexColors.borderSoft
            : accent.withValues(alpha: 0.47),
    );
    _text(
      canvas,
      _chipText(),
      chip.center,
      chip.height * 0.44,
      idle ? NexColors.textMid : NexColors.textHigh,
      FontWeight.w700,
    );

    // ---- bearing blip -------------------------------------------------------
    // Where the radar sits relative to the car's nose: 0° = straight up.
    final double? bearing = bearingDelta;
    if (bearing != null && distance != null) {
      final double angle = (bearing - 90) * math.pi / 180;
      final Offset blip = center +
          Offset(math.cos(angle), math.sin(angle)) * (radius * 1.16);
      canvas.drawCircle(
        blip,
        radius * 0.088,
        Paint()..color = const Color(0xFF060B0D).withValues(alpha: 0.86),
      );
      canvas.drawCircle(
        blip,
        radius * 0.068,
        Paint()..color = accent.withValues(alpha: 0.92),
      );
    }
  }

  /// The live remaining distance — the number the driver actually watches.
  String _chipText() {
    final double? d = distance;
    if (d == null) return unit == 'mph' ? 'MPH' : 'KM/S';
    if (!showRemaining && limit != null && limit! > 0) {
      return unit == 'mph' ? 'MPH' : 'KM/S';
    }
    return Fmt.distance(d);
  }

  void _text(
    Canvas canvas,
    String value,
    Offset center,
    double fontSize,
    Color color,
    FontWeight weight, {
    String? family,
    double letterSpacing = -0.4,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: weight,
          fontFamily: family,
          letterSpacing: letterSpacing,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 600);
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.speedText != speedText ||
      old.status != status ||
      old.limit != limit ||
      old.distance != distance ||
      old.flash != flash ||
      old.showRemaining != showRemaining ||
      old.hasFix != hasFix ||
      old.bearingDelta != bearingDelta;
}
