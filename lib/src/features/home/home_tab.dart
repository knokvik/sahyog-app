import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/location_service.dart';
import '../../core/models.dart';
import '../../theme/app_colors.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key, required this.api, required this.user});

  final ApiClient api;
  final AppUser user;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with AutomaticKeepAliveClientMixin {
  final _locationService = LocationService();
  final MapController _miniMapController = MapController();

  Position? _position;
  bool _loading = true;
  String _error = '';
  List<Map<String, dynamic>> _zones = [];
  List<Map<String, dynamic>> _recentTasks = [];
  List<Map<String, dynamic>> _recentSos = [];
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
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
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const SizedBox(height: 8),
                _RoleChip(role: widget.user.role),
                const SizedBox(height: 16),
                if (_error.isNotEmpty)
                  Text(
                    _error,
                    style: const TextStyle(color: AppColors.criticalRed),
                  ),
                GestureDetector(
                  onTap: () {
                    DefaultTabController.of(context).animateTo(1);
                  },
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(height: 200, child: _buildMiniMap()),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Recent Tasks',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
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
                    final title = (task['title'] ?? task['type'] ?? 'Task')
                        .toString();
                    final status = (task['status'] ?? 'pending').toString();
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
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
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
                    final status = (sos['status'] ?? 'active').toString();
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
          ),
        ),
      ],
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

    return Stack(
      children: [
        FlutterMap(
          mapController: _miniMapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 12,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.none,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.sahyog_app',
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

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.primaryGreen.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          role.toUpperCase(),
          style: const TextStyle(
            color: AppColors.primaryGreen,
            fontWeight: FontWeight.w800,
            fontSize: 12,
            letterSpacing: 1.1,
          ),
        ),
      ),
    );
  }
}
