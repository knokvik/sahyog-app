import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/location_service.dart';
import '../../core/models.dart';
import '../../core/socket_service.dart';
import '../../core/database_helper.dart';
import '../../theme/app_colors.dart';
import '../search/app_search_delegate.dart';
import '../search/app_inline_search.dart';
import 'sos_alerts_panel.dart';
import 'emergency_sos_box.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({
    super.key,
    required this.api,
    required this.user,
    this.onNavigate,
  });

  final ApiClient api;
  final AppUser user;
  final void Function(int, {LatLng? target})? onNavigate;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  final _locationService = LocationService();
  final MapController _miniMapController = MapController();
  double _currentZoom = 12.0;

  Position? _position;
  bool _loading = true;
  String _error = '';
  List<Map<String, dynamic>> _zones = [];
  List<Map<String, dynamic>> _recentTasks = [];
  List<Map<String, dynamic>> _recentSos = [];
  Timer? _pollTimer;

  late final AnimationController _glowCtrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  final FocusNode _searchFocus = FocusNode();
  String _searchQuery = '';

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

      Position? pos;
      try {
        pos = await _locationService.getCurrentPosition().timeout(
          const Duration(seconds: 5),
        );
      } catch (_) {}

      final disastersRaw = await widget.api.get('/api/v1/disasters');
      final disasters = (disastersRaw is List)
          ? disastersRaw.cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];

      List<Map<String, dynamic>> zones = [];
      if (disasters.isNotEmpty) {
        final active = disasters.firstWhere(
          (d) => (d['status'] ?? '').toString() == 'active',
          orElse: () => disasters.first,
        );
        final id = (active['id'] ?? '').toString();
        if (id.isNotEmpty) {
          try {
            final zoneRaw = await widget.api.get(
              '/api/v1/disasters/$id/relief-zones',
            );
            zones = (zoneRaw is List)
                ? zoneRaw.cast<Map<String, dynamic>>()
                : <Map<String, dynamic>>[];
          } catch (_) {}
        }
      }

      List<Map<String, dynamic>> recentTasks = [];
      try {
        final tasksRaw = await widget.api.get('/api/v1/tasks/pending');
        recentTasks = (tasksRaw is List)
            ? tasksRaw.cast<Map<String, dynamic>>()
            : <Map<String, dynamic>>[];
      } catch (_) {}

      if (recentTasks.isEmpty) {
        try {
          final needsRaw = await widget.api.get('/api/v1/needs');
          final needs = (needsRaw is List)
              ? needsRaw.cast<Map<String, dynamic>>()
              : <Map<String, dynamic>>[];
          recentTasks = needs.take(5).map((n) {
            return {
              'title': n['type'] ?? 'Need',
              'status': n['status'] ?? 'unassigned',
              'description': n['description'] ?? 'No details',
            };
          }).toList();
        } catch (_) {}
      }

      List<Map<String, dynamic>> recentSos = [];
      try {
        final sosRaw = await widget.api.get('/api/v1/sos');
        if (sosRaw is List) {
          recentSos = sosRaw.cast<Map<String, dynamic>>().take(3).toList();
        }
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _position = pos;
        _zones = zones;
        _recentTasks = recentTasks.take(5).toList();
        _recentSos = recentSos;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
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
                  const SizedBox(height: 16),
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
                        GestureDetector(
                          onTap: () {
                            widget.onNavigate?.call(1);
                          },
                          child: Card(
                            clipBehavior: Clip.antiAlias,
                            child: SizedBox(
                              height: 200,
                              child: _buildMiniMap(),
                            ),
                          ),
                        ),
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
                                            widget.onNavigate?.call(3),
                                      );
                                    }
                                  });
                            }
                          },
                          onSosLocationTap: (ll) =>
                              widget.onNavigate?.call(1, target: ll),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Recent Tasks',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        if (_recentTasks.isEmpty)
                          const Card(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('No recent tasks found.'),
                            ),
                          )
                        else
                          ..._recentTasks.map((task) {
                            final title =
                                (task['title'] ?? task['type'] ?? 'Task')
                                    .toString();
                            final status = (task['status'] ?? 'pending')
                                .toString();
                            final desc = (task['description'] ?? '').toString();
                            return Card(
                              child: ListTile(
                                leading: const CircleAvatar(
                                  backgroundColor: AppColors.primaryGreen,
                                  foregroundColor: Colors.white,
                                  child: Icon(Icons.assignment_turned_in),
                                ),
                                title: Text(title),
                                subtitle: Text(
                                  desc.isEmpty ? 'No description' : desc,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Chip(
                                  label: Text(
                                    status.toUpperCase(),
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                ),
                              ),
                            );
                          }),
                        const SizedBox(height: 16),
                        Text(
                          'Recent SOS',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        if (_recentSos.isEmpty)
                          const Card(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('No recent SOS found.'),
                            ),
                          )
                        else
                          ..._recentSos.map((sos) {
                            final status = (sos['status'] ?? 'active')
                                .toString();
                            return Card(
                              child: ListTile(
                                leading: const CircleAvatar(
                                  backgroundColor: AppColors.criticalRed,
                                  foregroundColor: Colors.white,
                                  child: Icon(Icons.sos),
                                ),
                                title: Text(
                                  (sos['reporter_name'] ??
                                          sos['volunteer_name'] ??
                                          'Unknown')
                                      .toString(),
                                ),
                                trailing: Chip(
                                  label: Text(
                                    status.toUpperCase(),
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                ),
                                onTap: () {
                                  DefaultTabController.of(context).animateTo(1);
                                },
                              ),
                            );
                          }),
                        const SizedBox(height: 32),
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
                              widget.onNavigate?.call(2); // Tasks
                              break;
                            case SearchCategory.sos:
                              widget.onNavigate?.call(3); // SOS Operations
                              break;
                            case SearchCategory.zone:
                              final lat = double.tryParse(
                                (result.raw['center_lat'] ?? '').toString(),
                              );
                              final lng = double.tryParse(
                                (result.raw['center_lng'] ?? '').toString(),
                              );
                              if (lat != null && lng != null) {
                                widget.onNavigate?.call(
                                  1,
                                  target: LatLng(lat, lng),
                                );
                              } else {
                                widget.onNavigate?.call(1);
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
                  hintText: 'Search tasks, SOS...',
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

  Widget _buildMiniMap() {
    LatLng center = const LatLng(18.5204, 73.8567);
    if (_position != null) {
      center = LatLng(_position!.latitude, _position!.longitude);
    } else if (_zones.isNotEmpty) {
      final lat = parseLat(_zones.first['center_lat']);
      final lng = parseLng(_zones.first['center_lng']);
      if (lat != null && lng != null) center = LatLng(lat, lng);
    }

    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      children: [
        Container(
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
              if (_position != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(_position!.latitude, _position!.longitude),
                      width: 34,
                      height: 34,
                      child: const Icon(
                        Icons.my_location,
                        color: AppColors.primaryGreen,
                        size: 28,
                      ),
                    ),
                  ],
                ),
              CircleLayer(
                circles: _zones.map((zone) {
                  final lat = parseLat(zone['center_lat']);
                  final lng = parseLng(zone['center_lng']);
                  if (lat == null || lng == null) {
                    return const CircleMarker(point: LatLng(0, 0), radius: 0);
                  }
                  final severity = (zone['severity'] ?? 'red').toString();
                  final radius = parseLat(zone['radius_meters']) ?? 500;
                  final color = _severityColor(severity);
                  return CircleMarker(
                    point: LatLng(lat, lng),
                    radius: radius,
                    useRadiusInMeter: true,
                    color: color.withValues(alpha: 0.18),
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

  Widget _buildStatsRow() {
    final items = [
      ('Tasks', _recentTasks.length, Icons.assignment, Colors.blueAccent, 2),
      ('SOS', 0, Icons.sos, AppColors.criticalRed, 2),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: items.map((item) {
          final (label, value, _, color, tabIndex) = item;
          final displayValue = (label == 'SOS')
              ? SocketService.instance.liveSosAlerts.value.length
              : value;

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
                                  widget.onNavigate?.call(tabIndex),
                            );
                          }
                        });
                  } else {
                    widget.onNavigate?.call(tabIndex);
                  }
                } else {
                  widget.onNavigate?.call(tabIndex);
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

                              if (child.key == ValueKey<int>(displayValue)) {
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
                          '$displayValue',
                          key: ValueKey<int>(displayValue),
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
}
