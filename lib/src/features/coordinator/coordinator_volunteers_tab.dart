import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../theme/app_colors.dart';

class CoordinatorVolunteersTab extends StatefulWidget {
  const CoordinatorVolunteersTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<CoordinatorVolunteersTab> createState() =>
      _CoordinatorVolunteersTabState();
}

class _CoordinatorVolunteersTabState extends State<CoordinatorVolunteersTab> {
  List<Map<String, dynamic>> _volunteers = [];
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

      final raw = await widget.api.get('/api/v1/coordinator/volunteers');
      final list = (raw is List)
          ? raw.cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];

      if (!mounted) return;
      setState(() {
        _volunteers = list;
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
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Volunteer Management',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'Live activity and assignment signal for all volunteers in operation.',
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_error, style: const TextStyle(color: AppColors.criticalRed)),
          ],
          const SizedBox(height: 12),
          if (_volunteers.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('No volunteer records found.'),
              ),
            )
          else
            ..._volunteers.map((v) {
              final name = (v['full_name'] ?? 'Unnamed').toString();
              final email = (v['email'] ?? '').toString();
              final active = v['is_active'] == true;
              final verified = v['is_verified'] == true;
              final lastActive = (v['last_active'] ?? '').toString();
              final activeTasks = (v['active_tasks'] ?? 0).toString();
              final completedTasks = (v['completed_tasks'] ?? 0).toString();

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: active
                                ? AppColors.primaryGreen
                                : Colors.grey,
                            foregroundColor: Colors.white,
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  email,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          Chip(
                            label: Text(active ? 'ACTIVE' : 'INACTIVE'),
                            backgroundColor:
                                (active ? AppColors.primaryGreen : Colors.grey)
                                    .withValues(alpha: 0.15),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (verified)
                            const Chip(
                              avatar: Icon(
                                Icons.verified,
                                size: 16,
                                color: AppColors.primaryGreen,
                              ),
                              label: Text('Verified'),
                            ),
                          Chip(label: Text('Active Tasks: $activeTasks')),
                          Chip(label: Text('Completed: $completedTasks')),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Last active: ${lastActive.isEmpty ? 'Unknown' : lastActive}',
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
