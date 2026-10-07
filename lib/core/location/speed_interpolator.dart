import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../constants/app_constants.dart';

/// Turns the 1 Hz GPS chip into a buttery 60 FPS needle.
///
/// The GPS chip emits a fix roughly once a second. Painting those raw values
/// directly makes the gauge jump. Instead we keep a *target* (the latest fix)
/// and chase it every frame with an exponential filter:
///
/// ```
/// current += (target - current) * (1 - e^(-dt / tau))
/// ```
///
/// The formula is frame-rate independent — the same [tauSeconds] behaves
/// identically at 60, 90 or 120 Hz — and it is C¹ continuous, so there is no
/// visible "snap" when a new fix arrives. This is the Dart twin of the native
/// overlay's interpolator, so the in-app gauge and the floating bubble always
/// agree.
class SpeedInterpolator {
  SpeedInterpolator({
    double tauSeconds = AppConstants.speedSmoothingTauSeconds,
    double maxKmh = AppConstants.maxDisplayKmh,
    double deadbandKmh = AppConstants.speedDeadbandKmh,
  })  : _tau = tauSeconds <= 0 ? AppConstants.speedSmoothingTauSeconds : tauSeconds,
        _max = maxKmh,
        _deadband = deadbandKmh;

  final double _tau;
  final double _max;
  final double _deadband;

  /// The value to paint. Listen with [ValueListenableBuilder] or attach it to a
  /// `AnimatedBuilder` for a ticker-driven rebuild.
  final ValueNotifier<double> display = ValueNotifier<double>(0);

  double _target = 0;

  double get target => _target;
  double get current => display.value;

  /// Feed a fresh GPS sample.
  void setTarget(double kmh) {
    _target = kmh.clamp(0.0, _max);
  }

  /// Jump straight to a value (used on first fix / after a long dropout) so the
  /// needle does not sweep up from zero.
  void snapTo(double kmh) {
    _target = kmh.clamp(0.0, _max);
    display.value = _target;
  }

  void reset() {
    _target = 0;
    display.value = 0;
  }

  /// Advance the filter. Call this once per frame with the elapsed *delta*
  /// (not the total elapsed time) — typically from a `Ticker`.
  void advance(double dtSeconds) {
    if (dtSeconds <= 0) return;

    // Clamp pathological deltas (debugger pauses, app resume) so the needle
    // never teleports.
    final double dt = dtSeconds > 0.25 ? 0.25 : dtSeconds;

    final double remaining = _target - display.value;

    // Snap once the outstanding error is smaller than a pixel of needle travel.
    // Checking this *first* matters: an exponential filter never reaches its
    // target, and a naive "only update if the change is visible" guard would
    // freeze the needle just short of it.
    if (remaining.abs() < 0.05) {
      if (display.value != _target) display.value = _target;
      return;
    }

    final double alpha = 1.0 - math.exp(-dt / _tau);
    double next = display.value + remaining * alpha;

    // Standstill deadband: both the filtered and the raw value are tiny.
    if (next < _deadband && _target < _deadband) next = 0;

    if (next != display.value) display.value = next;
  }

  bool get isSettled => (display.value - _target).abs() < 0.05;

  void dispose() => display.dispose();
}
