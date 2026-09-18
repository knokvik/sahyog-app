import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../theme/app_colors.dart';

class CoordinatorNeedsTab extends StatefulWidget {
  const CoordinatorNeedsTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<CoordinatorNeedsTab> createState() => _CoordinatorNeedsTabState();
}

class _CoordinatorNeedsTabState extends State<CoordinatorNeedsTab> {
  List<Map<String, dynamic>> _needs = [];
  bool _loading = true;
  String _error = '';
  String _filterStatus = 'all';
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

      final raw = await widget.api.get('/api/v1/coordinator/needs');
      final list = (raw is List)
          ? raw.cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];

      if (!mounted) return;
      setState(() {
        _needs = list;
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

  Future<void> _resolve(String id) async {
    try {
      await widget.api.patch('/api/v1/needs/$id/resolve');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Need marked resolved.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Resolve failed: $e')));
    }
  }

  Future<void> _assign(String id) async {
    final controller = TextEditingController();
    final volunteerId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Assign Volunteer'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Volunteer ID'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Assign'),
          ),
        ],
      ),
    );

    if (volunteerId == null || volunteerId.isEmpty) return;

    try {
      await widget.api.patch(
        '/api/v1/needs/$id/assign',
        body: {'volunteer_id': volunteerId},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Volunteer assigned.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Assign failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final filtered = _filterStatus == 'all'
        ? _needs
        : _needs
              .where((n) => (n['status'] ?? '').toString() == _filterStatus)
              .toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Needs Management',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (_error.isNotEmpty)
            Text(_error, style: const TextStyle(color: AppColors.criticalRed)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: ['all', 'unassigned', 'assigned', 'resolved'].map((
              status,
            ) {
              final selected = _filterStatus == status;
              return ChoiceChip(
                label: Text(status.toUpperCase()),
                selected: selected,
                onSelected: (_) => setState(() => _filterStatus = status),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          if (filtered.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('No needs found for selected filter.'),
              ),
            )
          else
            ...filtered.map((need) {
              final id = (need['id'] ?? '').toString();
              final status = (need['status'] ?? 'unassigned').toString();
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (need['type'] ?? 'Need').toString(),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text('Need ID: $id'),
                      Text('Reporter: ${(need['reporter_name'] ?? 'Unknown')}'),
                      Text('Urgency: ${(need['urgency'] ?? 'medium')}'),
                      Text(
                        'Assigned Volunteer: ${(need['assigned_volunteer_id'] ?? '-')}',
                      ),
                      Text('Status: $status'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: id.isEmpty ? null : () => _assign(id),
                            child: const Text('Assign Volunteer'),
                          ),
                          FilledButton.tonal(
                            onPressed: (id.isEmpty || status == 'resolved')
                                ? null
                                : () => _resolve(id),
                            child: const Text('Mark Resolved'),
                          ),
                        ],
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
