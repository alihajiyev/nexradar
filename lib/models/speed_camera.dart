import '../core/constants/camera_types.dart';

/// A single speed-enforcement point.
///
/// Persisted 1:1 into the `speed_camera` table:
///
/// ```sql
/// CREATE TABLE speed_camera(
///   id               INTEGER PRIMARY KEY,
///   latitude         REAL NOT NULL,
///   longitude        REAL NOT NULL,
///   max_speed        INTEGER NOT NULL,
///   direction_bearing REAL,
///   camera_type      TEXT NOT NULL,
///   is_temporary     INTEGER NOT NULL DEFAULT 0,
///   source           TEXT NOT NULL DEFAULT 'osm',
///   expires_at       INTEGER,
///   updated_at       INTEGER NOT NULL
/// );
/// ```
///
/// [id] is null for rows that have not been inserted yet. For freshly created
/// (not yet stored) cameras we still need a stable identity for dedupe, which
/// is why [identityKey] is derived from the geo position instead of the row id.
class SpeedCamera {
  const SpeedCamera({
    this.id,
    required this.latitude,
    required this.longitude,
    required this.maxSpeed,
    this.directionBearing,
    this.type = CameraType.fixed,
    this.isTemporary = false,
    this.source = sourceOsm,
    this.expiresAt,
    required this.updatedAt,
    this.distanceMeters,
  });

  static const String sourceOsm = 'osm';
  static const String sourceCommunity = 'community';

  final int? id;
  final double latitude;
  final double longitude;

  /// Posted limit in km/h.
  final int maxSpeed;

  /// The angle the radar is *looking* down the road, 0-360°, may be unknown.
  final double? directionBearing;

  final CameraType type;

  /// Community-submitted, expires after [AppConstants.temporaryRadarTtl].
  final bool isTemporary;

  /// `osm` | `community`
  final String source;

  final DateTime? expiresAt;
  final DateTime updatedAt;

  /// Transient, never persisted: filled in by the spatial query so the UI and
  /// the overlay can show "350 m" without recomputing the haversine distance.
  final double? distanceMeters;

  /// Stable identity across syncs — a camera does not move.
  String get identityKey =>
      '${latitude.toStringAsFixed(5)}:${longitude.toStringAsFixed(5)}:${type.wire}';

  bool get isExpired {
    final DateTime? exp = expiresAt;
    if (exp == null) return false;
    return exp.isBefore(DateTime.now());
  }

  SpeedCamera copyWith({
    int? id,
    double? latitude,
    double? longitude,
    int? maxSpeed,
    double? directionBearing,
    bool clearDirection = false,
    CameraType? type,
    bool? isTemporary,
    String? source,
    DateTime? expiresAt,
    DateTime? updatedAt,
    double? distanceMeters,
  }) {
    return SpeedCamera(
      id: id ?? this.id,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      maxSpeed: maxSpeed ?? this.maxSpeed,
      directionBearing:
          clearDirection ? null : (directionBearing ?? this.directionBearing),
      type: type ?? this.type,
      isTemporary: isTemporary ?? this.isTemporary,
      source: source ?? this.source,
      expiresAt: expiresAt ?? this.expiresAt,
      updatedAt: updatedAt ?? this.updatedAt,
      distanceMeters: distanceMeters ?? this.distanceMeters,
    );
  }

  Map<String, Object?> toMap({bool includeId = false}) {
    return <String, Object?>{
      if (includeId && id != null) 'id': id,
      'latitude': latitude,
      'longitude': longitude,
      'max_speed': maxSpeed,
      'direction_bearing': directionBearing,
      'camera_type': type.wire,
      'is_temporary': isTemporary ? 1 : 0,
      'source': source,
      'expires_at': expiresAt?.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  /// Same shape as [toMap] but the community feed uses camelCase JSON so the
  /// data is readable from the Firebase console.
  Map<String, Object?> toJson() => <String, Object?>{
        'latitude': latitude,
        'longitude': longitude,
        'maxSpeed': maxSpeed,
        'directionBearing': directionBearing,
        'cameraType': type.wire,
        'isTemporary': isTemporary,
        'source': source,
        'expiresAt': expiresAt?.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static SpeedCamera fromMap(Map<String, Object?> map) {
    final Object? dir = map['direction_bearing'];
    return SpeedCamera(
      id: (map['id'] as num?)?.toInt(),
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      maxSpeed: (map['max_speed'] as num?)?.toInt() ?? 60,
      directionBearing:
          dir == null ? null : (dir as num).toDouble(),
      type: CameraType.fromWire(map['camera_type'] as String?),
      isTemporary: ((map['is_temporary'] as num?)?.toInt() ?? 0) == 1,
      source: (map['source'] as String?) ?? sourceOsm,
      expiresAt: _dt(map['expires_at']),
      updatedAt: _dt(map['updated_at']) ?? DateTime.now(),
    );
  }

  static SpeedCamera fromJson(Map<dynamic, dynamic> map) {
    final Object? dir = map['directionBearing'];
    return SpeedCamera(
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      maxSpeed: (map['maxSpeed'] as num?)?.toInt() ?? 60,
      directionBearing: dir == null ? null : (dir as num).toDouble(),
      type: CameraType.fromWire(map['cameraType'] as String?),
      isTemporary: map['isTemporary'] == true,
      source: (map['source'] as String?) ?? sourceCommunity,
      expiresAt: _dt(map['expiresAt']),
      updatedAt: _dt(map['updatedAt']) ?? DateTime.now(),
    );
  }

  static DateTime? _dt(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  SpeedCamera withDistance(double meters) =>
      copyWith(distanceMeters: meters);

  @override
  String toString() =>
      'SpeedCamera(${type.wire} @ $latitude,$longitude limit=$maxSpeed '
      'bearing=${directionBearing?.toStringAsFixed(0)} temp=$isTemporary)';

  @override
  bool operator ==(Object other) =>
      other is SpeedCamera && other.identityKey == identityKey;

  @override
  int get hashCode => identityKey.hashCode;
}
