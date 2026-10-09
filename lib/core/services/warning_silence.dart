import 'package:flutter/foundation.dart';

/// The **Sükut** (silence) window: warnings muted on purpose, for a bounded time.
///
/// Why this is a value object instead of a boolean and a timestamp: silence has
/// exactly one interesting behaviour — it *expires* — and every actor that asks
/// about it must get the same answer. The alert ladder, the lock-screen media
/// panel (which prints the countdown), the floating bubble, the diagnostics
/// screen and the settings switch all read this one class, and the arithmetic is
/// pure, so the rules can be tested without a device or a clock.
///
/// The window is deliberately **bounded**. A radar app that can be muted forever
/// is a radar app that a driver will one day drive blind with: mute it in traffic
/// to answer a passenger, forget, and the rest of the trip is silent with no
/// visible symptom. Five minutes is long enough to be useful (a phone call, a
/// conversation, a drive-through) and short enough that the radar always comes
/// back on its own — and the lock screen shows the remaining time while it does.
@immutable
class WarningSilence {
  const WarningSilence._(this.pausedAt);

  /// Warnings are live:
  static const WarningSilence off = WarningSilence._(null);

  /// Warnings muted as of [at] — the moment the driver asked for it.
  factory WarningSilence.startingAt(DateTime at) => WarningSilence._(at);

  /// When the driver asked for silence, or null while warnings are live.
  final DateTime? pausedAt;

  bool get isActive => pausedAt != null;

  /// How long a silence lasts before the radar speaks up again.
  static const Duration window = Duration(minutes: 5);

  /// The instant the window closes, or null while warnings are live.
  ///
  /// A clock that jumped backwards (timezone change, manual set) can push
  /// [pausedAt] into the future, which would stretch the window: the remaining
  /// time is therefore clamped to [window] everywhere below.
  DateTime? endsAt() => pausedAt?.add(window);

  /// Whole seconds left, clamped to `[0, window]`.
  int remainingSeconds(DateTime now) {
    final DateTime? end = endsAt();
    if (end == null) return 0;
    final int seconds = end.difference(now).inSeconds;
    if (seconds < 0) return 0;
    final int ceiling = window.inSeconds;
    return seconds > ceiling ? ceiling : seconds;
  }

  /// True once the window has run out (or when warnings are live at all).
  bool isExpired(DateTime now) {
    final DateTime? end = endsAt();
    if (end == null) return false;
    return !now.isBefore(end);
  }

  /// This silence with an expired window dropped.
  ///
  /// A cold start, a resumed engine and a late auto-resume timer all end up
  /// applying this, which is what makes "the driver forgot" self-healing even
  /// after the process was killed.
  WarningSilence normalised(DateTime now) => isExpired(now) ? off : this;

  /// Epoch millis the window closes at, or 0 while warnings are live — the value
  /// the native lock-screen panel counts down from.
  int endsAtMillis(DateTime now) =>
      isActive ? endsAt()!.millisecondsSinceEpoch : 0;

  /// `4:12` — what the notification, the bubble's chip and the diagnostics screen
  /// print.
  String countdownLabel(DateTime now) {
    final int seconds = remainingSeconds(now);
    final int minutes = seconds ~/ 60;
    final int rest = seconds % 60;
    return '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  @override
  bool operator ==(Object other) =>
      other is WarningSilence && other.pausedAt == pausedAt;

  @override
  int get hashCode => pausedAt?.hashCode ?? 0;

  @override
  String toString() =>
      isActive ? 'WarningSilence(until ${endsAt()})' : 'WarningSilence.off';
}
