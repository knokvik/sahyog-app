import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/location_service.dart';
import '../../core/models.dart';
import '../../theme/app_colors.dart';

class MapTab extends StatefulWidget {
  const MapTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> with AutomaticKeepAliveClientMixin {
  final _locationService = LocationService();
  final MapController _mapController = MapController();

  LatLng _center = const LatLng(18.5204, 73.8567); // Pune default fallback
  LatLng? _userLocation;
  List<_ZoneCircle> _zones = [];
  final List<_ZoneCircle> _userMarkedZones = [];
  List<_ResourceMarker> _resources = [];
  bool _loading = true;
  String _error = '';
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
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

      try {
        // Just fetch but don't force move the map center here
        final pos = await _locationService.getCurrentPosition().timeout(
          const Duration(seconds: 4),
        );
        if (mounted) {
          setState(() => _userLocation = LatLng(pos.latitude, pos.longitude));
        }
      } catch (_) {}

      // Fetch zones, resources, and sos
      List<dynamic> zonesList = <dynamic>[];
      dynamic sosRaw;
      try {
        final disastersRaw = await widget.api.get('/api/v1/disasters');
        final disasters = disastersRaw is List ? disastersRaw : <dynamic>[];
        for (final d in disasters) {
          final disaster = d as Map<String, dynamic>;
          final id = (disaster['id'] ?? '').toString();
          if (id.isEmpty) continue;
          try {
            final reliefRaw = await widget.api.get(
              '/api/v1/disasters/$id/relief-zones',
            );
            if (reliefRaw is List) zonesList.addAll(reliefRaw);
          } catch (_) {}
        }
        if (zonesList.isEmpty) {
          final coordinatorZones = await widget.api.get(
            '/api/v1/coordinator/zones',
          );
          zonesList = coordinatorZones is List ? coordinatorZones : <dynamic>[];
        }
        sosRaw = await widget.api.get('/api/v1/coordinator/sos');
      } catch (_) {}

      final zones = <_ZoneCircle>[];

      for (final z in zonesList) {
        final zone = z as Map<String, dynamic>;
        final lat = parseLat(zone['center_lat']);
        final lng = parseLng(zone['center_lng']);
        if (lat == null || lng == null) continue;

        zones.add(
          _ZoneCircle(
            id: (zone['id'] ?? '').toString(),
            name: (zone['name'] ?? 'Zone').toString(),
            severity: (zone['severity'] ?? 'red').toString(),
            radiusMeters: parseLat(zone['radius_meters']) ?? 500,
            center: LatLng(lat, lng),
          ),
        );
      }

      final markers = <_ResourceMarker>[];

      final resourcesRaw = await widget.api.get('/api/v1/resources');
      final resources = resourcesRaw is List ? resourcesRaw : <dynamic>[];

      for (final item in resources) {
        final r = item as Map<String, dynamic>;
        final parsed = _parsePoint(r['current_location']);
        if (parsed == null) continue;
        markers.add(
          _ResourceMarker(
            id: (r['id'] ?? '').toString(),
            type: (r['type'] ?? 'Resource').toString(),
            status: (r['status'] ?? '').toString(),
            point: parsed,
          ),
        );
      }

      final sosAlerts = sosRaw is List ? sosRaw : <dynamic>[];
      for (final item in sosAlerts) {
        final s = item as Map<String, dynamic>;
        // Try parsing the item itself (for lat/lng top-level) or its location field
        final parsed = _parsePoint(s) ?? _parsePoint(s['location']);
        if (parsed == null) continue;
        markers.add(
          _ResourceMarker(
            id: (s['id'] ?? '').toString(),
            type: 'SOS',
            status: (s['status'] ?? '').toString(),
            point: parsed,
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _zones = zones;
        _resources = markers;
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

  LatLng? _parsePoint(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      final lat = parseLat(raw['lat']);
      final lng = parseLng(raw['lng']);
      if (lat != null && lng != null) return LatLng(lat, lng);

      if (raw['coordinates'] is List &&
          (raw['coordinates'] as List).length >= 2) {
        final coords = raw['coordinates'] as List;
        final lngFromCoords = parseLng(coords[0]);
        final latFromCoords = parseLat(coords[1]);
        if (latFromCoords != null && lngFromCoords != null) {
          return LatLng(latFromCoords, lngFromCoords);
        }
      }
    }

    if (raw is String && raw.startsWith('POINT(') && raw.endsWith(')')) {
      final parts = raw
          .replaceFirst('POINT(', '')
          .replaceFirst(')', '')
          .split(' ');
      if (parts.length == 2) {
        final lng = double.tryParse(parts[0]);
        final lat = double.tryParse(parts[1]);
        if (lat != null && lng != null) return LatLng(lat, lng);
      }
    }

    return null;
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // Keep map in memory, let FlutterMap's tile loader pull cached layers
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(
                  _error,
                  style: const TextStyle(color: AppColors.criticalRed),
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _zones.isNotEmpty
                          ? _zones.first.center
                          : _center,
                      initialZoom: 12,
                      onLongPress: (tapPosition, latLng) {
                        setState(() {
                          _userMarkedZones.add(
                            _ZoneCircle(
                              id: 'local-${DateTime.now().millisecondsSinceEpoch}',
                              name: 'User Marked Zone',
                              severity: 'blue',
                              radiusMeters: 250,
                              center: latLng,
                            ),
                          );
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Zone marker added (long-press).'),
                          ),
                        );
                      },
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.sahyog_app',
                      ),
                      // User Location Marker - Only show if we have successfully located
                      if (_userLocation != null)
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: _userLocation!,
                              width: 60,
                              height: 60,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.15),
                                          blurRadius: 10,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(
                                    Icons.gps_fixed,
                                    color: AppColors.primaryGreen,
                                    size: 26,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      CircleLayer(
                        circles: _zones
                            .map(
                              (z) => CircleMarker(
                                point: z.center,
                                radius: max(40, z.radiusMeters / 5),
                                useRadiusInMeter: true,
                                color: _severityColor(
                                  z.severity,
                                ).withValues(alpha: 0.16),
                                borderColor: _severityColor(z.severity),
                                borderStrokeWidth: 2,
                              ),
                            )
                            .toList(),
                      ),
                      CircleLayer(
                        circles: _userMarkedZones
                            .map(
                              (z) => CircleMarker(
                                point: z.center,
                                radius: z.radiusMeters,
                                useRadiusInMeter: true,
                                color: AppColors.primaryGreen.withValues(
                                  alpha: 0.16,
                                ),
                                borderColor: AppColors.primaryGreen,
                                borderStrokeWidth: 2,
                              ),
                            )
                            .toList(),
                      ),
                      MarkerLayer(
                        markers: _resources.map((r) {
                          final isSos = r.type == 'SOS';
                          return Marker(
                            point: r.point,
                            width: 120,
                            height: 60,
                            child: isSos
                                ? _SosMarker()
                                : Column(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              blurRadius: 6,
                                              color: Color(0x22000000),
                                            ),
                                          ],
                                        ),
                                        child: Text(
                                          r.type,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: Colors.black,
                                          ),
                                        ),
                                      ),
                                      const Icon(
                                        Icons.location_on,
                                        color: AppColors.primaryGreen,
                                        size: 26,
                                      ),
                                    ],
                                  ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                  Positioned(
                    right: 16,
                    bottom: 90, // moved up to avoid overlapping with FAB
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FloatingActionButton(
                          heroTag: "map_my_location",
                          mini: true,
                          onPressed: () async {
                            try {
                              final pos = await _locationService
                                  .getCurrentPosition()
                                  .timeout(const Duration(seconds: 10));
                              final ll = LatLng(pos.latitude, pos.longitude);
                              if (mounted) {
                                setState(() {
                                  _userLocation = ll;
                                });

                                // Detect San Francisco emulator default
                                final isEmulatorSF =
                                    (ll.latitude > 37.42 &&
                                        ll.latitude < 37.43) &&
                                    (ll.longitude > -122.09 &&
                                        ll.longitude < -122.08);

                                if (isEmulatorSF && _zones.isNotEmpty) {
                                  _mapController.move(_zones.first.center, 15);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Emulator detected. Staying in Pune.',
                                      ),
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                } else {
                                  _mapController.move(ll, 16);
                                }
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Could not locate device: $e',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.primaryGreen,
                          child: const Icon(Icons.gps_fixed),
                        ),
                        const SizedBox(height: 8),
                        FloatingActionButton(
                          heroTag: "map_zoom_in",
                          mini: true,
                          onPressed: () {
                            final zoom = _mapController.camera.zoom;
                            _mapController.move(
                              _mapController.camera.center,
                              zoom + 1,
                            );
                          },
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.primaryGreen,
                          child: const Icon(Icons.add),
                        ),
                        const SizedBox(height: 8),
                        FloatingActionButton(
                          heroTag: "map_zoom_out",
                          mini: true,
                          onPressed: () {
                            final zoom = _mapController.camera.zoom;
                            _mapController.move(
                              _mapController.camera.center,
                              zoom - 1,
                            );
                          },
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.primaryGreen,
                          child: const Icon(Icons.remove),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: 24,
                    left: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_loading)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primaryGreen,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black26,
                                  blurRadius: 4,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            child: const Row(
                              children: [
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Loading markers...',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).cardColor.withOpacity(0.95),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'ZONES',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  _CompactDot(
                                    color: AppColors.criticalRed,
                                    label: 'Red',
                                  ),
                                  const SizedBox(width: 12),
                                  _CompactDot(
                                    color: AppColors.warningAmber,
                                    label: 'Yellow',
                                  ),
                                  const SizedBox(width: 12),
                                  _CompactDot(
                                    color: AppColors.infoBlue,
                                    label: 'Blue',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'MARKERS',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  _CompactDot(
                                    color: AppColors.criticalRed,
                                    label: 'SOS',
                                  ),
                                  const SizedBox(width: 12),
                                  _CompactDot(
                                    color: AppColors.primaryGreen,
                                    label: 'User',
                                  ),
                                ],
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 6.0),
                                child: Divider(height: 1),
                              ),
                              Text(
                                'Items & SOS: ${_resources.length}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _load,
        backgroundColor: AppColors.primaryGreen,
        foregroundColor: Colors.white,
        child: const Icon(Icons.refresh),
      ),
    );
  }

  Color _severityColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'yellow':
        return AppColors.warningAmber;
      case 'blue':
        return AppColors.infoBlue;
      default:
        return AppColors.criticalRed;
    }
  }
}

class _CompactDot extends StatelessWidget {
  const _CompactDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(radius: 5, backgroundColor: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

class _ZoneCircle {
  _ZoneCircle({
    required this.id,
    required this.name,
    required this.severity,
    required this.radiusMeters,
    required this.center,
  });

  final String id;
  final String name;
  final String severity;
  final double radiusMeters;
  final LatLng center;
}

class _ResourceMarker {
  _ResourceMarker({
    required this.id,
    required this.type,
    required this.status,
    required this.point,
  });

  final String id;
  final String type;
  final String status;
  final LatLng point;
}

class _SosMarker extends StatefulWidget {
  @override
  State<_SosMarker> createState() => _SosMarkerState();
}

class _SosMarkerState extends State<_SosMarker>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            // Wave 1
            Opacity(
              opacity: (1.0 - t).clamp(0.0, 1.0),
              child: Container(
                width: 70 * t,
                height: 70 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.criticalRed, width: 1.5),
                ),
              ),
            ),
            // Wave 2
            Opacity(
              opacity: (1.0 - ((t + 0.33) % 1.0)).clamp(0.0, 1.0),
              child: Container(
                width: 70 * ((t + 0.33) % 1.0),
                height: 70 * ((t + 0.33) % 1.0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.criticalRed, width: 1.0),
                ),
              ),
            ),
            // Wave 3
            Opacity(
              opacity: (1.0 - ((t + 0.66) % 1.0)).clamp(0.0, 1.0),
              child: Container(
                width: 70 * ((t + 0.66) % 1.0),
                height: 70 * ((t + 0.66) % 1.0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.criticalRed, width: 0.5),
                ),
              ),
            ),
            // Pulse inner
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.criticalRed,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.criticalRed.withOpacity(0.8),
                    blurRadius: 8,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
