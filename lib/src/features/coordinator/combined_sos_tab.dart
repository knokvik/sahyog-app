import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/location_service.dart';
import '../../core/socket_service.dart';
import '../../core/models.dart';
import '../../theme/app_colors.dart';
import '../missing/missing_tab.dart';

class CombinedSosTab extends StatefulWidget {
  const CombinedSosTab({super.key, required this.api, required this.user});

  final ApiClient api;
  final AppUser user;

  @override
  State<CombinedSosTab> createState() => _CombinedSosTabState();
}

class _CombinedSosTabState extends State<CombinedSosTab> {
  List<Map<String, dynamic>> _alerts = [];
  bool _loading = true;
  String _error = '';
  Timer? _pollTimer;
  final Set<String> _expandedAlertIds = {};

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

      // If coordinator, use the dedicated coordinator endpoint.
      // Else use the general SOS endpoint which honors user/volunteer visibility.
      final endpoint = widget.user.isCoordinator
          ? '/api/v1/coordinator/sos'
          : '/api/v1/sos';

      final raw = await widget.api.get(endpoint);
      final list = (raw is List)
          ? raw.cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];

      if (!mounted) return;

      // Seed the global indicator for anyone who can see these alerts (Coordinators, Volunteers, Admins)
      if (widget.user.isCoordinator ||
          widget.user.isVolunteer ||
          widget.user.isAdmin) {
        SocketService.instance.setInitialAlerts(list);
      }

      setState(() {
        _alerts = list;
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

  Future<void> _updateStatus(String id, String status) async {
    try {
      await widget.api.patch(
        '/api/v1/sos/$id/status',
        body: {'status': status},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('SOS updated: $status')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            labelStyle: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
            unselectedLabelStyle: const TextStyle(
              fontWeight: FontWeight.w400,
              fontSize: 14,
            ),
            tabs: const [
              Tab(text: 'Missing Persons'),
              Tab(text: 'SOS Alerts'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                MissingTab(api: widget.api),
                _buildSosTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSosTab() {
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [              
                if (_error.isNotEmpty)
                  Text(
                    _error,
                    style: const TextStyle(color: AppColors.criticalRed),
                  ),
                if (_alerts.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: Text('No SOS alerts found.'),
                    ),
                  )
                else
                  ..._alerts.map((alert) {
                    final id = (alert['id'] ?? '').toString();
                    final status = (alert['status'] ?? 'triggered').toString();
                    final isActive = status == 'triggered';
                    final reporterName =
                        (alert['reporter_name'] ??
                                alert['reporter_phone'] ??
                                'Sahayanet User')
                            .toString();
                    final desc = (alert['description'] ?? '').toString();
                    final double? lat = double.tryParse((alert['latitude'] ?? alert['lat'] ?? '').toString());
                    final double? lng = double.tryParse((alert['longitude'] ?? alert['lng'] ?? '').toString());

                    final isExpanded = _expandedAlertIds.contains(id);

                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            if (_expandedAlertIds.contains(id)) {
                              _expandedAlertIds.remove(id);
                            } else {
                              _expandedAlertIds.add(id);
                            }
                          });
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 280),
                            curve: Curves.easeInOutCubic,
                            alignment: Alignment.topCenter,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    CircleAvatar(
                                      radius: 28,
                                      backgroundColor: isActive
                                          ? AppColors.criticalRed.withValues(alpha: 0.15)
                                          : Colors.grey.withValues(alpha: 0.15),
                                      child: Icon(
                                        isActive ? Icons.sos : Icons.check_circle,
                                        size: 28,
                                        color: isActive
                                            ? AppColors.criticalRed
                                            : Colors.grey.shade600,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            isActive ? 'SOS Active' : 'SOS Alert',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'Reporter: $reporterName • Status: ${status.toUpperCase()}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey,
                                            ),
                                            maxLines: isExpanded ? 3 : 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (isActive)
                                      const Chip(
                                        label: Text(
                                          'LIVE',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                      )
                                    else
                                      Chip(
                                        label: Text(
                                          status.toUpperCase(),
                                          style: const TextStyle(
                                            fontSize: 10,
                                          ),
                                        ),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                      ),
                                  ],
                                ),
                                if (isExpanded) ...[
                                  if (desc.isNotEmpty) ...[
                                    const SizedBox(height: 10),
                                    Text(
                                      desc,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ],
                                  if (alert['media_urls'] is List &&
                                      (alert['media_urls'] as List).isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    const Row(
                                      children: [
                                        Icon(Icons.attachment, size: 14, color: Colors.grey),
                                        SizedBox(width: 4),
                                        Text(
                                          'Has media attachments',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  if (lat != null && lng != null) ...[
                                    const SizedBox(height: 10),
                                    SizedBox(
                                      width: double.infinity,
                                      child: OutlinedButton.icon(
                                        onPressed: () => LocationService.openDirections(
                                          lat,
                                          lng,
                                          label: reporterName,
                                        ),
                                        icon: const Icon(
                                          Icons.directions_outlined,
                                          size: 16,
                                          color: AppColors.primaryGreen,
                                        ),
                                        label: const Text(
                                          'Get Directions in Maps',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (widget.user.isCoordinator ||
                                      widget.user.isVolunteer) ...[
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed: id.isEmpty ||
                                                    status == 'acknowledged' ||
                                                    status == 'resolved'
                                                ? null
                                                : () => _updateStatus(
                                                      id,
                                                      'acknowledged',
                                                    ),
                                            child: const Text(
                                              'Acknowledge',
                                              style: TextStyle(fontSize: 12),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: FilledButton.tonal(
                                            onPressed: id.isEmpty || status == 'resolved'
                                                ? null
                                                : () => _updateStatus(
                                                      id,
                                                      'resolved',
                                                    ),
                                            child: const Text(
                                              'Resolve',
                                              style: TextStyle(fontSize: 12),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ] else if (status == 'triggered') ...[
                                    const SizedBox(height: 12),
                                    SizedBox(
                                      width: double.infinity,
                                      child: OutlinedButton.icon(
                                        onPressed: () => _updateStatus(id, 'cancelled'),
                                        icon: const Icon(
                                          Icons.cancel_outlined,
                                          size: 16,
                                        ),
                                        label: const Text(
                                          'Cancel Request',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: AppColors.criticalRed,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
