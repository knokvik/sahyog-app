import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../theme/app_colors.dart';
import '../../core/socket_service.dart';

class NotificationsTab extends StatefulWidget {
  const NotificationsTab({super.key, required this.api, required this.user});

  final ApiClient api;
  final AppUser user;

  @override
  State<NotificationsTab> createState() => _NotificationsTabState();
}

class _NotificationsTabState extends State<NotificationsTab> {
  List<Map<String, dynamic>> _notifications = [];
  bool _loading = true;
  String _error = '';
  Timer? _pollTimer;
  int _lastCount = -1;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) _load(silent: true);
    });

    SocketService.instance.onNewSosAlert.addListener(_onSocketAlert);
  }

  void _onSocketAlert() {
    if (mounted) _load(silent: true);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    SocketService.instance.onNewSosAlert.removeListener(_onSocketAlert);
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

      final List<Map<String, dynamic>> derived = [];

      if (widget.user.isCoordinator ||
          widget.user.isAdmin ||
          widget.user.isOrganization) {
        final sosEndpoint = widget.user.isCoordinator
            ? '/api/v1/coordinator/sos'
            : '/api/v1/sos';
        final sosRaw = await widget.api.get(sosEndpoint);
        final sosList = (sosRaw is List) ? sosRaw : [];
        for (var sos in sosList) {
          derived.add({
            'id': 'sos_${sos['id']}',
            'title': '🆘 Emergency Alert',
            'body':
                'SOS from ${sos['volunteer_name'] ?? sos['reporter_name'] ?? 'Unknown'}',
            'type': 'sos',
            'time': sos['created_at'],
            'status': sos['status'],
          });
        }

        if (widget.user.isCoordinator) {
          final needsRaw = await widget.api.get('/api/v1/coordinator/needs');
          final needsList = (needsRaw is List) ? needsRaw : [];
          for (var need in needsList) {
            if (need['status'] == 'unassigned') {
              derived.add({
                'id': 'need_${need['id']}',
                'title': '📦 New Need Request',
                'body':
                    '${need['type']} request from ${need['reporter_name'] ?? 'Anonymous'}',
                'type': 'need',
                'time': need['created_at'],
                'status': 'urgent',
              });
            }
          }
        }
      }

      if (widget.user.isVolunteer) {
        final assignmentsRaw = await widget.api.get(
          '/api/v1/volunteer-assignments/mine',
        );
        final assignments = (assignmentsRaw is List) ? assignmentsRaw : [];
        for (var asn in assignments) {
          if (asn['status'] == 'pending') {
            derived.add({
              'id': 'asn_${asn['id']}',
              'title': '📢 New Deployment',
              'body': 'You have been assigned to ${asn['disaster_name']}',
              'type': 'assignment',
              'time': asn['created_at'],
              'status': 'new',
            });
          }
        }

        final tasksRaw = await widget.api.get('/api/v1/tasks/pending');
        final tasks = (tasksRaw is List) ? tasksRaw : [];
        for (var task in tasks) {
          if (task['volunteer_id'] == widget.user.id &&
              task['status'] == 'pending') {
            derived.add({
              'id': 'task_${task['id']}',
              'title': '📋 New Task Assigned',
              'body': 'Task: ${task['title']}',
              'type': 'task',
              'time': task['created_at'],
              'status': 'new',
            });
          }
        }
      }

      derived.sort(
        (a, b) => (b['time'] ?? '').toString().compareTo(
          (a['time'] ?? '').toString(),
        ),
      );

      if (!mounted) return;

      if (_lastCount != -1 && derived.length > _lastCount) {
        final newCount = derived.length - _lastCount;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🔔 $newCount new alert(s) received'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.primaryGreen,
          ),
        );
      }
      _lastCount = derived.length;

      setState(() {
        _notifications = derived;
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
    return Scaffold(
      backgroundColor: AppColors.neutralLight,
      appBar: AppBar(
        title: const Text(
          'Notifications',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: Column(
                children: [
                  if (_error.isNotEmpty)
                    Container(
                      width: double.infinity,
                      color: AppColors.criticalRed.withValues(alpha: 0.1),
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        _error,
                        style: const TextStyle(
                          color: AppColors.criticalRed,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  Expanded(
                    child: _notifications.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.notifications_none,
                                  size: 64,
                                  color: Colors.grey[300],
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'No new notifications',
                                  style: TextStyle(color: Colors.grey[500]),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: _notifications.length,
                            itemBuilder: (context, index) {
                              final n = _notifications[index];
                              return Card(
                                elevation: 0,
                                margin: const EdgeInsets.only(bottom: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  side: BorderSide(
                                    color: Colors.grey.withValues(alpha: 0.1),
                                  ),
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.all(16),
                                  leading: CircleAvatar(
                                    backgroundColor: _getIconColor(
                                      n['type'],
                                    ).withValues(alpha: 0.1),
                                    child: Icon(
                                      _getIcon(n['type']),
                                      color: _getIconColor(n['type']),
                                    ),
                                  ),
                                  title: Text(
                                    n['title'],
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: 4),
                                      Text(n['body']),
                                      const SizedBox(height: 8),
                                      Text(
                                        _formatTime(n['time']),
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey[500],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  IconData _getIcon(String? type) {
    switch (type) {
      case 'sos':
        return Icons.sos;
      case 'need':
        return Icons.shopping_basket;
      case 'assignment':
        return Icons.campaign;
      case 'task':
        return Icons.assignment;
      default:
        return Icons.notifications;
    }
  }

  Color _getIconColor(String? type) {
    switch (type) {
      case 'sos':
        return AppColors.criticalRed;
      case 'need':
        return Colors.orange;
      case 'assignment':
        return Colors.blue;
      case 'task':
        return AppColors.primaryGreen;
      default:
        return Colors.grey;
    }
  }

  String _formatTime(dynamic time) {
    if (time == null) return '';
    try {
      final dt = DateTime.parse(time.toString());
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return '${dt.day}/${dt.month}';
    } catch (_) {
      return '';
    }
  }
}
