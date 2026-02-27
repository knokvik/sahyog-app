import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../theme/app_colors.dart';
import 'task_detail_screen.dart';

class AssignmentsTab extends StatefulWidget {
  const AssignmentsTab({super.key, required this.api, required this.user});

  final ApiClient api;
  final AppUser user;

  @override
  State<AssignmentsTab> createState() => _AssignmentsTabState();
}

class _AssignmentsTabState extends State<AssignmentsTab> {
  List<Map<String, dynamic>> _assignments = [];
  List<Map<String, dynamic>> _pendingTasks = [];
  List<Map<String, dynamic>> _taskHistory = [];

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

      if (widget.user.isVolunteer) {
        final results = await Future.wait([
          widget.api.get('/api/v1/volunteer-assignments/mine'),
          widget.api.get('/api/v1/tasks/pending'),
          widget.api.get('/api/v1/tasks/history'),
        ]);

        _assignments = results[0] is List
            ? (results[0] as List).cast<Map<String, dynamic>>()
            : <Map<String, dynamic>>[];
        _pendingTasks = results[1] is List
            ? (results[1] as List).cast<Map<String, dynamic>>()
            : <Map<String, dynamic>>[];
        _taskHistory = results[2] is List
            ? (results[2] as List).cast<Map<String, dynamic>>()
            : <Map<String, dynamic>>[];
      } else if (widget.user.isCoordinator) {
        final raw = await widget.api.get('/api/v1/coordinator/needs');
        _assignments = raw is List
            ? raw.cast<Map<String, dynamic>>()
            : <Map<String, dynamic>>[];
      } else {
        _assignments = [];
      }

      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _respond(String assignmentId, String status) async {
    try {
      await widget.api.post(
        '/api/v1/volunteer-assignments/$assignmentId/respond',
        body: {'status': status},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Assignment $status')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _resolveNeed(String id) async {
    try {
      await widget.api.patch('/api/v1/needs/$id/resolve');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Need marked as resolved')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Resolve failed: $e')));
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
      ).showSnackBar(SnackBar(content: Text('Task marked as $status')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      // Handle new validation errors from backend
      final errorMsg = e.toString();
      String displayMsg = 'Failed to update task: $e';
      
      if (errorMsg.contains('training')) {
        displayMsg = 'This task requires specific training. Please contact a coordinator.';
      } else if (errorMsg.contains('distance') || errorMsg.contains('far')) {
        displayMsg = 'You are too far from this task location. Maximum distance is 50km.';
      } else if (errorMsg.contains('maximum') || errorMsg.contains('3 active tasks')) {
        displayMsg = 'You have reached the maximum of 3 active tasks. Complete existing tasks first.';
      }
      
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayMsg), backgroundColor: Colors.red));
    }
  }

  Future<void> _voteOnTaskCompletion(String taskId, String vote) async {
    try {
      await widget.api.post(
        '/api/v1/tasks/$taskId/vote-completion',
        body: {'vote': vote},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Vote recorded: $vote')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      // Handle self-voting restriction
      final errorMsg = e.toString();
      String displayMsg = 'Failed to vote: $e';
      
      if (errorMsg.contains('own task') || errorMsg.contains('cannot vote')) {
        displayMsg = 'You cannot vote on completion of your own task. Other volunteers or coordinators must verify your work.';
      } else if (errorMsg.contains('status') || errorMsg.contains('completed')) {
        displayMsg = 'Can only vote to confirm completion on tasks marked as completed by the volunteer.';
      }
      
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayMsg), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.user.isVolunteer && !widget.user.isCoordinator) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Assignments are available for volunteer/coordinator roles.',
          ),
        ),
      );
    }

    if (widget.user.isVolunteer) {
      return DefaultTabController(
        length: 2,
        child: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'Active Tasks'),
                Tab(text: 'History'),
              ],
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  _error,
                  style: const TextStyle(color: AppColors.criticalRed),
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _buildVolunteerAssignments(),
                        const SizedBox(height: 12),
                        _buildPendingTasks(),
                      ],
                    ),
                  ),
                  RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [_buildTaskHistory()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Coordinator Needs Dashboard',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                if (_error.isNotEmpty)
                  Text(
                    _error,
                    style: const TextStyle(color: AppColors.criticalRed),
                  ),
                _buildCoordinatorNeeds(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVolunteerAssignments() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Disaster Assignments',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (_assignments.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text('No disaster assignments.'),
            ),
          )
        else
          ..._assignments.map((item) {
            final status = (item['status'] ?? 'pending').toString();
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (item['disaster_name'] ?? 'Disaster Assignment')
                          .toString(),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text('Severity: ${item['disaster_severity'] ?? '-'}'),
                    Text('Coordinator: ${item['coordinator_name'] ?? '-'}'),
                    Text('Contact: ${item['coordinator_phone'] ?? '-'}'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: [
                        Chip(label: Text(status.toUpperCase())),
                        if (status == 'pending')
                          FilledButton(
                            onPressed: () => _respond(
                              (item['id'] ?? '').toString(),
                              'accepted',
                            ),
                            child: const Text('Accept'),
                          ),
                        if (status == 'pending')
                          OutlinedButton(
                            onPressed: () => _respond(
                              (item['id'] ?? '').toString(),
                              'rejected',
                            ),
                            child: const Text('Reject'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildPendingTasks() {
    // Count active tasks for the current user
    final activeTasksCount = _pendingTasks.where((t) {
      final status = (t['status'] ?? '').toString();
      return ['pending', 'accepted', 'in_progress'].contains(status) &&
             t['volunteer_id'] == widget.user.id;
    }).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'My Active Tasks',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            // Show active task count indicator
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: activeTasksCount >= 3 
                    ? Colors.red.withOpacity(0.1) 
                    : Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$activeTasksCount/3 active',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: activeTasksCount >= 3 ? Colors.red : Colors.blue,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_pendingTasks.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text('No pending tasks.'),
            ),
          )
        else
          ..._pendingTasks.map((task) {
            final status = (task['status'] ?? 'pending').toString();
            final volunteerId = task['volunteer_id'];
            final isUnassigned = volunteerId == null;
            final isMyTask = volunteerId == widget.user.id;
            final taskType = (task['type'] ?? '').toString().toLowerCase();
            final requiresSpecialTraining = ['medical', 'rescue', 'fire', 'evacuation'].contains(taskType);

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(0),
                child: Column(
                  children: [
                    ListTile(
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => TaskDetailScreen(
                              api: widget.api,
                              user: widget.user,
                              task: task,
                            ),
                          ),
                        );
                        _load(silent: true);
                      },
                      leading: CircleAvatar(
                        backgroundColor: isUnassigned
                            ? Colors.orange.withValues(alpha: 0.1)
                            : AppColors.primaryGreen.withValues(alpha: 0.1),
                        child: Icon(
                          isUnassigned
                              ? Icons.assignment
                              : Icons.assignment_ind,
                          color: isUnassigned
                              ? Colors.orange
                              : AppColors.primaryGreen,
                        ),
                      ),
                      title: Text(
                        (task['title'] ?? task['type'] ?? 'Task').toString(),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isUnassigned
                                ? 'Unassigned • Click to Accept'
                                : 'Status: $status',
                            style: TextStyle(
                              color: isUnassigned ? Colors.orange[800] : null,
                              fontWeight: isUnassigned ? FontWeight.bold : null,
                            ),
                          ),
                          // Show skill requirement for critical tasks
                          if (requiresSpecialTraining && isUnassigned)
                            Text(
                              'Requires $taskType training',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.orange,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                      trailing: (!isUnassigned && status == 'accepted' && isMyTask)
                          ? IconButton(
                              icon: const Icon(
                                Icons.check_circle_outline,
                                color: AppColors.primaryGreen,
                              ),
                              tooltip: 'Mark as Done',
                              onPressed: () => _updateTaskStatus(
                                (task['id'] ?? '').toString(),
                                'completed',
                              ),
                            )
                          // Show vote buttons for completed tasks (not own task)
                          : (!isUnassigned && status == 'completed' && !isMyTask)
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.check_circle, color: Colors.green),
                                      tooltip: 'Confirm Completion',
                                      onPressed: () => _voteOnTaskCompletion(
                                        (task['id'] ?? '').toString(),
                                        'completed',
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.cancel, color: Colors.red),
                                      tooltip: 'Reject Completion',
                                      onPressed: () => _voteOnTaskCompletion(
                                        (task['id'] ?? '').toString(),
                                        'rejected',
                                      ),
                                    ),
                                  ],
                                )
                              : const Icon(Icons.chevron_right),
                    ),
                    if (!isUnassigned &&
                        (status == 'pending' || status == 'assigned'))
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 72,
                          right: 16,
                          bottom: 12,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _updateTaskStatus(
                                  (task['id'] ?? '').toString(),
                                  'rejected',
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.criticalRed,
                                  side: BorderSide(
                                    color: AppColors.criticalRed.withOpacity(
                                      0.5,
                                    ),
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                                child: const Text('Decline'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.tonal(
                                onPressed: activeTasksCount >= 3 
                                    ? null  // Disable if at max tasks
                                    : () => _updateTaskStatus(
                                        (task['id'] ?? '').toString(),
                                        'accepted',
                                      ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.primaryGreen,
                                  foregroundColor: Colors.white,
                                  visualDensity: VisualDensity.compact,
                                ),
                                child: const Text('Accept'),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildTaskHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Task History',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (_taskHistory.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text('No completed history yet.'),
            ),
          )
        else
          ..._taskHistory.take(20).map((task) {
            final title = (task['title'] ?? task['type'] ?? 'Task').toString();
            final completedAt = (task['completed_at'] ?? '').toString();
            return Card(
              child: ListTile(
                leading: const CircleAvatar(
                  backgroundColor: AppColors.primaryGreen,
                  foregroundColor: Colors.white,
                  child: Icon(Icons.check),
                ),
                title: Text(title),
                subtitle: Text(completedAt.isEmpty ? 'Completed' : completedAt),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildCoordinatorNeeds() {
    if (_assignments.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No records found.'),
        ),
      );
    }

    return Column(
      children: _assignments.map((item) {
        final needId = (item['id'] ?? '').toString();
        return Card(
          child: ListTile(
            title: Text((item['type'] ?? 'Need').toString()),
            subtitle: Text(
              'Urgency: ${item['urgency'] ?? '-'} • Status: ${item['status'] ?? '-'}',
            ),
            trailing: FilledButton.tonal(
              onPressed: needId.isEmpty ? null : () => _resolveNeed(needId),
              child: const Text('Resolve'),
            ),
          ),
        );
      }).toList(),
    );
  }
}
