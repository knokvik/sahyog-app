import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api_client.dart';
import '../../theme/app_colors.dart';

/// Operations tab: Volunteers / Tasks / Needs as segmented top tabs.
class CoordinatorOperationsTab extends StatefulWidget {
  const CoordinatorOperationsTab({
    super.key,
    required this.api,
    this.initialTabIndex = 0,
  });

  final ApiClient api;
  final int initialTabIndex;

  @override
  State<CoordinatorOperationsTab> createState() =>
      _CoordinatorOperationsTabState();
}

class _CoordinatorOperationsTabState extends State<CoordinatorOperationsTab>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, dynamic>> _volunteers = [];
  List<Map<String, dynamic>> _tasks = [];
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;
  String _error = '';
  Timer? _pollTimer;

  // Task creation
  final _titleCtrl = TextEditingController();
  final _typeCtrl = TextEditingController(text: 'rescue');
  final _customTypeCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  XFile? _taskImage;
  List<Map<String, dynamic>> _selectedVolunteers = [];
  bool _creating = false;

  // Filters
  String _volunteersFilter = 'all'; // all, assigned, unassigned

  // View state

  // Expanded volunteer cards
  final Set<String> _expandedVolunteers = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTabIndex,
    );
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) _load(silent: true);
    });
  }

  @override
  void didUpdateWidget(CoordinatorOperationsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTabIndex != oldWidget.initialTabIndex) {
      _tabController.index = widget.initialTabIndex;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _pollTimer?.cancel();
    _titleCtrl.dispose();
    _typeCtrl.dispose();
    _customTypeCtrl.dispose();
    _descCtrl.dispose();
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
        widget.api.get('/api/v1/coordinator/volunteers'),
        widget.api.get('/api/v1/coordinator/tasks'),
        widget.api.get('/api/v1/tasks/history'),
      ]);
      if (!mounted) return;
      setState(() {
        _volunteers = _toList(results[0]);
        _tasks = _toList(results[1]);
        _history = _toList(results[2]);
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

  List<Map<String, dynamic>> _toList(dynamic raw) =>
      (raw is List) ? raw.cast<Map<String, dynamic>>() : [];

  // ── Volunteer Selection Panel ──────────────────────────────────────
  void _openVolunteerPanel({
    void Function(Map<String, dynamic>)? onSingleSelect,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (ctx) {
        final selectedIds = _selectedVolunteers
            .map((v) => v['id'].toString())
            .toSet();
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.85,
              expand: false,
              builder: (ctx, scrollController) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Text(
                            'Select Volunteers',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Done'),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        itemCount: _volunteers.length,
                        itemBuilder: (ctx, i) {
                          final v = _volunteers[i];
                          final id = v['id'].toString();
                          final name = (v['full_name'] ?? 'Unnamed').toString();
                          final isSelected = selectedIds.contains(id);
                          return CheckboxListTile(
                            value: isSelected,
                            title: Row(
                              children: [
                                Expanded(child: Text(name)),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        (v['is_active'] == true
                                                ? Colors.green
                                                : Colors.grey)
                                            .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color:
                                          (v['is_active'] == true
                                                  ? Colors.green
                                                  : Colors.grey)
                                              .withValues(alpha: 0.2),
                                    ),
                                  ),
                                  child: Text(
                                    v['is_active'] == true ? 'ACTIVE' : 'AWAY',
                                    style: TextStyle(
                                      color: v['is_active'] == true
                                          ? Colors.green
                                          : Colors.grey,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Text(
                              (v['email'] ?? '').toString(),
                              style: const TextStyle(fontSize: 12),
                            ),
                            secondary: CircleAvatar(
                              backgroundColor: AppColors.primaryGreen,
                              foregroundColor: Colors.white,
                              child: Text(name.isNotEmpty ? name[0] : '?'),
                            ),
                            onChanged: (checked) {
                              if (onSingleSelect != null) {
                                Navigator.pop(ctx);
                                onSingleSelect(v);
                                return;
                              }
                              setSheetState(() {
                                if (checked == true) {
                                  selectedIds.add(id);
                                } else {
                                  selectedIds.remove(id);
                                }
                              });
                              setState(() {
                                if (checked == true) {
                                  _selectedVolunteers.add(v);
                                } else {
                                  _selectedVolunteers.removeWhere(
                                    (sv) => sv['id'].toString() == id,
                                  );
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  // ── Task CRUD ──────────────────────────────────────────────────────
  Future<void> _createTask() async {
    String finalType = _typeCtrl.text;
    if (finalType == 'other' && _customTypeCtrl.text.trim().isNotEmpty) {
      finalType = _customTypeCtrl.text.trim();
    }

    if (_titleCtrl.text.trim().isEmpty || finalType.trim().isEmpty) {
      _snack('Title and type are required.');
      return;
    }

    if (_selectedVolunteers.isEmpty) {
      _snack('At least one volunteer must be assigned.');
      return;
    }
    try {
      setState(() => _creating = true);
      Map<String, dynamic> baseBody = {
        'title': _titleCtrl.text.trim(),
        'type': finalType.trim(),
        'description': _descCtrl.text.trim().isEmpty
            ? null
            : _descCtrl.text.trim(),
        'photo_path': _taskImage?.path ?? '',
        'status': 'in_progress', // Default to started as requested
      };

      for (final v in _selectedVolunteers) {
        await widget.api.post(
          '/api/v1/coordinator/tasks',
          body: {...baseBody, 'volunteer_id': v['id'].toString()},
        );
      }
      _titleCtrl.clear();
      _descCtrl.clear();
      _customTypeCtrl.clear();
      setState(() {
        _selectedVolunteers = [];
        _taskImage = null;
      });
      _snack('Task created.');
      await _load();
    } catch (e) {
      _snack('Create failed: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _reassignTask(String taskId, String volId) async {
    try {
      await widget.api.patch(
        '/api/v1/coordinator/tasks/$taskId/reassign',
        body: {'volunteer_id': volId},
      );
      _snack('Task reassigned.');
      await _load();
    } catch (e) {
      _snack('Reassign failed: $e');
    }
  }

  Future<void> _updateTaskStatus(
    String taskId,
    String status, {
    List<String>? proofImages,
  }) async {
    try {
      final body = <String, dynamic>{'status': status};
      if (proofImages != null && proofImages.isNotEmpty) {
        body['proof_images'] = proofImages;
      }
      await widget.api.patch('/api/v1/tasks/$taskId/status', body: body);
      _snack('Task → $status');
      await _load();
    } catch (e) {
      _snack('Update failed: $e');
    }
  }

  /// Shows a proof image picker dialog before completing a task.
  Future<void> _completeTaskWithProof(String taskId) async {
    final List<XFile> proofFiles = [];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.camera_alt_outlined,
                    size: 48,
                    color: AppColors.primaryGreen,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Upload Proof',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Add at least one photo as evidence of task completion.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[600], height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  if (proofFiles.isNotEmpty)
                    SizedBox(
                      height: 80,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: proofFiles.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.file(
                                  File(proofFiles[i].path),
                                  width: 80,
                                  height: 80,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              Positioned(
                                top: 0,
                                right: 0,
                                child: GestureDetector(
                                  onTap: () => setDialogState(
                                    () => proofFiles.removeAt(i),
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final files = await ImagePicker().pickMultiImage(
                        imageQuality: 70,
                      );
                      if (files.isNotEmpty) {
                        setDialogState(() => proofFiles.addAll(files));
                      }
                    },
                    icon: const Icon(Icons.add_a_photo_outlined),
                    label: Text(
                      proofFiles.isEmpty ? 'Select Photos' : 'Add More',
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: proofFiles.isEmpty
                              ? null
                              : () => Navigator.pop(ctx, true),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primaryGreen,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('Complete Task'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (confirmed != true || proofFiles.isEmpty) return;
    // Upload images to Supabase via backend
    try {
      final result = await widget.api.uploadFiles(
        '/api/v1/uploads/task-proof',
        fieldName: 'images',
        filePaths: proofFiles.map((f) => f.path).toList(),
        query: {'task_id': taskId},
      );
      final urls = (result is Map && result['urls'] is List)
          ? (result['urls'] as List).cast<String>()
          : <String>[];
      if (urls.isEmpty) {
        _snack('Upload failed — no URLs returned');
        return;
      }
      await _updateTaskStatus(taskId, 'completed', proofImages: urls);
    } catch (e) {
      _snack('Image upload failed: $e');
    }
  }

  Future<void> _deleteTask(String taskId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.grey.withValues(alpha: 0.2), width: 1),
        ),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.delete_sweep_outlined,
                size: 48,
                color: AppColors.criticalRed,
              ),
              const SizedBox(height: 16),
              Text(
                'Delete Task?',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                'This action will permanently remove this task. You cannot undo this.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600], height: 1.5),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.criticalRed,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Delete'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.delete('/api/v1/coordinator/tasks/$taskId');
      _snack('Task deleted.');
      await _load();
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Build ──────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          labelColor: AppColors.primaryGreen,
          unselectedLabelColor: Colors.grey,
          indicatorColor: AppColors.primaryGreen,
          tabs: const [
            Tab(text: 'Volunteers'),
            Tab(text: 'Tasks'),
            Tab(text: 'History'),
          ],
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _error,
              style: const TextStyle(color: AppColors.criticalRed),
            ),
          ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildVolunteersTab(),
              _buildTasksTab(),
              _buildHistoryTab(),
            ],
          ),
        ),
      ],
    );
  }

  // ── Volunteers ─────────────────────────────────────────────────────
  Widget _buildVolunteersTab() {
    final filtered = _volunteersFilter == 'all'
        ? _volunteers
        : _volunteers.where((v) {
            final id = v['id'].toString();
            final assignedTasks = _tasks
                .where((t) => t['volunteer_id']?.toString() == id)
                .toList();
            if (_volunteersFilter == 'assigned') {
              return assignedTasks.isNotEmpty;
            }
            if (_volunteersFilter == 'unassigned') {
              return assignedTasks.isEmpty;
            }
            return true;
          }).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Wrap(
            spacing: 8,
            children: ['all', 'assigned', 'unassigned'].map((s) {
              return ChoiceChip(
                label: Text(s.toUpperCase()),
                selected: _volunteersFilter == s,
                onSelected: (_) => setState(() => _volunteersFilter = s),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          if (filtered.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('No volunteers found.')),
              ),
            )
          else
            ...filtered.map((v) {
              final id = v['id'].toString();
              final name = (v['full_name'] ?? 'Unnamed').toString();
              final email = (v['email'] ?? '').toString();
              final verified = v['is_verified'] == true;
              final active = v['is_active'] == true;
              final expanded = _expandedVolunteers.contains(id);
              final assignedTasks = _tasks
                  .where((t) => t['volunteer_id']?.toString() == id)
                  .toList();

              return Card(
                child: InkWell(
                  onTap: () => setState(() {
                    expanded
                        ? _expandedVolunteers.remove(id)
                        : _expandedVolunteers.add(id);
                  }),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: AppColors.primaryGreen,
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
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    email,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            if (verified)
                              const Icon(
                                Icons.verified,
                                color: AppColors.primaryGreen,
                                size: 18,
                              ),
                            const SizedBox(width: 4),
                            Chip(
                              label: Text(
                                active ? 'ACTIVE' : 'AWAY',
                                style: const TextStyle(fontSize: 9),
                              ),
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              backgroundColor: active
                                  ? Colors.green.shade50
                                  : Colors.grey.shade200,
                            ),
                            Icon(
                              expanded ? Icons.expand_less : Icons.expand_more,
                              size: 20,
                            ),
                          ],
                        ),
                        if (expanded) ...[
                          const Divider(height: 16),
                          Text(
                            'Assigned Tasks (${assignedTasks.length})',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (assignedTasks.isEmpty)
                            const Text(
                              'No tasks assigned.',
                              style: TextStyle(fontSize: 12),
                            )
                          else
                            ...assignedTasks.map(
                              (t) => Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.circle,
                                      size: 6,
                                      color: AppColors.primaryGreen,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '${t['title'] ?? t['type']} — ${(t['status'] ?? 'pending').toString().toUpperCase()}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
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

  // ── Tasks ──────────────────────────────────────────────────────────
  void _openTaskForm() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
                left: 24,
                right: 24,
                top: 32,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
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
                    DropdownButtonFormField<String>(
                      value: _typeCtrl.text,
                      decoration: const InputDecoration(
                        labelText: 'Task Type',
                        prefixIcon: Icon(Icons.category_outlined),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'rescue',
                          child: Text('Rescue'),
                        ),
                        DropdownMenuItem(
                          value: 'relief',
                          child: Text('Relief Distribution'),
                        ),
                        DropdownMenuItem(
                          value: 'medical',
                          child: Text('Medical Aid'),
                        ),
                        DropdownMenuItem(
                          value: 'transport',
                          child: Text('Logistics/Transport'),
                        ),
                        DropdownMenuItem(
                          value: 'food',
                          child: Text('Food/Water'),
                        ),
                        DropdownMenuItem(
                          value: 'other',
                          child: Text('Other (Specify)'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setSheetState(() => _typeCtrl.text = v);
                        }
                      },
                    ),
                    if (_typeCtrl.text == 'other') ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: _customTypeCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Specify Type',
                          prefixIcon: Icon(Icons.edit_note_outlined),
                          hintText: 'e.g. Shelter Setup',
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    TextField(
                      controller: _descCtrl,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        prefixIcon: Icon(Icons.notes_outlined),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Reference Image (Optional)',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () async {
                        final file = await ImagePicker().pickImage(
                          source: ImageSource.gallery,
                          imageQuality: 70,
                        );
                        if (file != null) {
                          setSheetState(() => _taskImage = file);
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        height: 120,
                        decoration: BoxDecoration(
                          color: Colors.grey[50],
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.grey.withValues(alpha: 0.2),
                            width: 1.5,
                          ),
                        ),
                        child: _taskImage == null
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.add_a_photo_outlined,
                                    color: Colors.grey[400],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Click to upload reference',
                                    style: TextStyle(
                                      color: Colors.grey[500],
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              )
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Image.file(
                                  File(_taskImage!.path),
                                  fit: BoxFit.cover,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openVolunteerPanel();
                      },
                      icon: const Icon(Icons.person_add_outlined),
                      label: Text(
                        _selectedVolunteers.isEmpty
                            ? 'Select Volunteers'
                            : '${_selectedVolunteers.length} selected',
                      ),
                    ),
                    if (_selectedVolunteers.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: _selectedVolunteers.map((v) {
                            return Chip(
                              label: Text(
                                (v['full_name'] ?? 'Unnamed').toString(),
                                style: const TextStyle(fontSize: 12),
                              ),
                              onDeleted: () {
                                setSheetState(() {
                                  _selectedVolunteers.removeWhere(
                                    (sv) => sv['id'] == v['id'],
                                  );
                                });
                                setState(() {
                                  _selectedVolunteers.removeWhere(
                                    (sv) => sv['id'] == v['id'],
                                  );
                                });
                              },
                            );
                          }).toList(),
                        ),
                      ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _creating
                            ? null
                            : () {
                                Navigator.pop(ctx);
                                _createTask();
                              },
                        icon: const Icon(Icons.add_task),
                        label: const Text('Create Task'),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTasksTab() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openTaskForm,
        icon: const Icon(Icons.add),
        label: const Text('New Task'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(
            top: 12,
            left: 12,
            right: 12,
            bottom: 80,
          ),
          children: [
            // Task list
            if (_tasks.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('No tasks yet.'),
                ),
              )
            else
              ..._tasks.map(_buildTaskCard),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskCard(Map<String, dynamic> task) {
    final id = (task['id'] ?? '').toString();
    final status = (task['status'] ?? 'pending').toString();
    final volunteerName = (task['volunteer_name'] ?? 'Unassigned').toString();
    final desc = (task['description'] ?? '').toString();

    return Card(
      child: InkWell(
        onTap: () => _openTaskDetails(task),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      (task['title'] ?? task['type'] ?? 'Task').toString(),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  _StatusLabel(status: status),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(
                    Icons.person_pin_circle_outlined,
                    size: 14,
                    color: Colors.grey,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Assigned to: $volunteerName',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              if (desc.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    desc,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 1.4),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => _openVolunteerPanel(
                      onSingleSelect: (v) =>
                          _reassignTask(id, v['id'].toString()),
                    ),
                    icon: const Icon(Icons.swap_horiz, size: 16),
                    label: const Text(
                      'Quick Reassign',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: id.isEmpty ? null : () => _deleteTask(id),
                    icon: const Icon(
                      Icons.delete_outline,
                      color: AppColors.criticalRed,
                      size: 20,
                    ),
                    tooltip: 'Delete',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openTaskDetails(Map<String, dynamic> task) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
          ),
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (task['title'] ?? 'Task Detail').toString(),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          (task['type'] ?? '').toString().toUpperCase(),
                          style: TextStyle(
                            color: AppColors.primaryGreen,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _StatusLabel(
                    status: task['status']?.toString() ?? 'pending',
                    large: true,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _DetailRow(
                icon: Icons.person_outline,
                label: 'Assigned Volunteer',
                value: (task['volunteer_name'] ?? 'Unassigned').toString(),
              ),
              _DetailRow(
                icon: Icons.calendar_today_outlined,
                label: 'Assigned At',
                value: _formatDate(task['created_at']),
              ),
              const SizedBox(height: 24),
              const Text(
                'Description',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                (task['description'] ?? 'No description provided.').toString(),
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: Colors.blueGrey,
                ),
              ),
              const SizedBox(height: 24),
              // Proof Images
              if (task['proof_images'] != null &&
                  (task['proof_images'] as List).isNotEmpty) ...[
                const Text(
                  'Completion Proof',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 100,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: (task['proof_images'] as List).length,
                    itemBuilder: (_, i) {
                      final img = (task['proof_images'] as List)[i].toString();
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: img.startsWith('http')
                              ? Image.network(
                                  img,
                                  width: 100,
                                  height: 100,
                                  fit: BoxFit.cover,
                                )
                              : Container(
                                  width: 100,
                                  height: 100,
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryGreen.withValues(
                                      alpha: 0.1,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.image,
                                        color: AppColors.primaryGreen,
                                      ),
                                      Text(
                                        'Proof',
                                        style: TextStyle(fontSize: 10),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 24),
              ],
              const SizedBox(height: 8),
              const Text(
                'Operational Actions',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _ActionButton(
                    label: 'Mark Completed',
                    icon: Icons.check_circle_outline,
                    color: AppColors.primaryGreen,
                    onPressed: () {
                      Navigator.pop(ctx);
                      _completeTaskWithProof(task['id'].toString());
                    },
                  ),
                  _ActionButton(
                    label: 'Reassign Mission',
                    icon: Icons.swap_horiz,
                    color: AppColors.infoBlue,
                    onPressed: () {
                      Navigator.pop(ctx);
                      _openVolunteerPanel(
                        onSingleSelect: (v) => _reassignTask(
                          task['id'].toString(),
                          v['id'].toString(),
                        ),
                      );
                    },
                  ),
                  _ActionButton(
                    label: 'Emergency Recall',
                    icon: Icons.cancel_outlined,
                    color: AppColors.criticalRed,
                    onPressed: () {
                      Navigator.pop(ctx);
                      _deleteTask(task['id'].toString());
                    },
                  ),
                ],
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryTab() {
    if (_history.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Container(
            height: 400,
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.history_toggle_off,
                  size: 64,
                  color: Colors.grey[300],
                ),
                const SizedBox(height: 16),
                Text(
                  'No mission history yet',
                  style: TextStyle(color: Colors.grey[500]),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _history.length,
        itemBuilder: (ctx, i) {
          final item = _history[i];
          final isTask = item.containsKey('title');
          return Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.grey.withValues(alpha: 0.1)),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: CircleAvatar(
                backgroundColor: AppColors.primaryGreen.withValues(alpha: 0.1),
                child: Icon(
                  isTask ? Icons.task_alt : Icons.done_all,
                  color: AppColors.primaryGreen,
                ),
              ),
              title: Text(
                (item['title'] ?? item['type'] ?? 'Completed Item').toString(),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                'Completed by: ${item['volunteer_name'] ?? 'Self/Admin'}\nDate: ${_formatDate(item['completed_at'] ?? item['resolved_at'])}',
                style: const TextStyle(fontSize: 12),
              ),
              isThreeLine: true,
            ),
          );
        },
      ),
    );
  }

  String _formatDate(dynamic d) {
    if (d == null) return 'Recently';
    try {
      final dt = DateTime.parse(d.toString());
      return '${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return d.toString();
    }
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.status, this.large = false});
  final String status;
  final bool large;

  @override
  Widget build(BuildContext context) {
    Color color = Colors.grey;
    if (status == 'in_progress' || status == 'accepted')
      color = AppColors.infoBlue;
    if (status == 'completed') color = AppColors.primaryGreen;
    if (status == 'rejected' || status == 'canceled')
      color = AppColors.criticalRed;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 12 : 8,
        vertical: large ? 6 : 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: large ? 12 : 9,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 20, color: Colors.grey[600]),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: (MediaQuery.of(context).size.width - 60) / 2,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.5)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        icon: Icon(icon, size: 18),
        label: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
