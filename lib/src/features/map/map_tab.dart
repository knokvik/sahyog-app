import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
import '../../core/location_service.dart';
import '../../core/live_location_service.dart';
import '../../core/models.dart';
import '../../core/socket_service.dart';
import '../../theme/app_colors.dart';

class MapTab extends StatefulWidget {
  const MapTab({
    super.key,
    required this.api,
    this.initialTarget,
    this.detailedHeatmap = false,
  });

  final ApiClient api;
  final LatLng? initialTarget;
  final bool detailedHeatmap;

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
  List<_HeatmapPoint> _heatmapPoints = [];
  List<_ShelterPin> _shelterPins = [];
  bool _loading = true;
  String _error = '';
  Timer? _pollTimer;
  double _currentZoom = 12.0;

  bool _isMapReady = false;

  bool get _isPublicHeatmapMode => !widget.detailedHeatmap;

  @override
  void initState() {
    super.initState();
    _syncHeatmapFromSocket();
    SocketService.instance.liveHeatmapPoints.addListener(
      _onHeatmapSocketUpdate,
    );
    SocketService.instance.liveShelterPins.addListener(_onHeatmapSocketUpdate);
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) _load(silent: true);
    });
  }

  void _handleInitialTarget() {
    if (widget.initialTarget != null && _isMapReady) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          _mapController.move(widget.initialTarget!, 16);
        }
      });
    }
  }

  @override
  void didUpdateWidget(MapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTarget != null &&
        widget.initialTarget != oldWidget.initialTarget) {
      _handleInitialTarget();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    SocketService.instance.liveHeatmapPoints.removeListener(
      _onHeatmapSocketUpdate,
    );
    SocketService.instance.liveShelterPins.removeListener(
      _onHeatmapSocketUpdate,
    );
    super.dispose();
  }

  void _onHeatmapSocketUpdate() {
    if (!mounted) return;
    _syncHeatmapFromSocket();
  }

  void _syncHeatmapFromSocket() {
    final incomingPoints = SocketService.instance.liveHeatmapPoints.value;
    final incomingShelters = SocketService.instance.liveShelterPins.value;

    final parsedPoints = incomingPoints
        .map((item) {
          final lat = parseLat(item['lat']);
          final lng = parseLng(item['lng']);
          if (lat == null || lng == null) return null;

          final count = parseLat(item['count']) ?? 1;
          final severity = parseLat(item['severity']) ?? 1;

          return _HeatmapPoint(
            point: LatLng(lat, lng),
            count: count,
            severity: severity.clamp(1, 10),
          );
        })
        .whereType<_HeatmapPoint>()
        .toList(growable: false);

    final parsedShelters = incomingShelters
        .map((item) {
          final lat = parseLat(item['lat']);
          final lng = parseLng(item['lng']);
          if (lat == null || lng == null) return null;

          return _ShelterPin(
            id: (item['id'] ?? '${lat}_$lng').toString(),
            name: (item['name'] ?? 'Shelter').toString(),
            point: LatLng(lat, lng),
            capacity: item['capacity'],
            occupancy: item['occupancy'],
          );
        })
        .whereType<_ShelterPin>()
        .toList(growable: false);

    setState(() {
      _heatmapPoints = parsedPoints;
      _shelterPins = parsedShelters;
    });
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

  Future<void> _showSosNavigationChooser(LatLng destination) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Navigate to SOS Location',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    backgroundColor: Color(0x1A27B469),
                    child: Icon(Icons.map, color: AppColors.primaryGreen),
                  ),
                  title: const Text('Sahyog Map'),
                  subtitle: const Text('Focus this SOS on in-app map'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _mapController.move(destination, 16);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    backgroundColor: Color(0x1A34A853),
                    child: Icon(Icons.map, color: Color(0xFF34A853)),
                  ),
                  title: const Text('Google Maps'),
                  subtitle: const Text('Turn-by-turn directions'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _launchExternalNavigation(
                      providerName: 'Google Maps',
                      appUri: Uri.parse(
                        'comgooglemaps://?daddr=${destination.latitude},${destination.longitude}&directionsmode=driving',
                      ),
                      fallbackUri: Uri.parse(
                        'https://www.google.com/maps/dir/?api=1&destination=${destination.latitude},${destination.longitude}',
                      ),
                    );
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    backgroundColor: Color(0x1A007AFF),
                    child: Icon(Icons.navigation, color: Color(0xFF007AFF)),
                  ),
                  title: const Text('Apple Maps'),
                  subtitle: const Text('Open with Apple Maps'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _launchExternalNavigation(
                      providerName: 'Apple Maps',
                      appUri: Uri.parse(
                        'maps://?daddr=${destination.latitude},${destination.longitude}&dirflg=d',
                      ),
                      fallbackUri: Uri.parse(
                        'http://maps.apple.com/?daddr=${destination.latitude},${destination.longitude}&dirflg=d',
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _launchExternalNavigation({
    required String providerName,
    required Uri appUri,
    required Uri fallbackUri,
  }) async {
    try {
      final openedApp = await launchUrl(
        appUri,
        mode: LaunchMode.externalApplication,
      );
      if (openedApp) return;

      final openedFallback = await launchUrl(
        fallbackUri,
        mode: LaunchMode.externalApplication,
      );
      if (!openedFallback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open $providerName.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Navigation launch failed: $e')));
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final visibleResources = widget.detailedHeatmap
        ? _resources
        : _resources.where((r) => r.type != 'SOS').toList(growable: false);
    final activeSos = _resources
        .where((r) => r.type == 'SOS')
        .toList(growable: false);

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
                  Container(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF1B1B1B)
                        : Colors.grey[200],
                    child: FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: _zones.isNotEmpty
                            ? _zones.first.center
                            : _center,
                        initialZoom: _currentZoom,
                        minZoom: 3,
                        maxZoom: 18,
                        onMapReady: () {
                          setState(() => _isMapReady = true);
                          _handleInitialTarget();
                        },
                        onPositionChanged: (pos, hasGesture) {
                          if (hasGesture) {
                            setState(() {
                              _currentZoom = pos.zoom;
                            });
                          }
                        },
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
                          tileDisplay: const TileDisplay.fadeIn(),
                          tileBuilder:
                              Theme.of(context).brightness == Brightness.dark
                              ? _darkTileBuilder
                              : null,
                        ),
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
                                            color: Colors.black.withValues(
                                              alpha: 0.15,
                                            ),
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
                          circles: _zones.map((z) {
                            return CircleMarker(
                              point: z.center,
                              radius: max(40, z.radiusMeters / 5),
                              useRadiusInMeter: true,
                              color: _severityColor(
                                z.severity,
                              ).withValues(alpha: 0.16),
                              borderColor: _severityColor(z.severity),
                              borderStrokeWidth: 2,
                            );
                          }).toList(),
                        ),
                        CircleLayer(
                          circles: _userMarkedZones.map((z) {
                            return CircleMarker(
                              point: z.center,
                              radius: z.radiusMeters,
                              useRadiusInMeter: true,
                              color: AppColors.primaryGreen.withValues(
                                alpha: 0.16,
                              ),
                              borderColor: AppColors.primaryGreen,
                              borderStrokeWidth: 2,
                            );
                          }).toList(),
                        ),
                        if (_heatmapPoints.isNotEmpty)
                          CircleLayer(
                            circles: _heatmapPoints.map((point) {
                              final radius = _isPublicHeatmapMode
                                  ? 220 + (point.count * 24)
                                  : 110 + (point.count * 16);
                              return CircleMarker(
                                point: point.point,
                                radius: radius,
                                useRadiusInMeter: true,
                                color: _heatmapColor(
                                  point.severity,
                                  blurred: _isPublicHeatmapMode,
                                ),
                                borderColor: Colors.transparent,
                                borderStrokeWidth: 0,
                              );
                            }).toList(),
                          ),
                        if (_isPublicHeatmapMode && _heatmapPoints.isNotEmpty)
                          CircleLayer(
                            circles: _heatmapPoints.map((point) {
                              final radius = 90 + (point.count * 12);
                              return CircleMarker(
                                point: point.point,
                                radius: radius,
                                useRadiusInMeter: true,
                                color: _heatmapColor(point.severity),
                                borderColor: Colors.transparent,
                                borderStrokeWidth: 0,
                              );
                            }).toList(),
                          ),
                        if (_shelterPins.isNotEmpty)
                          MarkerLayer(
                            markers: _shelterPins.map((pin) {
                              return Marker(
                                point: pin.point,
                                width: 130,
                                height: 70,
                                child: Column(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(10),
                                        boxShadow: const [
                                          BoxShadow(
                                            blurRadius: 6,
                                            color: Color(0x22000000),
                                          ),
                                        ],
                                      ),
                                      child: Text(
                                        pin.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: Colors.black,
                                        ),
                                      ),
                                    ),
                                    const Icon(
                                      Icons.health_and_safety,
                                      color: Colors.blue,
                                      size: 24,
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        // ─── Live user location markers ──────────────────
                        ValueListenableBuilder<Map<String, LiveUserLocation>>(
                          valueListenable:
                              LiveLocationService.instance.liveLocations,
                          builder: (context, liveMap, _) {
                            if (liveMap.isEmpty) return const SizedBox.shrink();
                            return MarkerLayer(
                              markers: liveMap.values.map((loc) {
                                final roleColor = switch (loc.role) {
                                  'volunteer' => Colors.blue,
                                  'coordinator' => const Color(0xFF10B981),
                                  'citizen' => Colors.orange,
                                  _ => Colors.grey,
                                };
                                return Marker(
                                  point: LatLng(loc.lat, loc.lng),
                                  width: 32,
                                  height: 32,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: roleColor.withValues(alpha: 0.25),
                                      border: Border.all(
                                        color: roleColor,
                                        width: 2,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.person,
                                      size: 16,
                                      color: roleColor,
                                    ),
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),
                        MarkerLayer(
                          markers: visibleResources.map((r) {
                            final isSos = r.type == 'SOS';
                            return Marker(
                              point: r.point,
                              width: 120,
                              height: 60,
                              child: isSos
                                  ? GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () =>
                                          _showSosNavigationChooser(r.point),
                                      child: _SosMarker(),
                                    )
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
                  ),
                  if (_currentZoom >= 17.9)
                    Positioned(
                      top: 16,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'MAX ZOOM (100%)',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // LEFT-SIDE: Active SOS FAB
                  if (widget.detailedHeatmap)
                    Positioned(
                      left: 16,
                      bottom: 90,
                      child: _SosFab(
                        alerts: activeSos,
                        onGoToLocation: (LatLng point) {
                          _mapController.move(point, 16);
                        },
                      ),
                    ),
                  // RIGHT-SIDE: My Location, Zoom controls
                  Positioned(
                    right: 16,
                    bottom: 90,
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
                          shape: CircleBorder(
                            side: BorderSide(
                              color: Colors.grey.shade300,
                              width: 0.8,
                            ),
                          ),
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
                          shape: CircleBorder(
                            side: BorderSide(
                              color: Colors.grey.shade300,
                              width: 0.8,
                            ),
                          ),
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
                          shape: CircleBorder(
                            side: BorderSide(
                              color: Colors.grey.shade300,
                              width: 0.8,
                            ),
                          ),
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
                            ).cardColor.withValues(alpha: 0.95),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.1),
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
                                    color: widget.detailedHeatmap
                                        ? AppColors.criticalRed
                                        : Colors.blue,
                                    label: widget.detailedHeatmap
                                        ? 'SOS'
                                        : 'Shelter',
                                  ),
                                  const SizedBox(width: 12),
                                  _CompactDot(
                                    color: AppColors.primaryGreen,
                                    label: widget.detailedHeatmap
                                        ? 'Resource'
                                        : 'Heatmap',
                                  ),
                                ],
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 6.0),
                                child: Divider(height: 1),
                              ),
                              Text(
                                'Items & SOS: ${visibleResources.length + activeSos.length}',
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

  Color _heatmapColor(double severity, {bool blurred = false}) {
    final normalized = severity.clamp(1, 10);
    final Color base = normalized >= 8
        ? AppColors.criticalRed
        : normalized >= 5
        ? AppColors.warningAmber
        : AppColors.primaryGreen;
    return base.withValues(alpha: blurred ? 0.13 : 0.2);
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

class _HeatmapPoint {
  _HeatmapPoint({
    required this.point,
    required this.count,
    required this.severity,
  });

  final LatLng point;
  final double count;
  final double severity;
}

class _ShelterPin {
  _ShelterPin({
    required this.id,
    required this.name,
    required this.point,
    this.capacity,
    this.occupancy,
  });

  final String id;
  final String name;
  final LatLng point;
  final dynamic capacity;
  final dynamic occupancy;
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

/// Left-side FAB that shows a badge with the number of active SOS alerts
/// and opens a bottom sheet listing them with "Go to Location" actions.
class _SosFab extends StatelessWidget {
  const _SosFab({required this.alerts, required this.onGoToLocation});

  final List<_ResourceMarker> alerts;
  final ValueChanged<LatLng> onGoToLocation;

  @override
  Widget build(BuildContext context) {
    final count = alerts.length;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        FloatingActionButton(
          heroTag: 'map_sos_fab',
          mini: true,
          onPressed: () => _showSosSheet(context),
          backgroundColor: count > 0 ? AppColors.criticalRed : Colors.white,
          foregroundColor: count > 0 ? Colors.white : AppColors.criticalRed,
          shape: CircleBorder(
            side: BorderSide(
              color: count > 0
                  ? AppColors.criticalRed.withValues(alpha: 0.3)
                  : Colors.grey.shade300,
              width: 0.8,
            ),
          ),
          child: const Icon(Icons.sos, size: 22),
        ),
        if (count > 0)
          Positioned(
            right: -4,
            top: -4,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  color: AppColors.criticalRed,
                  fontWeight: FontWeight.w900,
                  fontSize: 11,
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showSosSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.4,
          minChildSize: 0.25,
          maxChildSize: 0.7,
          builder: (ctx, scrollCtrl) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.sos, color: AppColors.criticalRed),
                        const SizedBox(width: 8),
                        Text(
                          'Active SOS (${alerts.length})',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: alerts.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'No active SOS alerts on the map.',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                          )
                        : ListView.separated(
                            controller: scrollCtrl,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            itemCount: alerts.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (ctx, i) {
                              final sos = alerts[i];
                              return ListTile(
                                leading: const CircleAvatar(
                                  backgroundColor: AppColors.criticalRed,
                                  child: Icon(
                                    Icons.sos,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                ),
                                title: Text(
                                  'SOS #${sos.id.length > 8 ? sos.id.substring(0, 8) : sos.id}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(
                                  '${sos.point.latitude.toStringAsFixed(4)}, ${sos.point.longitude.toStringAsFixed(4)}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: FilledButton.icon(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    onGoToLocation(sos.point);
                                  },
                                  icon: const Icon(Icons.location_on, size: 16),
                                  label: const Text(
                                    'Go',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: AppColors.criticalRed,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    minimumSize: const Size(0, 32),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
