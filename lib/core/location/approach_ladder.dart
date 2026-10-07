import '../constants/app_constants.dart';

/// The approach ladder — 1 km, then 500 m, then 200 m — as pure arithmetic.
///
/// The rule the driver actually asked for lives here: *announce the gate when it
/// is crossed, never when it is merely satisfied.* The difference matters at both
/// ends of the range:
///
/// * a radar that appears already 30 m away is **not** announced at all — the
///   old code fired the first sentence on first sighting, which is where
///   "radar 0 metres away" came from;
/// * a gap in the GPS track that jumps 900 m in one step announces only the
///   deepest gate it crossed, not all three in a row.
class ApproachLadder {
  ApproachLadder._();

  /// The most urgent gate crossed between two consecutive fixes, or null when
  /// none was.
  ///
  /// [previous] is the last distance we measured for this radar, and null means
  /// we have never seen it before.
  static double? crossedGate({
    required double? previous,
    required double distance,
  }) {
    if (previous == null) return null;

    double? crossed;
    for (final double gate in AppConstants.approachGatesMeters) {
      // The list runs far → near, so the last match is the most urgent one.
      if (distance <= gate && previous > gate) crossed = gate;
    }
    return crossed;
  }

  /// True for the gate that earns the urgent wording ("slow down").
  static bool isUrgent(double gate) => gate <= AppConstants.gateNearMeters;

  /// The beep for a given distance, or null when the bubble should stay quiet.
  /// Kept next to the gates so the audible ladder cannot drift from the spoken
  /// one.
  static bool isBeepGate(double distance) => distance <= AppConstants.gateMidMeters;
}
