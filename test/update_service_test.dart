import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nex_radar/core/services/settings_service.dart';
import 'package:nex_radar/core/services/update_service.dart';

/// The updater is how the app is distributed, so its two decisions — *is there a
/// newer release?* and *which asset is the APK?* — are pinned down here. Both
/// halves of the I/O are faked: the GitHub response comes from a `MockClient`,
/// and the installed version comes from the `nexradar/update` platform channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('nexradar/update');

  void installedVersionIs(String versionName, [int versionCode = 1]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'installedVersion') {
        return <String, Object?>{
          'versionName': versionName,
          'versionCode': versionCode,
        };
      }
      return null;
    });
  }

  /// A GitHub `releases/latest` payload, trimmed to the fields the updater reads.
  String releaseJson({
    required String tag,
    List<Map<String, Object?>> assets = const <Map<String, Object?>>[
      <String, Object?>{
        'name': 'NexRadar.apk',
        'browser_download_url':
            'https://github.com/alihajiyev/nexradar/releases/download/v1.2.0/NexRadar.apk',
        'size': 55639611,
      },
    ],
  }) {
    return jsonEncode(<String, Object?>{
      'tag_name': tag,
      'body': 'Kilid ekranı HUD-u',
      'html_url': 'https://github.com/alihajiyev/nexradar/releases/tag/$tag',
      'published_at': '2026-10-07T07:43:13Z',
      'assets': assets,
    });
  }

  /// The real endpoint answers with `charset=utf-8`. Without that header
  /// `http.Response` encodes the body as latin-1, which rejects the Azerbaijani
  /// release notes — and would hide a genuine encoding bug in the updater.
  http.Response githubOk(String body) => http.Response(
        body,
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );

  UpdateService serviceReturning(
    http.Response Function(http.Request request) handler,
  ) {
    return UpdateService(
      settings: SettingsService.instance,
      client: MockClient((http.Request request) async => handler(request)),
    );
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('UpdateService · release check', () {
    test('a newer release is available and the .apk asset is picked', () async {
      installedVersionIs('1.1.0', 2);
      Uri? seen;
      final UpdateService service = serviceReturning((http.Request request) {
        seen = request.url;
        return githubOk(releaseJson(tag: 'v1.2.0'));
      });

      final UpdateCheckResult result = await service.check();

      expect(result.status, UpdateStatus.available, reason: result.message ?? "");
      expect(result.hasUpdate, isTrue);
      expect(result.installedVersion, '1.1.0');
      expect(result.release!.tag, 'v1.2.0');
      expect(result.release!.version, '1.2.0');
      expect(result.release!.apkName, 'NexRadar.apk');
      expect(result.release!.apkSizeBytes, 55639611);
      expect(result.release!.sizeLabel, '53.1 MB');
      // The endpoint the release pipeline actually publishes to.
      expect(
        seen.toString(),
        'https://api.github.com/repos/alihajiyev/nexradar/releases/latest',
      );
    });

    test('a non-APK asset is skipped in favour of the real one', () async {
      installedVersionIs('1.1.0');
      final UpdateService service = serviceReturning(
        (http.Request request) => githubOk(
          releaseJson(
            tag: 'v1.2.0',
            assets: <Map<String, Object?>>[
              <String, Object?>{
                'name': 'checksums.txt',
                'browser_download_url': 'https://example.invalid/checksums.txt',
                'size': 12,
              },
              <String, Object?>{
                'name': 'NexRadar.apk',
                'browser_download_url': 'https://example.invalid/NexRadar.apk',
                'size': 100,
              },
            ],
          ),
        ),
      );

      final UpdateCheckResult result = await service.check();

      expect(result.release!.apkName, 'NexRadar.apk');
      expect(result.release!.apkUrl, 'https://example.invalid/NexRadar.apk');
    });

    test('the installed version is up to date', () async {
      installedVersionIs('1.2.0');
      final UpdateService service = serviceReturning(
        (http.Request request) => githubOk(releaseJson(tag: 'v1.2.0')),
      );

      final UpdateCheckResult result = await service.check();

      expect(result.status, UpdateStatus.upToDate);
      expect(result.hasUpdate, isFalse);
    });

    test('an older published release never offers a downgrade', () async {
      installedVersionIs('1.2.0');
      final UpdateService service = serviceReturning(
        (http.Request request) => githubOk(releaseJson(tag: 'v1.1.9')),
      );

      expect((await service.check()).status, UpdateStatus.upToDate);
    });

    test('a release without an APK asset fails loudly instead of silently', () async {
      installedVersionIs('1.0.0');
      final UpdateService service = serviceReturning(
        (http.Request request) =>
            githubOk(releaseJson(tag: 'v9.9.9', assets: <Map<String, Object?>>[])),
      );

      final UpdateCheckResult result = await service.check();

      expect(result.status, UpdateStatus.failed);
      expect(result.release, isNull);
    });

    test('404 means the repository has no releases yet, not an error', () async {
      installedVersionIs('1.0.0');
      final UpdateService service = serviceReturning(
        (http.Request request) => http.Response('{"message":"Not Found"}', 404),
      );

      final UpdateCheckResult result = await service.check();

      expect(result.status, UpdateStatus.upToDate);
      expect(result.message, contains('release'));
    });

    test('a network failure is reported as failed, never as up to date', () async {
      installedVersionIs('1.0.0');
      final UpdateService service = serviceReturning((http.Request request) {
        throw http.ClientException('offline');
      });

      final UpdateCheckResult result = await service.check();

      expect(result.status, UpdateStatus.failed);
      expect(result.hasUpdate, isFalse);
    });
  });

  group('UpdateService · version arithmetic', () {
    test('tags are normalized to a comparable version', () {
      expect(UpdateService.normalizeVersion('v1.2.3'), '1.2.3');
      expect(UpdateService.normalizeVersion('V2.0'), '2.0');
      expect(UpdateService.normalizeVersion('1.2.3-beta+build.7'), '1.2.3');
      expect(UpdateService.normalizeVersion('  1.0.0  '), '1.0.0');
      expect(UpdateService.normalizeVersion(''), '0');
    });

    test('comparison is numeric, not lexicographic', () {
      // The bug this guards against: "1.9.0" > "1.10.0" as strings.
      expect(UpdateService.compareVersions('1.10.0', '1.9.0'), greaterThan(0));
      expect(UpdateService.compareVersions('1.9.0', '1.10.0'), lessThan(0));
    });

    test('comparison tolerates tags, missing components and junk', () {
      expect(UpdateService.compareVersions('v1.1.0', '1.1.0'), 0);
      expect(UpdateService.compareVersions('1.1', '1.1.0'), 0);
      expect(UpdateService.compareVersions('1.1.1', '1.1.0'), greaterThan(0));
      expect(UpdateService.compareVersions('2.0', '1.9.9'), greaterThan(0));
      expect(UpdateService.compareVersions('1.2.x', '1.2.0'), 0);
      expect(UpdateService.compareVersions('0.0.0', '1.0.0'), lessThan(0));
    });
  });
}
