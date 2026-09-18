import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../theme/app_colors.dart';

class UserProfileCompletionScreen extends StatefulWidget {
  const UserProfileCompletionScreen({
    super.key,
    required this.api,
    required this.user,
    required this.onCompleted,
  });

  final ApiClient api;
  final AppUser user;
  final VoidCallback onCompleted;

  @override
  State<UserProfileCompletionScreen> createState() =>
      _UserProfileCompletionScreenState();
}

class _UserProfileCompletionScreenState
    extends State<UserProfileCompletionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneCtrl = TextEditingController();
  final _bloodGroupCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _medicalHistoryCtrl = TextEditingController();

  bool _loading = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _phoneCtrl.text = widget.user.phone ?? '';
    _bloodGroupCtrl.text = widget.user.bloodGroup ?? '';
    _addressCtrl.text = widget.user.address ?? '';
    _medicalHistoryCtrl.text = widget.user.medicalHistory ?? '';
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _bloodGroupCtrl.dispose();
    _addressCtrl.dispose();
    _medicalHistoryCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _error = '';
    });

    try {
      await widget.api.put(
        '/api/users/me',
        body: {
          'phone': _phoneCtrl.text.trim(),
          'blood_group': _bloodGroupCtrl.text.trim().toUpperCase(),
          'address': _addressCtrl.text.trim(),
          'medical_history': _medicalHistoryCtrl.text.trim(),
        },
      );

      if (!mounted) return;
      widget.onCompleted();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to update profile: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Complete Your Profile')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.person_pin_circle,
                size: 64,
                color: AppColors.primaryGreen,
              ),
              const SizedBox(height: 16),
              Text(
                'Welcome, ${widget.user.name}!',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Please complete your profile to access all features. We need this information to help you effectively during emergencies.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),

              if (_error.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.criticalRed.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.criticalRed.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    _error,
                    style: const TextStyle(color: AppColors.criticalRed),
                  ),
                ),
                const SizedBox(height: 24),
              ],

              TextFormField(
                controller: _phoneCtrl,
                decoration: const InputDecoration(
                  labelText: 'Phone Number',
                  hintText: 'e.g. +91 9876543210',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone),
                ),
                keyboardType: TextInputType.phone,
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter your phone number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _bloodGroupCtrl.text.isNotEmpty
                    ? _bloodGroupCtrl.text
                    : null,
                items: ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']
                    .map((bg) => DropdownMenuItem(value: bg, child: Text(bg)))
                    .toList(),
                onChanged: (val) {
                  if (val != null) _bloodGroupCtrl.text = val;
                },
                decoration: const InputDecoration(
                  labelText: 'Blood Group',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.bloodtype),
                ),
                validator: (val) {
                  if (val == null || val.isEmpty) {
                    return 'Please select your blood group';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _addressCtrl,
                decoration: const InputDecoration(
                  labelText: 'Residential Address',
                  hintText: 'Your full address',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.home),
                ),
                maxLines: 2,
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter your address';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _medicalHistoryCtrl,
                decoration: const InputDecoration(
                  labelText: 'Medical History (Optional)',
                  hintText: 'Allergies, chronic conditions, etc.',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.medical_services),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 32),

              if (_loading)
                const Center(child: CircularProgressIndicator())
              else
                FilledButton(
                  onPressed: _submit,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  child: const Text('Save Profile'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
