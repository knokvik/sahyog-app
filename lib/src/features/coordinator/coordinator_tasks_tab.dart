import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../theme/app_colors.dart';

class CoordinatorTasksTab extends StatefulWidget {
  const CoordinatorTasksTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<CoordinatorTasksTab> createState() => _CoordinatorTasksTabState();
}

class _CoordinatorTasksTabState extends State<CoordinatorTasksTab> {
  final _disasterCtrl = TextEditingController();
  final _zoneCtrl = TextEditingController();
  final _volunteerCtrl = TextEditingController();
  final _typeCtrl = TextEditingController(text: 'medical_support');
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();

  List<Map<String, dynamic>> _tasks = [];
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;
  bool _creating = false;
  String _error = '';
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
    _disasterCtrl.dispose();
    _zoneCtrl.dispose();
    _volunteerCtrl.dispose();
    _typeCtrl.dispose();
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
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

      final pendingRaw = await widget.api.get('/api/v1/coordinator/tasks');
      final historyRaw = await widget.api.get('/api/v1/tasks/history');
      final list = (pendingRaw is List)
          ? pendingRaw.cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];
      final history = (historyRaw is List)
          ? historyRaw.cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];

      if (!mounted) return;
      setState(() {
        _tasks = list;
        _history = history;
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

  Future<void> _createTask() async {
    if (_titleCtrl.text.trim().isEmpty || _typeCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Task title and type are required.')),
      );
      return;
    }

    try {
      setState(() => _creating = true);

      Map<String, dynamic>? meetingPoint;
      final lat = double.tryParse(_latCtrl.text.trim());
      final lng = double.tryParse(_lngCtrl.text.trim());
      if (lat != null && lng != null) {
        meetingPoint = {'lat': lat, 'lng': lng};
      }

      final volunteerIds = _volunteerCtrl.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      if (volunteerIds.isEmpty) {
        await widget.api.post(
          '/api/v1/tasks',
          body: {
            'disaster_id': _disasterCtrl.text.trim().isEmpty
                ? null
                : _disasterCtrl.text.trim(),
            'zone_id': _zoneCtrl.text.trim().isEmpty
                ? null
                : _zoneCtrl.text.trim(),
            'volunteer_id': null,
            'type': _typeCtrl.text.trim(),
            'title': _titleCtrl.text.trim(),
            'description': _descCtrl.text.trim().isEmpty
                ? null
                : _descCtrl.text.trim(),
            'meeting_point': meetingPoint,
          },
        );
      } else {
        for (final volunteerId in volunteerIds) {
          await widget.api.post(
            '/api/v1/tasks',
            body: {
              'disaster_id': _disasterCtrl.text.trim().isEmpty
                  ? null
                  : _disasterCtrl.text.trim(),
              'zone_id': _zoneCtrl.text.trim().isEmpty
                  ? null
                  : _zoneCtrl.text.trim(),
              'volunteer_id': volunteerId,
              'type': _typeCtrl.text.trim(),
              'title': _titleCtrl.text.trim(),
              'description': _descCtrl.text.trim().isEmpty
                  ? null
                  : _descCtrl.text.trim(),
              'meeting_point': meetingPoint,
            },
          );
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Task created.')));

      _titleCtrl.clear();
      _descCtrl.clear();
      _volunteerCtrl.clear();
      _latCtrl.clear();
      _lngCtrl.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Create task failed: $e')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _updateTaskStatus(String taskId, String status) async {
    try {
      await widget.api.patch(
        '/api/v1/tasks/$taskId/status',
        body: {'status': status},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Task updated: $status')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<void> _showVotes(String taskId) async {
    try {
      final raw = await widget.api.get('/api/v1/tasks/$taskId/votes');
      final votes = (raw is Map<String, dynamic> && raw['votes'] is List)
          ? (raw['votes'] as List).cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];
      final summary =
          (raw is Map<String, dynamic> &&
              raw['summary'] is Map<String, dynamic>)
          ? raw['summary'] as Map<String, dynamic>
          : <String, dynamic>{};

      if (!mounted) return;
      showModalBottomSheet<void>(
        context: context,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Completion Votes',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Completed: ${summary['completed_votes'] ?? 0} • Rejected: ${summary['rejected_votes'] ?? 0} • Total: ${summary['total_votes'] ?? 0}',
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: votes.isEmpty
                      ? const Center(child: Text('No votes yet'))
                      : ListView.builder(
                          itemCount: votes.length,
                          itemBuilder: (_, i) {
                            final v = votes[i];
                            return ListTile(
                              leading: const Icon(Icons.how_to_vote_outlined),
                              title: Text(
                                (v['voter_name'] ?? 'Volunteer').toString(),
                              ),
                              subtitle: Text((v['note'] ?? '').toString()),
                              trailing: Chip(
                                label: Text(
                                  (v['vote'] ?? '').toString().toUpperCase(),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to fetch votes: $e')));
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
            'Task Management',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'Create and monitor task execution for disaster operations.',
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_error, style: const TextStyle(color: AppColors.criticalRed)),
          ],
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Create Task',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _titleCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      prefixIcon: Icon(Icons.task_outlined),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _typeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Type',
                      prefixIcon: Icon(Icons.category_outlined),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _descCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Description',
                      prefixIcon: Icon(Icons.notes_outlined),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _disasterCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Disaster ID',
                      prefixIcon: Icon(Icons.warning_amber_outlined),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _zoneCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Zone ID',
                      prefixIcon: Icon(Icons.map_outlined),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _volunteerCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Volunteer IDs (comma separated)',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _latCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Meeting Lat',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _lngCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Meeting Lng',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _creating ? null : _createTask,
                    icon: const Icon(Icons.add_task),
                    label: const Text('Create Task'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Pending / Active Tasks',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (_tasks.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('No task data returned for this account.'),
              ),
            )
          else
            ..._tasks.map((task) {
              final id = (task['id'] ?? '').toString();
              final status = (task['status'] ?? 'pending').toString();
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (task['title'] ?? task['type'] ?? 'Task').toString(),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text('Task ID: $id'),
                      Text('Status: $status'),
                      Text('Volunteer ID: ${(task['volunteer_id'] ?? '-')}'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: id.isEmpty
                                ? null
                                : () => _updateTaskStatus(id, 'in_progress'),
                            child: const Text('Mark In Progress'),
                          ),
                          FilledButton.tonal(
                            onPressed: id.isEmpty
                                ? null
                                : () => _updateTaskStatus(id, 'completed'),
                            child: const Text('Mark Completed'),
                          ),
                          TextButton(
                            onPressed: id.isEmpty ? null : () => _showVotes(id),
                            child: const Text('View Votes'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 14),
          Text(
            'Completed History',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (_history.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('No completed task history yet.'),
              ),
            )
          else
            ..._history.take(20).map((task) {
              final id = (task['id'] ?? '').toString();
              final title = (task['title'] ?? task['type'] ?? 'Task')
                  .toString();
              final completedAt = (task['completed_at'] ?? '').toString();
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: AppColors.primaryGreen,
                    foregroundColor: Colors.white,
                    child: Icon(Icons.check),
                  ),
                  title: Text(title),
                  subtitle: Text(
                    completedAt.isEmpty ? 'Completed' : completedAt,
                  ),
                  trailing: TextButton(
                    onPressed: id.isEmpty ? null : () => _showVotes(id),
                    child: const Text('Votes'),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
