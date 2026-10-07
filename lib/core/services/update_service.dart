import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'settings_service.dart';

/// A published GitHub Release that carries an installable APK.
@immutable
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.apkName,
    required this.apkSizeBytes,
    required this.pageUrl,
    required this.publishedAt,
  });

  /// Raw tag, e.g. `v1.2.0`.
  final String tag;

  /// Normalized, comparable version, e.g. `1.2.0`.
  final String version;
  final String notes;
  final String apkUrl;
  final String apkName;
  final int apkSizeBytes;
  final String pageUrl;
  final DateTime? publishedAt;

  String get sizeLabel {
    if (apkSizeBytes <= 0) return '—';
    final double mb = apkSizeBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  /// First line of the release notes, for a compact "what's new" line.
  String get headline {
    for (final String line in notes.split('\n')) {
      final String trimmed = line.trim().replaceAll(RegExp(r'^[#*\-\s]+'), '');
      if (trimmed.isNotEmpty) return trimmed;
    }
    return 'Yeni sürüm';
  }
}

enum UpdateStatus {
  /// The installed build is already the newest release.
  upToDate,

  /// A newer release exists and is ready to download.
  available,

  /// The check could not complete (offline, rate limit, no releases).
  failed,
}

@immutable
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    required this.installedVersion,
    this.release,
    this.message,
  });

  final UpdateStatus status;
  final String installedVersion;
  final ReleaseInfo? release;
  final String? message;

  bool get hasUpdate => status == UpdateStatus.available && release != null;
}

/// Self-hosted OTA updates on top of GitHub Releases.
///
/// Why not `in_app_update`? That plugin only talks to the Play Store, and
/// NexRadar is side-loaded from GitHub. The flow here is the standard
/// side-load one:
///
/// ```
/// GET /repos/:owner/:repo/releases/latest   → compare tag with the installed
/// GET <asset browser_download_url>          → stream the APK into cacheDir
/// → native `installApk(path)`               → FileProvider + system installer
/// ```
///
/// The repo slug is baked in with `--dart-define=NEX_RADAR_REPO=owner/name` and
/// can be overridden at runtime from the settings screen, so a fork can point
/// the updater at itself without a rebuild of the Dart code.
class UpdateService {
  UpdateService({required this.settings, http.Client? client})
      : _client = client ?? http.Client();

  final SettingsService settings;
  final http.Client _client;

  static const MethodChannel _channel = MethodChannel('nexradar/update');

  static const String _bakedRepo =
      String.fromEnvironment('NEX_RADAR_REPO', defaultValue: '');

  static const String _defaultRepo = 'alihajiyev/nexradar';

  /// `owner/name`. Runtime setting wins, then the baked dart-define, then the
  /// project default.
  String get repoSlug {
    final String configured = settings.updateRepo.trim();
    if (configured.isNotEmpty) return configured;
    if (_bakedRepo.isNotEmpty) return _bakedRepo;
    return _defaultRepo;
  }

  bool get isConfigured => repoSlug.contains('/');

  String get releasesPageUrl => 'https://github.com/$repoSlug/releases/latest';

  // ------------------------------------------------------------------ native

  Future<String> installedVersion() async {
    try {
      final Map<Object?, Object?>? info =
          await _channel.invokeMethod<Map<Object?, Object?>>('installedVersion');
      return (info?['versionName'] as String?) ?? '0.0.0';
    } catch (_) {
      return '0.0.0';
    }
  }

  Future<bool> canInstallPackages() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openInstallPermissionSettings() async {
    try {
      await _channel.invokeMethod<void>('openInstallPermissionSettings');
    } catch (_) {}
  }

  /// Hands a downloaded file to the system package installer.
  ///
  /// Returns `false` when the "install unknown apps" grant is missing — the
  /// caller should then surface that to the user, because the settings page has
  /// already been opened for them.
  Future<bool> installApk(String path) async {
    try {
      return await _channel
              .invokeMethod<bool>('installApk', <String, Object?>{'path': path}) ??
          false;
    } catch (e) {
      if (kDebugMode) debugPrint('[UpdateService] installApk failed: $e');
      return false;
    }
  }

  Future<String?> cacheDirectory() async {
    try {
      return await _channel.invokeMethod<String>('cacheDir');
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------- check

  Future<UpdateCheckResult> check() async {
    final String installed = await installedVersion();
    if (!isConfigured) {
      return UpdateCheckResult(
        status: UpdateStatus.failed,
        installedVersion: installed,
        message: 'GitHub deposu təyin edilməyib.',
      );
    }

    try {
      final http.Response res = await _client
          .get(
            Uri.parse('https://api.github.com/repos/$repoSlug/releases/latest'),
            headers: const <String, String>{
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'NexRadar-Updater',
            },
          )
          .timeout(const Duration(seconds: 20));

      if (res.statusCode == 404) {
        return UpdateCheckResult(
          status: UpdateStatus.upToDate,
          installedVersion: installed,
          message: 'Hələ heç bir release dərc edilməyib.',
        );
      }
      if (res.statusCode != 200) {
        return UpdateCheckResult(
          status: UpdateStatus.failed,
          installedVersion: installed,
          message: 'GitHub cavabı: HTTP ${res.statusCode}',
        );
      }

      final Object? decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        return UpdateCheckResult(
          status: UpdateStatus.failed,
          installedVersion: installed,
          message: 'Release cavabı oxuna bilmədi.',
        );
      }

      final ReleaseInfo? release = _parseRelease(decoded);
      if (release == null) {
        return UpdateCheckResult(
          status: UpdateStatus.failed,
          installedVersion: installed,
          message: 'Release-də APK faylı tapılmadı.',
        );
      }

      final bool newer = compareVersions(release.version, installed) > 0;
      return UpdateCheckResult(
        status: newer ? UpdateStatus.available : UpdateStatus.upToDate,
        installedVersion: installed,
        release: release,
        message: newer
            ? 'Yeni sürüm mövcuddur: v${release.version}'
            : 'Ən son sürümü istifadə edirsiniz.',
      );
    } on TimeoutException {
      return UpdateCheckResult(
        status: UpdateStatus.failed,
        installedVersion: installed,
        message: 'GitHub vaxtında cavab vermədi.',
      );
    } catch (e) {
      return UpdateCheckResult(
        status: UpdateStatus.failed,
        installedVersion: installed,
        message: 'Yoxlama alınmadı: $e',
      );
    }
  }

  static ReleaseInfo? _parseRelease(Map<dynamic, dynamic> json) {
    final String tag = (json['tag_name'] as String?) ?? '';
    final String body = (json['body'] as String?) ?? '';
    final String pageUrl = (json['html_url'] as String?) ?? '';
    final DateTime? published =
        DateTime.tryParse((json['published_at'] as String?) ?? '');

    final dynamic assets = json['assets'];
    if (assets is! List) return null;

    for (final dynamic asset in assets) {
      if (asset is! Map) continue;
      final String name = (asset['name'] as String?) ?? '';
      final String url = (asset['browser_download_url'] as String?) ?? '';
      if (!name.toLowerCase().endsWith('.apk') || url.isEmpty) continue;
      return ReleaseInfo(
        tag: tag,
        version: normalizeVersion(tag),
        notes: body,
        apkUrl: url,
        apkName: name,
        apkSizeBytes: (asset['size'] as num?)?.toInt() ?? 0,
        pageUrl: pageUrl,
        publishedAt: published,
      );
    }
    return null;
  }

  // ---------------------------------------------------------------- download

  /// Streams the release APK into `cacheDir/updates/` and returns its path.
  Future<String> download(
    ReleaseInfo release, {
    void Function(double progress)? onProgress,
  }) async {
    final String? cache = await cacheDirectory();
    if (cache == null || cache.isEmpty) {
      throw const FileSystemException('Keş qovluğu tapılmadı.');
    }
    final Directory dir = Directory('$cache/updates');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final File target = File('${dir.path}/${_safeName(release.apkName)}');

    final http.StreamedResponse response = await _client
        .send(
          http.Request('GET', Uri.parse(release.apkUrl))
            ..headers['Accept'] = 'application/octet-stream'
            ..headers['User-Agent'] = 'NexRadar-Updater',
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw HttpException('APK endirilə bilmədi (HTTP ${response.statusCode})');
    }

    final int total = response.contentLength ?? release.apkSizeBytes;
    final IOSink sink = target.openWrite();
    int received = 0;
    try {
      await for (final List<int> chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (received == 0 || !target.existsSync()) {
      throw const FileSystemException('Endirilən fayl boşdur.');
    }
    onProgress?.call(1.0);
    return target.path;
  }

  static String _safeName(String name) {
    final String cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.toLowerCase().endsWith('.apk') ? cleaned : '$cleaned.apk';
  }

  // ---------------------------------------------------------------- versions

  /// `v1.2.3-beta+build` → `1.2.3`.
  static String normalizeVersion(String raw) {
    String value = raw.trim();
    value = value.replaceFirst(RegExp(r'^[vV]'), '');
    value = value.split('+').first;
    value = value.split('-').first;
    return value.isEmpty ? '0' : value;
  }

  /// Numeric, component-wise comparison. `1.10.0` is newer than `1.9.0`.
  static int compareVersions(String a, String b) {
    final List<int> left = _components(a);
    final List<int> right = _components(b);
    final int length = left.length > right.length ? left.length : right.length;
    for (int i = 0; i < length; i++) {
      final int l = i < left.length ? left[i] : 0;
      final int r = i < right.length ? right[i] : 0;
      if (l != r) return l.compareTo(r);
    }
    return 0;
  }

  static List<int> _components(String version) {
    return normalizeVersion(version)
        .split('.')
        .map((String part) {
          final RegExpMatch? digits = RegExp(r'\d+').firstMatch(part);
          return digits == null ? 0 : int.tryParse(digits.group(0)!) ?? 0;
        })
        .toList(growable: false);
  }

  void dispose() => _client.close();
}
