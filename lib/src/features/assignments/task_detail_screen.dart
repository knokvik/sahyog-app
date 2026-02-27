import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../theme/app_colors.dart';

class TaskDetailScreen extends StatefulWidget {
  const TaskDetailScreen({
    super.key,
    required this.api,
    required this.user,
    required this.task,
  });

  final ApiClient api;
  final AppUser user;
  final Map<String, dynamic> task;

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  late Map<String, dynamic> _task;
  bool _loading = false;
  final ImagePicker _picker = ImagePicker();
  List<XFile> _selectedProofImages = [];

  @override
  void initState() {
    super.initState();
    _task = widget.task;
  }

  Future<void> _updateStatus(String status) async {
    setState(() => _loading = true);
    try {
      final updated = await widget.api.patch(
        '/api/v1/tasks/${_task['id']}/status',
        body: {'status': status},
      );
      if (mounted) {
        setState(() {
          _task = updated as Map<String, dynamic>;
          _loading = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Task $status')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        // Handle new validation errors from backend
        final errorMsg = e.toString();
        String displayMsg = 'Error: $e';
        
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
  }

  Future<void> _pickProofImages() async {
    try {
      final List<XFile> images = await _picker.pickMultiImage();
      if (images.isNotEmpty) {
        setState(() {
          _selectedProofImages = images;
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pick images: $e')),
      );
    }
  }

  Future<List<String>> _uploadImagesToStorage() async {
    // TODO: Implement actual image upload to your storage service (e.g., Firebase Storage, S3)
    // For now, return placeholder URLs - replace with actual upload logic
    return _selectedProofImages.map((_) => 'https://storage.example.com/proof.jpg').toList();
  }

  Future<void> _uploadProof() async {
    if (_selectedProofImages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select at least one photo as proof'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      // Upload images to storage and get URLs
      final proofUrls = await _uploadImagesToStorage();
      
      final updated = await widget.api.patch(
        '/api/v1/tasks/${_task['id']}/status',
        body: {
          'status': 'completed',
          'proof_images': proofUrls,
          'persons_helped': 5,
        },
      );
      if (mounted) {
        setState(() {
          _task = updated as Map<String, dynamic>;
          _selectedProofImages = [];
          _loading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Proof uploaded and task completed!')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _requestHelp() async {
    final noteController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request More Help'),
        content: TextField(
          controller: noteController,
          decoration: const InputDecoration(
            hintText: 'Describe what assistance is needed...',
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send Request'),
          ),
        ],
      ),
    );

    if (result == true) {
      setState(() => _loading = true);
      try {
        await widget.api.post(
          '/api/v1/tasks/${_task['id']}/request-help',
          body: {'note': noteController.text, 'type': 'volunteer'},
        );
        if (mounted) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Help request sent to coordinators.')),
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Request failed: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = (_task['status'] ?? 'pending').toString();
    final isAssignedToMe = _task['volunteer_id'] == widget.user.id;
    final isUnassigned = _task['volunteer_id'] == null;

    return Scaffold(
      appBar: AppBar(title: const Text('Task Details')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildHeader(),
                const Divider(height: 32),
                _buildInfoSection(),
                const Divider(height: 32),
                _buildDescription(),
                const SizedBox(height: 32),
                _buildActions(status, isAssignedToMe, isUnassigned),
              ],
            ),
    );
  }

  Widget _buildHeader() {
    final type = (_task['type'] ?? 'Task').toString();
    final status = (_task['status'] ?? 'pending').toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primaryGreen.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                type.toUpperCase(),
                style: const TextStyle(
                  color: AppColors.primaryGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _getStatusColor(status).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                status.toUpperCase(),
                style: TextStyle(
                  color: _getStatusColor(status),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          (_task['title'] ?? 'Unnamed Task').toString(),
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'Created ${_formatDate(_task['created_at'])}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildInfoSection() {
    return Column(
      children: [
        _buildInfoTile(
          Icons.person,
          'Assigned Volunteer',
          (_task['volunteer_name'] ?? 'Not Assigned').toString(),
        ),
        _buildInfoTile(
          Icons.assignment_ind,
          'Assigned By',
          (_task['assigned_by_name'] ?? 'System/Coordinator').toString(),
        ),
        _buildInfoTile(
          Icons.location_on,
          'Meeting Point',
          _task['meeting_point'] != null ? 'View on Map' : 'Not specified',
          isLink: _task['meeting_point'] != null,
        ),
      ],
    );
  }

  Widget _buildInfoTile(
    IconData icon,
    String label,
    String value, {
    bool isLink = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey[600]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: isLink ? AppColors.primaryGreen : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDescription() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Description',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          (_task['description'] ?? 'No description provided.').toString(),
          style: const TextStyle(fontSize: 15, height: 1.4),
        ),
      ],
    );
  }

  Widget _buildActions(String status, bool isAssignedToMe, bool isUnassigned) {
    if (status == 'completed' || status == 'resolved') {
      return const Center(child: Text('This task is already completed.'));
    }

    final taskType = (_task['type'] ?? '').toString().toLowerCase();
    final requiresSpecialTraining = ['medical', 'rescue', 'fire', 'evacuation'].contains(taskType);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Show skill requirement warning for critical tasks
        if (requiresSpecialTraining && isUnassigned)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This $taskType task requires specific training.',
                    style: const TextStyle(color: Colors.orange, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),

        if (isUnassigned)
          FilledButton.icon(
            onPressed: () => _updateStatus('accepted'),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Accept This Task'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: AppColors.primaryGreen,
            ),
          ),

        if (isAssignedToMe && status == 'accepted')
          FilledButton.icon(
            onPressed: () => _updateStatus('in_progress'),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start Work'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),

        if (isAssignedToMe && status == 'in_progress') ...[
          // Proof image picker
          if (_selectedProofImages.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_selectedProofImages.length} image(s) selected',
                      style: const TextStyle(color: Colors.green, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _selectedProofImages = []),
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),

          OutlinedButton.icon(
            onPressed: _pickProofImages,
            icon: const Icon(Icons.photo_library),
            label: Text(_selectedProofImages.isEmpty ? 'Select Proof Photos' : 'Add More Photos'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _uploadProof,
            icon: const Icon(Icons.cloud_upload),
            label: const Text('Complete & Upload Proof'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: AppColors.primaryGreen,
            ),
          ),
        ],

        const SizedBox(height: 12),
        if (isAssignedToMe)
          OutlinedButton.icon(
            onPressed: _requestHelp,
            icon: const Icon(Icons.group_add),
            label: const Text('Request More Hands'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
      ],
    );
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return Colors.orange;
      case 'accepted':
        return Colors.blue;
      case 'in_progress':
        return Colors.purple;
      case 'completed':
        return AppColors.primaryGreen;
      default:
        return Colors.grey;
    }
  }

  String _formatDate(dynamic date) {
    if (date == null) return 'N/A';
    try {
      final dt = DateTime.parse(date.toString());
      return '${dt.day}/${dt.month} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return date.toString();
    }
  }
}
