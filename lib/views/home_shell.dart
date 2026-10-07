import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/services/radar_engine.dart';
import '../main.dart';
import '../ui/theme/app_theme.dart';
import 'tabs/drive_tab.dart';
import 'tabs/radars_tab.dart';
import 'tabs/settings_tab.dart';

/// The signed-in experience: three tabs, one frame ticker, one snackbar host.
///
/// The ticker lives here rather than inside a tab so the 60 FPS interpolation
/// keeps running no matter which tab is on screen — switching to "Radarlar"
/// mid-drive must not freeze the needle.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.services});

  final AppServices services;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;

  int _index = 0;

  /// Bumped whenever a radar may have been added/removed, so the radar tab can
  /// reload without polling.
  final ValueNotifier<int> _radarsRevision = ValueNotifier<int>(0);

  AppServices get services => widget.services;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_onTick)..start();
    services.lastNotice.addListener(_onNotice);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _radarsRevision.dispose();
    services.lastNotice.removeListener(_onNotice);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The user may have changed the overlay grant while we were away.
      services.overlay.refreshRunningState();
      setState(() {});
    }
  }

  void _onTick(Duration elapsed) {
    // The engine owns its own clock (it also pumps itself when no UI is
    // attached), so this is a nudge, not a time source.
    services.engine.tick();
  }

  void _onNotice() {
    final String? notice = services.lastNotice.value;
    if (notice == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(notice),
          duration: const Duration(seconds: 4),
        ),
      );
    services.lastNotice.value = null;
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    if (index == 1) _radarsRevision.value++;
  }

  void notifyRadarsChanged() => _radarsRevision.value++;

  @override
  Widget build(BuildContext context) {
    final int revision = _radarsRevision.value;

    return Scaffold(
      backgroundColor: NexColors.background,
      body: IndexedStack(
        index: _index,
        children: <Widget>[
          DriveTab(
            services: services,
            onOpenSettings: () => _select(2),
            onRadarsChanged: notifyRadarsChanged,
          ),
          RadarsTab(
            services: services,
            revision: revision,
            onRadarsChanged: notifyRadarsChanged,
          ),
          SettingsTab(
            services: services,
            onOpenRadars: () => _select(1),
          ),
        ],
      ),
      bottomNavigationBar: _NexBottomBar(index: _index, onSelect: _select),
    );
  }
}

// ---------------------------------------------------------------------------

class _NavDestination {
  const _NavDestination({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

class _NexBottomBar extends StatelessWidget {
  const _NexBottomBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  static const List<_NavDestination> _destinations = <_NavDestination>[
    _NavDestination(
      icon: Icons.speed_outlined,
      activeIcon: Icons.speed_rounded,
      label: 'Sürüş',
    ),
    _NavDestination(
      icon: Icons.radar_outlined,
      activeIcon: Icons.radar_rounded,
      label: 'Radarlar',
    ),
    _NavDestination(
      icon: Icons.tune_outlined,
      activeIcon: Icons.tune_rounded,
      label: 'Ayarlar',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      decoration: const BoxDecoration(color: NexColors.background),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: NexColors.surfaceAlt,
          borderRadius: BorderRadius.circular(NexRadius.xl),
          border: Border.all(color: NexColors.borderSoft),
          boxShadow: NexShadow.card,
        ),
        child: Row(
          children: List<Widget>.generate(_destinations.length, (int i) {
            final _NavDestination d = _destinations[i];
            final bool active = i == index;
            return Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => onSelect(i),
                  borderRadius: BorderRadius.circular(NexRadius.lg),
                  child: AnimatedContainer(
                    duration: NexMotion.base,
                    curve: NexMotion.emphasized,
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    decoration: BoxDecoration(
                      color: active
                          ? NexColors.primary.withValues(alpha: 0.12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(NexRadius.lg),
                      border: Border.all(
                        color: active
                            ? NexColors.primary.withValues(alpha: 0.30)
                            : Colors.transparent,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          active ? d.activeIcon : d.icon,
                          size: 22,
                          color: active
                              ? NexColors.primary
                              : NexColors.textLow,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          d.label,
                          style: TextStyle(
                            fontFamily: NexFont.text,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: active
                                ? NexColors.textHigh
                                : NexColors.textLow,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// Shared helper so every tab can show engine log lines through one snackbar.
extension ShellFeedback on BuildContext {
  void showNotice(String message) {
    ScaffoldMessenger.of(this)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Kept for tests / debugging: describes the running engine.
String describeEngine(RadarEngine engine) =>
    'NexRadar running=${engine.isRunning} '
    'cached=${engine.cameraCacheSize} '
    'state=${engine.state.value}';
