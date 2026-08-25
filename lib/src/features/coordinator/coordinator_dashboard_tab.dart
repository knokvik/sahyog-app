import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../theme/app_colors.dart';
import '../home/emergency_sos_box.dart';
import '../home/sos_alerts_panel.dart';
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

class _CoordinatorDashboardTabState extends State<CoordinatorDashboardTab> {
  final MapController _miniMapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  bool _loading = true;
  String _error = '';
  String _searchQuery = '';
  bool _isSearchExpanded = false;
  Timer? _pollTimer;

  Map<String, dynamic> _ctx = {};
  List<Map<String, dynamic>> _recentSos = [];
  List<Map<String, dynamic>> _recentTasks = [];
  List<Map<String, dynamic>> _zones = [];

  double _currentZoom = 12.0;

  @override
  void initState() {
    super.initState();
    _load();
    _searchFocusNode.addListener(() {
      if (_searchFocusNode.hasFocus) {
        setState(() => _isSearchExpanded = true);
      } else if (_searchController.text.isEmpty) {
        setState(() => _isSearchExpanded = false);
      }
    });
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
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
    return GestureDetector(
      onTap: () {
        if (_searchFocusNode.hasFocus) {
          _searchFocusNode.unfocus();
          if (_searchController.text.isEmpty) {
            setState(() => _isSearchExpanded = false);
          }
        }
      },
      behavior: HitTestBehavior.translucent,
      child: Scaffold(
        body: Column(
          children: [
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildTopSearchAndMapArea(),
                    const SizedBox(height: 12),
                    if (_error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Text(
                          _error,
                          style: const TextStyle(color: AppColors.criticalRed),
                        ),
                      ),
                    _buildStatsRow(),
                    const SizedBox(height: 12),
                    EmergencySosBox(
                      user: widget.user,
                      api: widget.api,
                      onSosTap: () {
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
                                    onGoToSosPanels: () => widget.onNavigate(3),
                                  );
                                }
                              });
                        }
                      },
                      onSosLocationTap: (ll) => widget.onNavigate(3, target: ll),
                    ),
                    const SizedBox(height: 12),
                    _buildRecentTasks(),
                    const SizedBox(height: 12),
                    _buildRecentSos(),
                    const SizedBox(height: 80), // Padding for FAB
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopSearchAndMapArea() {
    return SizedBox(
      height: 246,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 66,
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildMiniMap(),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildHeader(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final String initial = widget.user.name.isNotEmpty
        ? widget.user.name[0].toUpperCase()
        : 'N';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOutCubic,
      height: _isSearchExpanded ? 246 : 56,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(_isSearchExpanded ? 20 : 32),
        border: Border.all(
          color: _isSearchExpanded
              ? AppColors.primaryGreen.withValues(alpha: 0.6)
              : Colors.grey.withValues(alpha: 0.25),
          width: _isSearchExpanded ? 1.6 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: _isSearchExpanded
                ? AppColors.primaryGreen.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.03),
            blurRadius: _isSearchExpanded ? 12 : 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          SizedBox(
            height: 52,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: _isSearchExpanded ? 14 : 10,
                vertical: 2,
              ),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 2, right: 12),
                    child: _AnimatedAvatarRing(initial: initial),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      onChanged: (val) => setState(() => _searchQuery = val),
                      decoration: const InputDecoration(
                        hintText: 'Search alerts, tasks...',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  if (_isSearchExpanded || _searchController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.close, size: 20, color: Colors.grey),
                      onPressed: () {
                        _searchController.clear();
                        _searchFocusNode.unfocus();
                        setState(() {
                          _searchQuery = '';
                          _isSearchExpanded = false;
                        });
                      },
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.only(right: 8.0),
                      child: Icon(Icons.search, color: Colors.grey),
                    ),
                ],
              ),
            ),
          ),
          if (_isSearchExpanded) ...[
            Divider(
              height: 1,
              thickness: 1,
              color: Colors.grey.withValues(alpha: 0.15),
            ),
            Expanded(
              child: _buildSearchResultsContent(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchResultsContent() {
    final query = _searchQuery.trim().toLowerCase();

    final matchingSos = _recentSos.where((s) {
      final name = (s['reporter_name'] ?? s['name'] ?? '').toString().toLowerCase();
      final type = (s['type'] ?? '').toString().toLowerCase();
      return name.contains(query) || type.contains(query);
    }).toList();

    final matchingTasks = _recentTasks.where((t) {
      final title = (t['title'] ?? t['description'] ?? '').toString().toLowerCase();
      return title.contains(query);
    }).toList();

    final matchingZones = _zones.where((z) {
      final name = (z['name'] ?? z['disaster_name'] ?? '').toString().toLowerCase();
      return name.contains(query);
    }).toList();

    final int totalMatches = matchingSos.length + matchingTasks.length + matchingZones.length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: query.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.manage_search, size: 36, color: AppColors.primaryGreen.withValues(alpha: 0.6)),
                  const SizedBox(height: 6),
                  const Text(
                    'Search alerts, relief tasks, or disaster zones',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            )
          : totalMatches == 0
              ? const Center(
                  child: Text(
                    'No matching incidents or tasks found',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                )
              : Material(
                  color: Colors.transparent,
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      if (matchingSos.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 4),
                          child: Text(
                            'SOS ALERTS',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: AppColors.criticalRed,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                        ...matchingSos.map((sos) => ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                              leading: CircleAvatar(
                                radius: 14,
                                backgroundColor: AppColors.criticalRed.withValues(alpha: 0.15),
                                child: const Icon(Icons.sos, color: AppColors.criticalRed, size: 16),
                              ),
                              title: Text(
                                sos['reporter_name'] ?? sos['type'] ?? 'SOS Alert',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                sos['status'] ?? 'triggered',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded, size: 18, color: Colors.grey),
                              onTap: () => widget.onNavigate(3),
                            )),
                      ],
                      if (matchingTasks.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 4),
                          child: Text(
                            'TASKS',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.blueAccent,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                        ...matchingTasks.map((t) => ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                              leading: CircleAvatar(
                                radius: 14,
                                backgroundColor: Colors.blueAccent.withValues(alpha: 0.15),
                                child: const Icon(Icons.assignment, color: Colors.blueAccent, size: 16),
                              ),
                              title: Text(
                                t['title'] ?? 'Task',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                t['status'] ?? 'pending',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded, size: 18, color: Colors.grey),
                              onTap: () => widget.onNavigate(2),
                            )),
                      ],
                      if (matchingZones.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 4),
                          child: Text(
                            'RELIEF ZONES',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.orange,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                        ...matchingZones.map((z) => ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                              leading: CircleAvatar(
                                radius: 14,
                                backgroundColor: Colors.orange.withValues(alpha: 0.15),
                                child: const Icon(Icons.hub, color: Colors.orange, size: 16),
                              ),
                              title: Text(
                                z['name'] ?? 'Zone',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded, size: 18, color: Colors.grey),
                              onTap: () => widget.onNavigate(1),
                            )),
                      ],
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
      (
        'Needs',
        stats['active_needs'] ?? 0,
        Icons.report_problem,
        Colors.orange,
        12, // Index for Needs tab
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
                          if (mounted) {
                            SosAlertsPanel.show(
                              context: context,
                              alerts: alerts,
                              activeLocalUuid: active?.uuid,
                              onCancelSos: null,
                              onGoToSosPanels: () =>
                                  widget.onNavigate(tabIndex),
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
                  circles: _zones.map((zone) {
                    final lat = parseLat(zone['center_lat']);
                    final lng = parseLng(zone['center_lng']);
                    if (lat == null || lng == null) {
                      return CircleMarker(point: const LatLng(0, 0), radius: 0);
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
                  }).toList(),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent Tasks',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (filtered.isNotEmpty)
                Text(
                  '${filtered.length} total',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (filtered.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text('No recent tasks.', style: TextStyle(color: Colors.grey)),
            ),
          )
        else
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final task = filtered[i];
                final title = (task['title'] ?? task['type'] ?? 'Task').toString();
                final status = (task['status'] ?? 'pending').toString();
                final isDone = status == 'completed' || status == 'resolved';
                final isPending = status == 'pending';

                return Container(
                  constraints: const BoxConstraints(minWidth: 160, maxWidth: 220),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.grey.withValues(alpha: 0.2),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.02),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: isDone
                            ? AppColors.primaryGreen.withValues(alpha: 0.15)
                            : isPending
                                ? Colors.amber.withValues(alpha: 0.15)
                                : Colors.blue.withValues(alpha: 0.15),
                        child: Icon(
                          isDone
                              ? Icons.check_circle_outline
                              : isPending
                                  ? Icons.pending_actions
                                  : Icons.directions_run,
                          size: 18,
                          color: isDone
                              ? AppColors.primaryGreen
                              : isPending
                                  ? Colors.amber.shade800
                                  : Colors.blue.shade700,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              status.toUpperCase(),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: isDone
                                    ? AppColors.primaryGreen
                                    : isPending
                                        ? Colors.amber.shade800
                                        : Colors.blue.shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent SOS Alerts',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (filtered.isNotEmpty)
                Text(
                  '${filtered.length} active',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (filtered.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text('No SOS alerts.', style: TextStyle(color: Colors.grey)),
            ),
          )
        else
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final sos = filtered[i];
                final status = (sos['status'] ?? 'triggered').toString();
                final isActive = status == 'triggered';
                final name = (sos['reporter_name'] ?? sos['volunteer_name'] ?? 'Citizen Alert').toString();

                return InkWell(
                  onTap: () {
                    widget.onNavigate(1);
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 165, maxWidth: 230),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isActive
                            ? AppColors.criticalRed.withValues(alpha: 0.3)
                            : Colors.grey.withValues(alpha: 0.2),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isActive
                              ? AppColors.criticalRed.withValues(alpha: 0.04)
                              : Colors.black.withValues(alpha: 0.02),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: isActive
                              ? AppColors.criticalRed.withValues(alpha: 0.15)
                              : Colors.grey.withValues(alpha: 0.15),
                          child: Icon(
                            isActive ? Icons.sos : Icons.check_circle_outline,
                            size: 18,
                            color: isActive
                                ? AppColors.criticalRed
                                : Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                isActive ? 'LIVE ALERT' : status.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: isActive
                                      ? AppColors.criticalRed
                                      : Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
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

class _AnimatedAvatarRing extends StatefulWidget {
  const _AnimatedAvatarRing({required this.initial});
  final String initial;

  @override
  State<_AnimatedAvatarRing> createState() => _AnimatedAvatarRingState();
}

class _AnimatedAvatarRingState extends State<_AnimatedAvatarRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cardColor = Theme.of(context).cardColor;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              transform: GradientRotation(_ctrl.value * 2 * 3.14159265),
              colors: [
                Colors.grey.withValues(alpha: 0.15),
                Colors.grey.withValues(alpha: 0.85),
                Colors.grey.withValues(alpha: 0.15),
              ],
            ),
          ),
          padding: const EdgeInsets.all(1.8),
          child: Container(
            padding: const EdgeInsets.all(2.2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cardColor,
            ),
            child: CircleAvatar(
              backgroundColor: AppColors.primaryGreen,
              foregroundColor: Colors.white,
              child: Text(
                widget.initial,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
