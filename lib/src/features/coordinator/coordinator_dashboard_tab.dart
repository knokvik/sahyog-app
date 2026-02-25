import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../theme/app_colors.dart';

class CoordinatorDashboardTab extends StatefulWidget {
  const CoordinatorDashboardTab({
    super.key,
    required this.api,
    required this.user,
    required this.onNavigate,
  });

  final ApiClient api;
  final AppUser user;
  final void Function(int) onNavigate;

  @override
  State<CoordinatorDashboardTab> createState() =>
      _CoordinatorDashboardTabState();
}

class _CoordinatorDashboardTabState extends State<CoordinatorDashboardTab> {
  final MapController _miniMapController = MapController();

  bool _loading = true;
  String _error = '';
  String _searchQuery = '';
  Timer? _pollTimer;

  Map<String, dynamic> _ctx = {};
  List<Map<String, dynamic>> _recentSos = [];
  List<Map<String, dynamic>> _recentTasks = [];
  List<Map<String, dynamic>> _zones = [];

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

  Future<void> _fetchAndShowLatestSos() async {
    try {
      final raw = await widget.api.get('/api/v1/coordinator/sos');
      final list = (raw is List)
          ? raw.cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];
      if (list.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No active SOS alerts found.')),
        );
        return;
      }
      final latest = list.first;
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(
            '🆘 Emergency Alert',
            style: TextStyle(color: AppColors.criticalRed),
          ),
          content: Text(
            'Latest SOS from: ${latest['volunteer_name'] ?? 'Unknown'}\nStatus: ${(latest['status'] ?? '').toString().toUpperCase()}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                widget.onNavigate(3);
              },
              child: const Text('View All'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to check SOS: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildHeader(),
            const SizedBox(height: 10),
            if (_error.isNotEmpty)
              Text(
                _error,
                style: const TextStyle(color: AppColors.criticalRed),
              ),
            _buildMiniMap(),
            const SizedBox(height: 12),
            _buildStatsRow(),
            const SizedBox(height: 12),
            _buildRecentTasks(),
            const SizedBox(height: 12),
            _buildRecentSos(),
            const SizedBox(height: 80), // Padding for FAB
          ],
        ),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(right: 12.0),
        child: AnimatedSosButton(onTrigger: _fetchAndShowLatestSos),
      ),
    );
  }

  Widget _buildHeader() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(30),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.3), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: AppColors.primaryGreen,
              foregroundColor: Colors.white,
              child: Text(
                widget.user.name.isNotEmpty
                    ? widget.user.name[0].toUpperCase()
                    : '?',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                onChanged: (val) => setState(() => _searchQuery = val),
                decoration: const InputDecoration(
                  hintText: 'Search alerts, tasks...',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
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
        10,
      ),
      (
        'Tasks',
        _recentTasks.length, // Or use a total count from stats if available
        Icons.assignment,
        Colors.blueAccent,
        11,
      ),
      (
        'Needs',
        stats['active_needs'] ?? 0,
        Icons.report_problem,
        Colors.orange,
        12,
      ),
      ('SOS', _recentSos.length, Icons.sos, AppColors.criticalRed, 3),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: items.map((item) {
          final (label, value, _, color, tabIndex) = item;
          return SizedBox(
            width: 110,
            child: InkWell(
              onTap: () => widget.onNavigate(tabIndex),
              borderRadius: BorderRadius.circular(24),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                    color: Colors.grey.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 16,
                    horizontal: 8,
                  ),
                  child: Column(
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 500),
                        transitionBuilder:
                            (Widget child, Animation<double> animation) {
                              return SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0.0, 0.5),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              );
                            },
                        child: Text(
                          '$value',
                          key: ValueKey<int>(value),
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w800,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey,
                        ),
                        maxLines: 1,
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

    return Card(
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        onLongPress: () => widget.onNavigate(1),
        child: SizedBox(
          height: 180,
          child: Stack(
            children: [
              FlutterMap(
                mapController: _miniMapController,
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: 11,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.none,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.sahyog_app',
                  ),
                  CircleLayer(
                    circles: _zones.map((zone) {
                      final lat = parseLat(zone['center_lat']);
                      final lng = parseLng(zone['center_lng']);
                      if (lat == null || lng == null) {
                        return const CircleMarker(
                          point: LatLng(0, 0),
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
                    }).toList(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.blueAccent,
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

class AnimatedSosButton extends StatefulWidget {
  final VoidCallback onTrigger;
  const AnimatedSosButton({super.key, required this.onTrigger});

  @override
  State<AnimatedSosButton> createState() => _AnimatedSosButtonState();
}

class _AnimatedSosButtonState extends State<AnimatedSosButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isPressed = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _onPanDown(_) {
    setState(() => _isPressed = true);
    _timer = Timer(const Duration(seconds: 3), () {
      widget.onTrigger();
      setState(() => _isPressed = false);
    });
  }

  void _onPanCancel() {
    setState(() => _isPressed = false);
    _timer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanDown: _onPanDown,
      onPanCancel: _onPanCancel,
      onPanEnd: (_) => _onPanCancel(),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final scale = _isPressed ? 1.1 : 1.0 + (_controller.value * 0.1);
          return Transform.scale(
            scale: scale,
            child: Container(
              width: 65,
              height: 65,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.criticalRed,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.criticalRed.withValues(
                      alpha: 0.5 * _controller.value,
                    ),
                    blurRadius: 15 * _controller.value,
                    spreadRadius: 10 * _controller.value,
                  ),
                ],
              ),
              child: const Icon(Icons.sos, color: Colors.white, size: 32),
            ),
          );
        },
      ),
    );
  }
}
