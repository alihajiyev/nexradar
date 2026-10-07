/// Central, single source of truth for every tunable number in NexRadar.
///
/// Nothing in the app should hard-code a distance, angle or duration — the
/// constants below are what the settings screen and the engine read.
class AppConstants {
  AppConstants._();

  // ---------------------------------------------------------------- identity
  static const String appName = 'NexRadar';
  static const String appTagline = 'Arxa fonda işləyən radar & sürət HUD';
  static const String appVersion = '1.1.0';

  // -------------------------------------------------------------- persistence
  static const String dbName = 'nex_radar.db';
  static const int dbVersion = 1;

  static const String tableCameras = 'speed_camera';
  static const String tablePendingReports = 'pending_report';
  static const String tableSyncMeta = 'sync_meta';

  // ------------------------------------------------------------------- engine
  /// The radar horizon, in meters.
  ///
  /// NexRadar always looks **exactly** this far ahead and reports the nearest
  /// camera inside it. This is deliberately not a setting: the driver asked for
  /// a fixed 5 km picture — not less, not more — so the bubble and the
  /// lock-screen card always mean the same thing.
  static const double radarHorizonMeters = 5000.0;

  /// |θ_heading - θ_camera| <= tolerance ⇒ the camera is a real forward threat.
  /// Everything else is oncoming traffic / perpendicular streets and is dropped.
  static const double angularToleranceDegrees = 45.0;

  /// Extra slack used when we only know where the camera is (no facing angle).
  static const double approachToleranceDegrees = 55.0;

  // ---------------------------------------------------------- overlay alerts
  /// APPROACHING gate: the bubble turns amber inside this radius.
  static const double overlayWarnFarMeters = 500.0;

  /// The "very close" gate — blinking limit + remaining distance.
  static const double overlayWarnNearMeters = 200.0;

  // ------------------------------------------------------------------ voice
  /// First spoken announcement.
  static const double voiceFarMeters = 400.0;

  /// Second, urgent announcement.
  static const double voiceNearMeters = 150.0;

  /// Do not repeat the same sentence faster than this.
  static const Duration voiceCooldown = Duration(seconds: 9);

  /// Kill switch: never queue more than N sentences in a row.
  static const Duration voiceGlobalCooldown = Duration(seconds: 3);

  // ------------------------------------------------------------ beep / alarm
  static const Duration beepCooldown = Duration(milliseconds: 900);
  static const Duration alarmRepeatInterval = Duration(milliseconds: 1600);

  // ----------------------------------------------------------- crowdsourcing
  /// A community "mobile YPX" report stays valid for two hours.
  static const Duration temporaryRadarTtl = Duration(hours: 2);

  /// How often the live community feed is polled while driving.
  static const Duration communityPollInterval = Duration(seconds: 45);

  // --------------------------------------------------------- camera cache db
  /// Re-read the local cache when we moved this far or this much time passed.
  static const double cameraRefreshMoveMeters = 60.0;
  static const Duration cameraRefreshInterval = Duration(seconds: 12);

  /// Temporary reports older than this are pruned from SQLite.
  static const Duration temporaryPurgeAfter = Duration(hours: 3);

  // ---------------------------------------------------------- speed smoothing
  /// Time constant of the exponential smoother that turns the 1 Hz GPS chip
  /// into a 60 FPS fluid needle. Bigger = smoother but lazier.
  static const double speedSmoothingTauSeconds = 0.42;

  /// Hard clamp so a bad fix can never paint a 900 km/h needle.
  static const double maxDisplayKmh = 320.0;

  /// A fix older than this is considered lost.
  static const Duration gpsStaleAfter = Duration(seconds: 5);

  /// Stop moving below this (GPS jitter at standstill reads 1-3 km/h).
  static const double speedDeadbandKmh = 2.4;

  // --------------------------------------------------------------- defaults
  static const double defaultSpeedLimitKmh = 60.0;

  /// Sent to the native overlay when no limit is known for the threat.
  static const int unknownLimit = -1;

  // -------------------------------------------------------------- osm / sync
  static const List<String> overpassEndpoints = <String>[
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
  ];

  static const Duration overpassTimeout = Duration(seconds: 40);

  /// Shrink the Overpass window above this so the query never explodes.
  static const double maxSyncRadiusMeters = 60000.0;
  static const double defaultSyncRadiusMeters = 25000.0;

  // ------------------------------------------------------------ preference keys
  static const String prefOverlayEnabled = 'overlay_enabled';
  static const String prefVoiceEnabled = 'voice_enabled';
  static const String prefBeepEnabled = 'beep_enabled';
  static const String prefLanguage = 'voice_language';
  static const String prefAngularTolerance = 'angular_tolerance';
  static const String prefUnitsMph = 'units_mph';
  static const String prefShowRemaining = 'overlay_show_remaining';
  static const String prefFirebaseUrl = 'crowd_firebase_url';
  static const String prefSyncRadius = 'sync_radius';
  static const String prefLastSync = 'last_sync_epoch';
  static const String prefOverlayScale = 'overlay_scale';
  static const String prefOverlayX = 'overlay_x';
  static const String prefOverlayY = 'overlay_y';
  static const String prefOnboarded = 'onboarding_completed';
  static const String prefUpdateRepo = 'update_repo';
  static const String prefAutoUpdateCheck = 'auto_update_check';
  static const String prefLastUpdateCheck = 'last_update_check';
  static const String prefPendingUpdate = 'pending_update_version';
  static const String prefLogExpanded = 'log_expanded';

  // ----------------------------------------------------------------- geometry
  /// Meters per degree of latitude (good enough for city-scale filtering).
  static const double metersPerDegreeLat = 111320.0;
}
