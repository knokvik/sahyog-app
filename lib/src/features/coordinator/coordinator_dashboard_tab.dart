import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../theme/app_colors.dart';
import '../home/emergency_sos_box.dart';
import '../home/sos_alerts_panel.dart';
import '../search/app_search_delegate.dart';
import '../search/app_inline_search.dart';
import '../../core/socket_service.dart';
import '../../core/database_helper.dart';

class CoordinatorDashboardTab extends StatefulWidget {
  const CoordinatorDashboardTab({
    super.key,
    required this.api,
    required this.user,
    required this.onNavigate,
  });

  final ApiClient api;
  final AppUser user;
  final void Function(int, {LatLng? target}) onNavigate;

  @override
  State<CoordinatorDashboardTab> createState() =>
      _CoordinatorDashboardTabState();
}

class _CoordinatorDashboardTabState extends State<CoordinatorDashboardTab>
    with SingleTickerProviderStateMixin {
  final MapController _miniMapController = MapController();

  late final AnimationController _glowCtrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  final FocusNode _searchFocus = FocusNode();

  bool _loading = true;
  String _error = '';
  String _searchQuery = '';
  Timer? _pollTimer;

  Map<String, dynamic> _ctx = {};
  List<Map<String, dynamic>> _recentSos = [];
  List<Map<String, dynamic>> _recentTasks = [];
  List<Map<String, dynamic>> _zones = [];
  List<Map<String, dynamic>> _allZones = [];

  double _currentZoom = 12.0;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) _load(silent: true);
    });
    _searchFocus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _glowCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      if (!silent) {
        setState(() {
          _loading = true;
          _error = '';
        });
      }

      final results = await Future.wait([
        widget.api.get('/api/v1/coordinator/context'),
        widget.api.get('/api/v1/coordinator/sos'),
        widget.api.get('/api/v1/coordinator/tasks'),
        widget.api.get('/api/v1/coordinator/my-zones'),
        widget.api.get('/api/v1/coordinator/zones'),
      ]);

      if (!mounted) return;
      setState(() {
        _ctx = (results[0] is Map<String, dynamic>)
            ? results[0] as Map<String, dynamic>
            : {};

        final sosList = (results[1] is List) ? results[1] as List : [];
        _recentSos = sosList
            .take(5)
            .map((e) => e as Map<String, dynamic>)
            .toList();

        final tasksList = (results[2] is List) ? results[2] as List : [];
        _recentTasks = tasksList
            .take(5)
            .map((e) => e as Map<String, dynamic>)
            .toList();

        final zonesList = (results[3] is List) ? results[3] as List : [];
        _zones = zonesList.map((e) => e as Map<String, dynamic>).toList();

        final allZonesList = (results[4] is List) ? results[4] as List : [];
        _allZones = allZonesList.map((e) => e as Map<String, dynamic>).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 10),
                    AnimatedCrossFade(
                      duration: const Duration(milliseconds: 300),
                      crossFadeState: _searchFocus.hasFocus
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                      firstChild: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_error.isNotEmpty)
                            Text(
                              _error,
                              style: const TextStyle(
                                color: AppColors.criticalRed,
                              ),
                            ),
                          _buildMiniMap(),
                          const SizedBox(height: 12),
                          _buildStatsRow(),
                          const SizedBox(height: 12),
                          EmergencySosBox(
                            user: widget.user,
                            api: widget.api,
                            onSosTap: () {
                              final alerts =
                                  SocketService.instance.liveSosAlerts.value;
                              if (alerts.isNotEmpty) {
                                DatabaseHelper.instance
                                    .getActiveIncident(widget.user.id)
                                    .then((active) {
                                      if (context.mounted) {
                                        SosAlertsPanel.show(
                                          context: context,
                                          alerts: alerts,
                                          activeLocalUuid: active?.uuid,
                                          onCancelSos: null,
                                          onGoToSosPanels: () =>
                                              widget.onNavigate(3),
                                          onSosLocationTap: (lat, lng) {
                                            widget.onNavigate(
                                              1,
                                              target: LatLng(lat, lng),
                                            );
                                          },
                                        );
                                      }
                                    });
                              }
                            },
                            onSosLocationTap: (ll) =>
                                widget.onNavigate(3, target: ll),
                          ),
                          const SizedBox(height: 12),
                          _buildRecentTasks(),
                          const SizedBox(height: 12),
                          _buildRecentSos(),
                          const SizedBox(height: 80), // Padding for FAB
                        ],
                      ),
                      secondChild: SizedBox(
                        height: MediaQuery.of(context).size.height * 0.7,
                        child: InlineSearchResults(
                          api: widget.api,
                          query: _searchQuery,
                          onResultTap: (result) {
                            _searchFocus.unfocus();
                            switch (result.category) {
                              case SearchCategory.volunteer:
                              case SearchCategory.task:
                                widget.onNavigate(
                                  10,
                                ); // Operations > Tasks / Volunteers
                                break;
                              case SearchCategory.sos:
                                widget.onNavigate(3); // SOS Operations
                                break;
                              case SearchCategory.zone:
                                final lat = double.tryParse(
                                  (result.raw['center_lat'] ?? '').toString(),
                                );
                                final lng = double.tryParse(
                                  (result.raw['center_lng'] ?? '').toString(),
                                );
                                if (lat != null && lng != null) {
                                  widget.onNavigate(
                                    1,
                                    target: LatLng(lat, lng),
                                  );
                                } else {
                                  widget.onNavigate(1);
                                }
                                break;
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(30),
        side: BorderSide(
          color: _searchFocus.hasFocus
              ? AppColors.primaryGreen.withOpacity(0.5)
              : Colors.grey.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: [
            AnimatedBuilder(
              animation: _glowCtrl,
              builder: (context, child) {
                return Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      colors: [
                        Colors.transparent,
                        _searchFocus.hasFocus
                            ? AppColors.primaryGreen
                            : Colors.grey.shade400,
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.5, 1.0],
                      transform: GradientRotation(
                        _glowCtrl.value * 2 * 3.14159,
                      ),
                    ),
                  ),
                  padding: const EdgeInsets.all(2.5),
                  child: CircleAvatar(
                    backgroundColor: Colors.white,
                    radius: 19,
                    child: CircleAvatar(
                      backgroundColor: AppColors.primaryGreen,
                      foregroundColor: Colors.white,
                      radius: 17,
                      child: Text(
                        widget.user.name.isNotEmpty
                            ? widget.user.name[0].toUpperCase()
                            : '?',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                focusNode: _searchFocus,
                onChanged: (val) => setState(() => _searchQuery = val),
                decoration: const InputDecoration(
                  hintText: 'Search alerts, tasks...',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            if (_searchFocus.hasFocus)
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.clear, color: Colors.grey),
                onPressed: () {
                  setState(() {
                    _searchQuery = '';
                  });
                  if (_searchQuery.isEmpty) {
                    _searchFocus.unfocus();
                  }
                },
              )
            else
              const Icon(Icons.search, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsRow() {
    final stats = (_ctx['stats'] is Map<String, dynamic>)
        ? _ctx['stats'] as Map<String, dynamic>
        : {};
    final items = [
      (
        'Volunteers',
        stats['volunteers'] ?? 0,
        Icons.people_alt,
        AppColors.primaryGreen,
        10, // Index for Volunteers tab
      ),
      (
        'Tasks',
        _recentTasks.length,
        Icons.assignment,
        Colors.blueAccent,
        11, // Index for Tasks tab
      ),
      ('SOS', _recentSos.length, Icons.sos, AppColors.criticalRed, 3),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: items.map((item) {
          final (label, value, _, color, tabIndex) = item;
          return Expanded(
            child: InkWell(
              onTap: () {
                if (label == 'SOS') {
                  final alerts = SocketService.instance.liveSosAlerts.value;
                  if (alerts.isNotEmpty) {
                    DatabaseHelper.instance
                        .getActiveIncident(widget.user.id)
                        .then((active) {
                          if (context.mounted) {
                            SosAlertsPanel.show(
                              context: context,
                              alerts: alerts,
                              activeLocalUuid: active?.uuid,
                              onCancelSos: null,
                              onGoToSosPanels: () =>
                                  widget.onNavigate(tabIndex),
                              onSosLocationTap: (lat, lng) {
                                widget.onNavigate(1, target: LatLng(lat, lng));
                              },
                            );
                          }
                        });
                  } else {
                    widget.onNavigate(tabIndex);
                  }
                } else {
                  widget.onNavigate(tabIndex);
                }
              },
              borderRadius: BorderRadius.circular(16),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: Colors.grey.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 4,
                  ),
                  child: Column(
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 600),
                        transitionBuilder:
                            (Widget child, Animation<double> animation) {
                              final inAnimation = Tween<Offset>(
                                begin: const Offset(0.0, 1.0),
                                end: Offset.zero,
                              ).animate(animation);
                              final outAnimation = Tween<Offset>(
                                begin: const Offset(0.0, -1.0),
                                end: Offset.zero,
                              ).animate(animation);

                              if (child.key == ValueKey<int>(value)) {
                                return ClipRect(
                                  child: SlideTransition(
                                    position: inAnimation,
                                    child: FadeTransition(
                                      opacity: animation,
                                      child: child,
                                    ),
                                  ),
                                );
                              } else {
                                return ClipRect(
                                  child: SlideTransition(
                                    position: outAnimation,
                                    child: FadeTransition(
                                      opacity: animation,
                                      child: child,
                                    ),
                                  ),
                                );
                              }
                            },
                        child: Text(
                          '$value',
                          key: ValueKey<int>(value),
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMiniMap() {
    LatLng center = const LatLng(18.5204, 73.8567);
    if (_zones.isNotEmpty) {
      final first = _zones.first;
      final lat = parseLat(first['center_lat']);
      final lng = parseLng(first['center_lng']);
      if (lat != null && lng != null) {
        center = LatLng(lat, lng);
      }
    }

    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Container(
            height: 180,
            color: isDark ? const Color(0xFF1B1B1B) : Colors.grey[200],
            child: FlutterMap(
              mapController: _miniMapController,
              options: MapOptions(
                initialCenter: center,
                initialZoom: _currentZoom,
                minZoom: 3,
                maxZoom: 18,
                onPositionChanged: (pos, hasGesture) {
                  if (hasGesture) {
                    setState(() {
                      _currentZoom = pos.zoom;
                    });
                  }
                },
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.sahyog_app',
                  tileDisplay: const TileDisplay.fadeIn(),
                  tileBuilder: isDark ? _darkTileBuilder : null,
                ),
                CircleLayer(
                  circles: [
                    // All zones (muted grey) — other coordinators' zones
                    ..._allZones.map((zone) {
                      final lat = parseLat(zone['center_lat']);
                      final lng = parseLng(zone['center_lng']);
                      if (lat == null || lng == null) {
                        return CircleMarker(
                          point: const LatLng(0, 0),
                          radius: 0,
                        );
                      }
                      final myZoneIds = _zones
                          .map((z) => z['id']?.toString())
                          .toSet();
                      if (myZoneIds.contains(zone['id']?.toString())) {
                        return CircleMarker(
                          point: const LatLng(0, 0),
                          radius: 0,
                        );
                      }
                      final radius = parseLat(zone['radius_meters']) ?? 400;
                      return CircleMarker(
                        point: LatLng(lat, lng),
                        radius: radius,
                        useRadiusInMeter: true,
                        color: Colors.grey.withValues(alpha: 0.08),
                        borderColor: Colors.grey.withValues(alpha: 0.4),
                        borderStrokeWidth: 1.5,
                      );
                    }),
                    // My assigned zones (bold severity colors)
                    ..._zones.map((zone) {
                      final lat = parseLat(zone['center_lat']);
                      final lng = parseLng(zone['center_lng']);
                      if (lat == null || lng == null) {
                        return CircleMarker(
                          point: const LatLng(0, 0),
                          radius: 0,
                        );
                      }
                      final severity = (zone['severity'] ?? 'red').toString();
                      final radius = parseLat(zone['radius_meters']) ?? 400;
                      final color = _severityColor(severity);
                      return CircleMarker(
                        point: LatLng(lat, lng),
                        radius: radius,
                        useRadiusInMeter: true,
                        color: color.withValues(alpha: 0.16),
                        borderColor: color,
                        borderStrokeWidth: 2,
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
          if (_currentZoom >= 17.9)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  '100% ZOOM',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _darkTileBuilder(
    BuildContext context,
    Widget tileWidget,
    TileImage tile,
  ) {
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix([
        -1.0,
        0.0,
        0.0,
        0.0,
        255.0,
        0.0,
        -1.0,
        0.0,
        0.0,
        255.0,
        0.0,
        0.0,
        -1.0,
        0.0,
        255.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
      ]),
      child: tileWidget,
    );
  }

  double? parseLat(dynamic val) {
    if (val == null) return null;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString());
  }

  double? parseLng(dynamic val) {
    return parseLat(val);
  }

  Widget _buildRecentTasks() {
    final filtered = _searchQuery.isEmpty
        ? _recentTasks
        : _recentTasks.where((task) {
            final title = (task['title'] ?? task['type'] ?? '')
                .toString()
                .toLowerCase();
            final status = (task['status'] ?? '').toString().toLowerCase();
            return title.contains(_searchQuery.toLowerCase()) ||
                status.contains(_searchQuery.toLowerCase());
          }).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recent Tasks',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            if (filtered.isEmpty)
              const Text('No tasks.', style: TextStyle(color: Colors.grey))
            else
              ...filtered.map((task) {
                final title = (task['title'] ?? task['type'] ?? 'Task')
                    .toString();
                final status = (task['status'] ?? 'pending').toString();
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      Text(
                        status.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentSos() {
    final filtered = _searchQuery.isEmpty
        ? _recentSos
        : _recentSos.where((sos) {
            final name = (sos['reporter_name'] ?? sos['volunteer_name'] ?? '')
                .toString()
                .toLowerCase();
            final status = (sos['status'] ?? '').toString().toLowerCase();
            return name.contains(_searchQuery.toLowerCase()) ||
                status.contains(_searchQuery.toLowerCase());
          }).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recent SOS Alerts',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            if (filtered.isEmpty)
              const Text('No SOS alerts.', style: TextStyle(color: Colors.grey))
            else
              ...filtered.map((sos) {
                final status = (sos['status'] ?? 'triggered').toString();
                final name =
                    (sos['reporter_name'] ?? sos['volunteer_name'] ?? 'Unknown')
                        .toString();
                return InkWell(
                  onTap: () {
                    // Navigate to map tab
                    widget.onNavigate(1);
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.criticalRed,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        Text(
                          status.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.grey,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Color _severityColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'yellow':
        return Colors.amber;
      case 'blue':
        return Colors.blue;
      default:
        return AppColors.criticalRed;
    }
  }
}
