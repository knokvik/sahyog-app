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
import 'sos_alerts_panel.dart';
import 'emergency_sos_box.dart';
import '../../theme/app_colors.dart';

class UserHomeTab extends StatefulWidget {
  const UserHomeTab({
    super.key,
    required this.api,
    required this.user,
    this.onNavigate,
  });

  final ApiClient api;
  final AppUser user;
  final void Function(int, {LatLng? target})? onNavigate;

  @override
  State<UserHomeTab> createState() => _UserHomeTabState();
}

class _UserHomeTabState extends State<UserHomeTab>
    with AutomaticKeepAliveClientMixin {
  final _locationService = LocationService();
  final MapController _miniMapController = MapController();

  Position? _position;
  bool _loading = true;
  List<Map<String, dynamic>> _alerts = [];
  Timer? _pollTimer;

  String? _activeSosId;

  // Track global SOS from sockets: {id: LatLng}
  final Map<String, LatLng> _globalActiveSos = {};

  @override
  void initState() {
    super.initState();
    _checkActiveSos();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _load(silent: true);
    });

    SocketService.instance.onNewSosAlert.addListener(_onRemoteSosReceived);
    SocketService.instance.onSosResolved.addListener(_onRemoteSosResolved);
  }

  Future<void> _checkActiveSos() async {
    final active = await DatabaseHelper.instance.getActiveIncident(
      widget.user.id,
    );
    if (mounted && active?.backendId != null) {
      setState(() => _activeSosId = active!.backendId);
    }
  }

  void _onRemoteSosReceived() {
    final payload = SocketService.instance.onNewSosAlert.value;
    if (payload == null) return;

    final locRaw = payload['location'];
    if (locRaw is Map<String, dynamic> && locRaw['coordinates'] is List) {
      final coords = locRaw['coordinates'];
      if (coords.length >= 2) {
        final id = payload['id'].toString();
        if (id == _activeSosId) return;

        setState(() {
          _globalActiveSos[id] = LatLng(
            (coords[1] as num).toDouble(),
            (coords[0] as num).toDouble(),
          );
        });
      }
    }
  }

  void _onRemoteSosResolved() {
    final payload = SocketService.instance.onSosResolved.value;
    if (payload == null) return;

    final id = payload['id'].toString();
    setState(() {
      _globalActiveSos.remove(id);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    SocketService.instance.onNewSosAlert.removeListener(_onRemoteSosReceived);
    SocketService.instance.onSosResolved.removeListener(_onRemoteSosResolved);
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      if (!silent) {
        setState(() {
          _loading = true;
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

      if (!mounted) return;
      setState(() {
        _position = pos;
        _alerts = disasters;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  bool get wantKeepAlive => true;

  // ─────────────────────────────────────────────────────────

  // ─────────────────────────────────────────────────────────
  // Build Methods
  // ─────────────────────────────────────────────────────────

  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _load,
      child: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _UserStatusBanner(user: widget.user),
              const SizedBox(height: 16),
              Card(
                clipBehavior: Clip.antiAlias,
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SizedBox(height: 220, child: _buildMiniMap()),
              ),
              const SizedBox(height: 16),
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
                              onGoToSosPanels: () => widget.onNavigate?.call(1),
                            );
                          }
                        });
                  }
                },
                onSosLocationTap: (ll) =>
                    widget.onNavigate?.call(1, target: ll),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  const Icon(
                    Icons.emergency_share_outlined,
                    color: AppColors.criticalRed,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Recent Disaster Alerts',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_alerts.isEmpty)
                _EmptyAlertsState()
              else
                ..._alerts.map(
                  (alert) => _AlertCard(alert: alert, api: widget.api),
                ),
              const SizedBox(height: 32),
            ],
          ),
        ],
      ),
    );
  }

  // Removed _buildEmergencySOSButton, _cancelHold, etc. as they are now in EmergencySosBox

  Widget _buildMiniMap() {
    LatLng center = const LatLng(18.5204, 73.8567);
    if (_position != null) {
      center = LatLng(_position!.latitude, _position!.longitude);
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _miniMapController,
          options: MapOptions(initialCenter: center, initialZoom: 13),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.sahyog_app',
            ),
            MarkerLayer(
              markers: [
                if (_position != null)
                  Marker(
                    point: center,
                    width: 40,
                    height: 40,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.primaryGreen.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.person_pin_circle,
                          color: AppColors.primaryGreen,
                          size: 32,
                        ),
                      ),
                    ),
                  ),
                ..._globalActiveSos.entries.map((entry) {
                  return Marker(
                    point: entry.value,
                    width: 100,
                    height: 100,
                    child: const _PulsingMarkerWidget(),
                  );
                }),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _UserStatusBanner extends StatelessWidget {
  const _UserStatusBanner({required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primaryGreen.withValues(alpha: 0.1), Colors.white],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.primaryGreen.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.primaryGreen.withValues(alpha: 0.2),
            child: const Icon(
              Icons.verified_user,
              color: AppColors.primaryGreen,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome, ${user.name}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  'Stay safe. Monitor active alerts below.',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.api});
  final Map<String, dynamic> alert;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    final severity = (alert['severity'] ?? 0).toInt();
    final isCritical = severity >= 4;
    final color = isCritical ? AppColors.criticalRed : Colors.orange;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.2)),
      ),
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (ctx) => AlertDetailPage(alert: alert, api: api),
          ),
        ),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.warning_amber_rounded, color: color),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (alert['name'] ?? 'Disaster Alert').toString(),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      (alert['type'] ?? 'Unknown Type')
                          .toString()
                          .toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyAlertsState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(32),
      alignment: Alignment.center,
      child: Column(
        children: [
          Icon(Icons.shield_outlined, size: 48, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text(
            'No active alerts in your area',
            style: TextStyle(color: Colors.grey[500], fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class AlertDetailPage extends StatelessWidget {
  const AlertDetailPage({super.key, required this.alert, required this.api});
  final Map<String, dynamic> alert;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alert Details')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            (alert['name'] ?? 'Disaster Update').toString(),
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _Tag(
                label: (alert['type'] ?? 'Disaster').toString().toUpperCase(),
                color: AppColors.primaryGreen,
              ),
              const SizedBox(width: 8),
              _Tag(
                label: 'SEVERITY: ${alert['severity'] ?? 'N/A'}',
                color: AppColors.criticalRed,
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text(
            'Description',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          const SizedBox(height: 12),
          Text(
            (alert['description'] ??
                    'No detailed description available for this alert at this time. Please follow local news and official guidance.')
                .toString(),
            style: const TextStyle(
              fontSize: 15,
              height: 1.6,
              color: Colors.blueGrey,
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Affected Area',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              height: 250,
              color: Colors.grey[100],
              child: const Center(child: Text('Map View of Affected Area')),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _PulsingMarkerWidget extends StatefulWidget {
  const _PulsingMarkerWidget();

  @override
  State<_PulsingMarkerWidget> createState() => _PulsingMarkerWidgetState();
}

class _PulsingMarkerWidgetState extends State<_PulsingMarkerWidget>
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
        return Stack(
          alignment: Alignment.center,
          children: [
            Transform.scale(
              scale: _controller.value * 2.0,
              child: Opacity(
                opacity: 1.0 - _controller.value,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.criticalRed, width: 2),
                  ),
                ),
              ),
            ),
            Transform.scale(
              scale: ((_controller.value + 0.5) % 1.0) * 2.0,
              child: Opacity(
                opacity: 1.0 - ((_controller.value + 0.5) % 1.0),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.criticalRed, width: 2),
                  ),
                ),
              ),
            ),
            Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: AppColors.criticalRed,
                shape: BoxShape.circle,
              ),
            ),
          ],
        );
      },
    );
  }
}
