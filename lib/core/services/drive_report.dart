import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// What one drive actually looked like.
///
/// The dashboard shows the *now*: this second's speed, the next camera. None of
/// that answers the question a driver asks after a trip — "was I alright?" — and
/// none of it survives the app being closed. So the engine accumulates a handful
/// of numbers for as long as the pipeline runs, and this model renders them.
///
/// Every field is a plain fact measured from the GPS stream; nothing here is
/// interpolated or guessed. [averageSpeedKmh] in particular is the same
/// distance-over-time arithmetic an average-speed camera uses, which makes it a
/// useful check on a section the driver has just left.
@immutable
class DriveReport {
  const DriveReport({
    required this.startedAt,
    required this.endedAt,
    required this.distanceMeters,
    required this.maxSpeedKmh,
    required this.overLimitSeconds,
    required this.announcements,
    required this.radarsPassed,
    required this.camerasSeen,
  });

  final DateTime? startedAt;
  final DateTime? endedAt;
  final double distanceMeters;
  final double maxSpeedKmh;
  final int overLimitSeconds;
  final int announcements;
  final int radarsPassed;
  final int camerasSeen;

  static DriveReport empty() => const DriveReport(
        startedAt: null,
        endedAt: null,
        distanceMeters: 0,
        maxSpeedKmh: 0,
        overLimitSeconds: 0,
        announcements: 0,
        radarsPassed: 0,
        camerasSeen: 0,
      );

  /// Wall clock of the drive, which stops when the pipeline does.
  Duration get elapsed {
    final DateTime? from = startedAt;
    if (from == null) return Duration.zero;
    final DateTime to = endedAt ?? DateTime.now();
    final Duration gap = to.difference(from);
    return gap.isNegative ? Duration.zero : gap;
  }

  /// Distance over time, exactly as an average-speed camera computes it.
  double get averageSpeedKmh {
    final int ms = elapsed.inMilliseconds;
    if (ms <= 0 || distanceMeters <= 0) return 0;
    return distanceMeters / ms * 3600.0;
  }

  bool get isEmpty => startedAt == null;
  bool get isMoving => distanceMeters >= 100;

  /// Share of the drive spent above the posted limit, 0-1.
  double get overLimitShare {
    final int ms = elapsed.inMilliseconds;
    if (ms <= 0) return 0;
    return math.min(1, overLimitSeconds * 1000 / ms);
  }

  String get durationLabel {
    final int hours = elapsed.inHours;
    final int minutes = elapsed.inMinutes % 60;
    final int seconds = elapsed.inSeconds % 60;
    if (hours > 0) return '$hours saat $minutes dəq';
    if (minutes > 0) return '$minutes dəq $seconds san';
    return '$seconds san';
  }

  String get distanceLabel => distanceMeters >= 1000
      ? '${(distanceMeters / 1000).toStringAsFixed(1)} km'
      : '${distanceMeters.round()} m';

  String get maxSpeedLabel => maxSpeedKmh.round().toString();
  String get averageSpeedLabel => averageSpeedKmh.round().toString();

  String get overLimitLabel {
    if (overLimitSeconds < 60) return '$overLimitSeconds san';
    return '${overLimitSeconds ~/ 60} dəq ${overLimitSeconds % 60} san';
  }

  /// One sentence for the top of the card. Deliberately not a score: the driver
  /// only needs to know whether anything about this trip deserves a second look.
  String get verdict {
    if (isEmpty) return 'Hələ sürüş qeydə alınmayıb';
    if (!isMoving) return 'Sürüş başladı — hələ hərəkət yoxdur';
    if (overLimitSeconds == 0) {
      return 'Təmiz sürüş · $distanceLabel, limit heç vaxt aşılmayıb';
    }
    final int share = (overLimitShare * 100).round();
    if (share < 5) {
      return 'Yaxşı sürüş · limitin üstündə cəmi $overLimitLabel';
    }
    return 'Limitin üstündə $overLimitLabel '
        '(sürüşün $share%-i)';
  }

  /// Timeline of the drive, for the log-style rows under the card.
  List<String> get timeline => <String>[
        'Müddət: $durationLabel',
        'Məsafə: $distanceLabel',
        'Orta sürət: $averageSpeedLabel km/s',
        'Maksimum: $maxSpeedLabel km/s',
        if (overLimitSeconds > 0) 'Limit üstü: $overLimitLabel',
        'Anons: $announcements',
        'Keçilən radar: $radarsPassed',
      ];
}
