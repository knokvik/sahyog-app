import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../../core/api_client.dart';
import '../../theme/app_colors.dart';

class LocationOnboardingDialog extends StatefulWidget {
  const LocationOnboardingDialog({
    super.key,
    required this.api,
    required this.onCompleted,
  });

  final ApiClient api;
  final VoidCallback onCompleted;

  @override
  State<LocationOnboardingDialog> createState() =>
      _LocationOnboardingDialogState();
}

class _LocationOnboardingDialogState extends State<LocationOnboardingDialog> {
  bool _loading = false;
  String? _error;
  List<dynamic> _nearbyOrgs = [];
  bool _showOrgs = false;

  Future<void> _handleLocationPermission() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are disabled.');
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception('Location permissions are denied.');
        }
      }

      if (permission == LocationPermission.deniedForever) {
        throw Exception('Location permissions are permanently denied.');
      }

      final position = await Geolocator.getCurrentPosition();

      // Update user location in backend
      await widget.api.put(
        '/api/users/me/location',
        body: {'lat': position.latitude, 'lng': position.longitude},
      );

      // Fetch nearby NGOs
      final orgs = await widget.api.get(
        '/api/organizations/nearby',
        query: {
          'lat': position.latitude.toString(),
          'lng': position.longitude.toString(),
          'radius': '50000', // 50km
        },
      );

      setState(() {
        _nearbyOrgs = orgs is List ? orgs : [];
        _showOrgs = true;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _joinOrg(String orgId) async {
    setState(() => _loading = true);
    try {
      await widget.api.post(
        '/api/organizations/join',
        body: {'organization_id': orgId},
      );
      widget.onCompleted();
    } catch (e) {
      setState(() {
        _error = 'Failed to join: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_showOrgs) ...[
              const Icon(
                Icons.location_on,
                size: 64,
                color: AppColors.primaryGreen,
              ),
              const SizedBox(height: 16),
              const Text(
                'Enable Location',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'To suggest the best NGOs and organizations near you, we need your current location.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              if (_error != null)
                Text(
                  _error!,
                  style: const TextStyle(color: AppColors.criticalRed),
                ),
              const SizedBox(height: 16),
              if (_loading)
                const CircularProgressIndicator()
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _handleLocationPermission,
                    child: const Text('Enable & Find NGOs'),
                  ),
                ),
            ] else ...[
              const Text(
                'Nearby Organizations',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text('Suggested for your local area'),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _nearbyOrgs.length + 1,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (context, index) {
                    if (index == _nearbyOrgs.length) {
                      return ListTile(
                        leading: const Icon(
                          Icons.account_balance,
                          color: Colors.blue,
                        ),
                        title: const Text('Proceed with Government'),
                        subtitle: const Text('Standard disaster response'),
                        onTap: () => widget.onCompleted(),
                      );
                    }
                    final org = _nearbyOrgs[index];
                    return ListTile(
                      title: Text(org['name']),
                      subtitle: Text(
                        '${(org['distance'] / 1000).toStringAsFixed(1)} km away',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _joinOrg(org['id']),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Text(
                  _error!,
                  style: const TextStyle(color: AppColors.criticalRed),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
