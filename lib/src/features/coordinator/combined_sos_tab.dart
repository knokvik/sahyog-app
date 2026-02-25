import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
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
          const TabBar(
            tabs: [
              Tab(text: 'SOS Alerts'),
              Tab(text: 'Missing Persons'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildSosTab(),
                MissingTab(api: widget.api),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSosTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'SOS Monitoring',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text('SOS alerts within your area.'),
          const SizedBox(height: 10),
          if (_error.isNotEmpty)
            Text(_error, style: const TextStyle(color: AppColors.criticalRed)),
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

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                elevation: isActive ? 2 : 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: isActive
                        ? AppColors.criticalRed.withOpacity(0.3)
                        : Colors.grey.withOpacity(0.2),
                    width: 1,
                  ),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: isActive
                        ? AppColors.criticalRed.withOpacity(0.04)
                        : null,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: isActive
                                  ? AppColors.criticalRed
                                  : Colors.grey.shade400,
                              foregroundColor: Colors.white,
                              child: Icon(
                                isActive ? Icons.sos : Icons.check_circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                isActive ? '🔴 SOS ACTIVE' : 'SOS Alert',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                  color: isActive
                                      ? AppColors.criticalRed
                                      : null,
                                ),
                              ),
                            ),
                            if (isActive)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.criticalRed,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.circle,
                                      color: Colors.white,
                                      size: 8,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      'LIVE',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 11,
                                        letterSpacing: 1,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            else
                              Chip(label: Text(status.toUpperCase())),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Reporter: $reporterName',
                          style: TextStyle(
                            fontWeight: isActive
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        if (alert['media_urls'] is List &&
                            (alert['media_urls'] as List).isNotEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text('📎 Has media attachments'),
                          ),
                        const SizedBox(height: 8),
                        if (widget.user.isCoordinator ||
                            widget.user.isVolunteer)
                          Wrap(
                            spacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed:
                                    id.isEmpty ||
                                        status == 'acknowledged' ||
                                        status == 'resolved'
                                    ? null
                                    : () => _updateStatus(id, 'acknowledged'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 0,
                                  ),
                                  minimumSize: const Size(0, 32),
                                  side: BorderSide(
                                    color: Colors.blue.withOpacity(0.5),
                                  ),
                                ),
                                child: const Text(
                                  'Acknowledge',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              FilledButton.tonal(
                                onPressed: id.isEmpty || status == 'resolved'
                                    ? null
                                    : () => _updateStatus(id, 'resolved'),
                                style: isActive
                                    ? FilledButton.styleFrom(
                                        backgroundColor: AppColors.criticalRed
                                            .withOpacity(0.8),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 0,
                                        ),
                                        minimumSize: const Size(0, 32),
                                      )
                                    : FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 0,
                                        ),
                                        minimumSize: const Size(0, 32),
                                      ),
                                child: const Text(
                                  'Resolve',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          )
                        else if (status == 'triggered')
                          OutlinedButton.icon(
                            onPressed: () => _updateStatus(id, 'cancelled'),
                            icon: const Icon(Icons.cancel, size: 16),
                            label: const Text(
                              'Cancel Request',
                              style: TextStyle(fontSize: 12),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red.withOpacity(0.8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 0,
                              ),
                              minimumSize: const Size(0, 32),
                              side: BorderSide(
                                color: Colors.red.withOpacity(0.3),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
