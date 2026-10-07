import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/camera_types.dart';
import '../../core/services/crowdsourced_radar_service.dart';
import '../../core/services/osm_sync_service.dart';
import '../../main.dart';
import '../../models/speed_camera.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/theme/status_palette.dart';
import '../../ui/widgets/app_header.dart';
import '../../ui/widgets/brand.dart';
import '../../ui/widgets/controls.dart';
import '../../ui/widgets/surfaces.dart';

enum _RadarFilter {
  all('Hamısı'),
  fixed('Sabit'),
  mobile('Mobil'),
  other('Digər');

  const _RadarFilter(this.label);
  final String label;

  bool accepts(CameraType type) => switch (this) {
        _RadarFilter.all => true,
        _RadarFilter.fixed => type == CameraType.fixed,
        _RadarFilter.mobile => type == CameraType.mobile,
        _RadarFilter.other =>
          type == CameraType.redLight || type == CameraType.averageSpeed,
      };
}

/// The local radar database, browsable.
///
/// The dashboard answers "what is in front of me right now"; this tab answers
/// "what does the app actually know about this city" — which is the question a
/// driver asks right after installing it.
class RadarsTab extends StatefulWidget {
  const RadarsTab({
    super.key,
    required this.services,
    required this.revision,
    required this.onRadarsChanged,
  });

  final AppServices services;
  final int revision;
  final VoidCallback onRadarsChanged;

  @override
  State<RadarsTab> createState() => _RadarsTabState();
}

class _RadarsTabState extends State<RadarsTab> {
  List<SpeedCamera> _nearby = const <SpeedCamera>[];
  int _total = 0;
  int _temporary = 0;
  bool _loading = true;
  bool _busy = false;
  bool _hasPosition = false;
  _RadarFilter _filter = _RadarFilter.all;

  AppServices get services => widget.services;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant RadarsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);

    final double? lat;
    final double? lon;
    final state = services.engine.state.value;
    if (state.hasFix) {
      lat = state.latitude;
      lon = state.longitude;
    } else {
      final last = await services.locationService.lastKnown();
      lat = last?.latitude;
      lon = last?.longitude;
    }

    final int total = await services.repository.count();
    final int temporary = await services.repository.countTemporary();
    List<SpeedCamera> nearby = const <SpeedCamera>[];
    if (lat != null && lon != null) {
      nearby = await services.repository.nearby(
        latitude: lat,
        longitude: lon,
        radiusMeters: AppConstants.radarHorizonMeters,
      );
    }

    if (!mounted) return;
    setState(() {
      _nearby = nearby;
      _total = total;
      _temporary = temporary;
      _hasPosition = lat != null && lon != null;
      _loading = false;
    });
  }

  Future<void> _sync() async {
    setState(() => _busy = true);
    final SyncResult result = await services.engine.syncOsmCameras();
    if (!mounted) return;
    setState(() => _busy = false);
    services.lastNotice.value = result.message;
    widget.onRadarsChanged();
    await _load();
  }

  Future<void> _report() async {
    setState(() => _busy = true);
    final ReportResult result = await services.engine.reportTemporaryRadar();
    if (!mounted) return;
    setState(() => _busy = false);
    services.lastNotice.value = result.message;
    widget.onRadarsChanged();
    await _load();
  }

  Future<void> _openDetails(SpeedCamera camera) async {
    final bool? removed = await showModalBottomSheet<bool>(
      context: context,
      builder: (BuildContext context) => _RadarSheet(
        camera: camera,
        mph: services.settings.useMph,
      ),
    );
    if (removed == true && camera.id != null) {
      await services.repository.deleteById(camera.id!);
      widget.onRadarsChanged();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<SpeedCamera> visible =
        _nearby.where((SpeedCamera c) => _filter.accepts(c.type)).toList();

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: _load,
        color: NexColors.primary,
        backgroundColor: NexColors.surfaceHigh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            NexSpace.page,
            0,
            NexSpace.page,
            NexSpace.xxl,
          ),
          children: <Widget>[
            NexHeader(
              title: 'Radarlar',
              subtitle: _subtitle(),
              leading: const NexLogo(size: 42),
              actions: <Widget>[
                NexIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Yenilə',
                  onPressed: _loading ? null : _load,
                ),
              ],
            ),
            _DatabaseSummary(
              total: _total,
              nearby: _nearby.length,
              temporary: _temporary,
              lastSync: services.settings.lastSync,
            ),
            const SizedBox(height: NexSpace.sm),
            _ActionRow(
              busy: _busy,
              canReport: _hasPosition,
              onSync: _sync,
              onReport: _report,
            ),
            const SizedBox(height: NexSpace.md),
            Segmented<_RadarFilter>(
              value: _filter,
              onChanged: (_RadarFilter f) => setState(() => _filter = f),
              options: _RadarFilter.values
                  .map(
                    (_RadarFilter f) => SegmentedOption<_RadarFilter>(
                      value: f,
                      label: f.label,
                    ),
                  )
                  .toList(growable: false),
            ),
            const SizedBox(height: NexSpace.md),
            if (_loading)
              const _LoadingList()
            else if (visible.isEmpty)
              _EmptyRadars(
                hasPosition: _hasPosition,
                hasDatabase: _total > 0,
                onSync: _sync,
              )
            else
              for (final SpeedCamera camera in visible) ...<Widget>[
                _RadarRow(
                  camera: camera,
                  mph: services.settings.useMph,
                  onTap: () => _openDetails(camera),
                ),
                const SizedBox(height: NexSpace.xs),
              ],
          ],
        ),
      ),
    );
  }

  String _subtitle() {
    if (!_hasPosition && _total == 0) return 'Konum və baza gözlənilir';
    return '${_nearby.length} yaxında · $_total bazada';
  }
}

// ---------------------------------------------------------------------------

class _DatabaseSummary extends StatelessWidget {
  const _DatabaseSummary({
    required this.total,
    required this.nearby,
    required this.temporary,
    required this.lastSync,
  });

  final int total;
  final int nearby;
  final int temporary;
  final DateTime? lastSync;

  @override
  Widget build(BuildContext context) {
    return NexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: StatBlock(
                  value: '$total',
                  label: 'Yaddaşdaki radar',
                  accent: NexColors.primary,
                  icon: Icons.storage_rounded,
                ),
              ),
              const SizedBox(width: NexSpace.xs),
              Expanded(
                child: StatBlock(
                  value: '$nearby',
                  label: 'Yaxınlıqda',
                  accent: NexColors.amber,
                  icon: Icons.near_me_rounded,
                ),
              ),
              const SizedBox(width: NexSpace.xs),
              Expanded(
                child: StatBlock(
                  value: '$temporary',
                  label: 'Topluluk',
                  accent: NexColors.cyan,
                  icon: Icons.groups_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: NexSpace.sm),
          const NexDivider(),
          const SizedBox(height: NexSpace.xs),
          Row(
            children: <Widget>[
              const Icon(
                Icons.cloud_done_outlined,
                size: 14,
                color: NexColors.textLow,
              ),
              const SizedBox(width: 6),
              Text(
                'Son sinxronizasiya: ${Fmt.ago(lastSync)}',
                style: NexText.caption,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.busy,
    required this.canReport,
    required this.onSync,
    required this.onReport,
  });

  final bool busy;
  final bool canReport;
  final VoidCallback onSync;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: FilledButton.icon(
            onPressed: busy ? null : onSync,
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download_outlined, size: 19),
            label: const Text('OSM-dən sinxronlaşdır'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
          ),
        ),
        const SizedBox(width: NexSpace.xs),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: busy || !canReport ? null : onReport,
            icon: const Icon(Icons.add_location_alt_outlined, size: 19),
            label: const Text('Radar bildir'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
          ),
        ),
      ],
    );
  }
}

class _RadarRow extends StatelessWidget {
  const _RadarRow({
    required this.camera,
    required this.mph,
    required this.onTap,
  });

  final SpeedCamera camera;
  final bool mph;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color tone = StatusPalette.ofCamera(camera.type);
    return NexCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: NexSpace.md,
        vertical: NexSpace.sm,
      ),
      child: Row(
        children: <Widget>[
          NexIconBadge(icon: camera.type.icon, color: tone, size: 42),
          const SizedBox(width: NexSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(camera.type.label('az'), style: NexText.bodyStrong),
                const SizedBox(height: 3),
                Row(
                  children: <Widget>[
                    StatusPill(
                      dense: true,
                      label: camera.isTemporary ? 'Topluluk' : 'OSM',
                      color: camera.isTemporary
                          ? NexColors.cyan
                          : NexColors.textLow,
                    ),
                    const SizedBox(width: 6),
                    Text(Fmt.ago(camera.updatedAt), style: NexText.caption),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: NexSpace.xs),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(Fmt.distance(camera.distanceMeters), style: NexText.numeric),
              const SizedBox(height: 2),
              Text(
                'Limit ${camera.maxSpeed} ${mph ? 'mph' : 'km/s'}',
                style: NexText.caption,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: NexSpace.xxxl),
      child: Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      ),
    );
  }
}

class _EmptyRadars extends StatelessWidget {
  const _EmptyRadars({
    required this.hasPosition,
    required this.hasDatabase,
    required this.onSync,
  });

  final bool hasPosition;
  final bool hasDatabase;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: NexSpace.xl),
      child: Column(
        children: <Widget>[
          const RadarSweep(size: 180, color: NexColors.textLow),
          const SizedBox(height: NexSpace.md),
          Text(
            hasPosition ? 'Yaxınlıqda radar tapılmadı' : 'Konum gözlənilir',
            style: NexText.h3,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: NexSpace.xs),
          Text(
            hasPosition
                ? (hasDatabase
                    ? 'Bazada radar var, amma seçilmiş radiusda deyil. '
                        'Radiusu ayarlardan artıra bilərsən.'
                    : 'OSM-dən sinxronlaşdıraraq bu ərazinin radarlarını '
                        'yüklə. Sonra şəbəkə olmadan da işləyəcək.')
                : 'GPS fiksi alınan kimi yaxınlıqdaki radarlar siyahıda '
                    'görünəcək.',
            style: NexText.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: NexSpace.lg),
          SizedBox(
            width: 220,
            child: FilledButton.icon(
              onPressed: onSync,
              icon: const Icon(Icons.cloud_download_outlined, size: 19),
              label: const Text('Sinxronlaşdır'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _RadarSheet extends StatelessWidget {
  const _RadarSheet({required this.camera, required this.mph});

  final SpeedCamera camera;
  final bool mph;

  @override
  Widget build(BuildContext context) {
    final Color tone = StatusPalette.ofCamera(camera.type);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NexSpace.lg,
          NexSpace.xs,
          NexSpace.lg,
          NexSpace.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                NexIconBadge(icon: camera.type.icon, color: tone, size: 48),
                const SizedBox(width: NexSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(camera.type.label('az'), style: NexText.h3),
                      Text(
                        camera.isTemporary
                            ? 'Sürücü bildirişi'
                            : 'OpenStreetMap məlumatı',
                        style: NexText.caption,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: NexSpace.md),
            _DetailRow(
              label: 'Sürət həddi',
              value: '${camera.maxSpeed} ${mph ? 'mph' : 'km/s'}',
            ),
            _DetailRow(
              label: 'Məsafə',
              value: Fmt.distance(camera.distanceMeters),
            ),
            _DetailRow(
              label: 'Koordinatlar',
              value: '${camera.latitude.toStringAsFixed(5)}, '
                  '${camera.longitude.toStringAsFixed(5)}',
            ),
            if (camera.directionBearing != null)
              _DetailRow(
                label: 'İstiqamət',
                value: '${camera.directionBearing!.round()}°',
              ),
            _DetailRow(label: 'Mənbə', value: camera.source),
            _DetailRow(label: 'Yeniləndi', value: Fmt.ago(camera.updatedAt)),
            if (camera.isTemporary) ...<Widget>[
              const SizedBox(height: NexSpace.md),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(true),
                  icon: const Icon(Icons.delete_outline_rounded, size: 19),
                  label: const Text('Bu bildirişi sil'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NexColors.danger,
                    side: BorderSide(
                      color: NexColors.danger.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(label, style: NexText.caption),
          ),
          Expanded(
            child: Text(
              value,
              style: NexText.bodyStrong.copyWith(fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}
