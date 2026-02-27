import 'dart:async';

import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher/url_launcher.dart';

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

      final endpoint = widget.user.isCoordinator
          ? '/api/v1/coordinator/sos'
          : '/api/v1/sos';

      final raw = await widget.api.get(endpoint);
      final list = (raw is List)
          ? raw.cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];

      if (!mounted) return;

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

  Future<void> _updateStatus(
    String id,
    String status, {
    String? assignedVolunteerId,
  }) async {
    try {
      final body = <String, dynamic>{'status': status};
      if (assignedVolunteerId != null) {
        body['assigned_volunteer_id'] = assignedVolunteerId;
      }
      await widget.api.patch('/api/v1/sos/$id/status', body: body);
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

  /// Show a dialog to pick a volunteer from the coordinator's zone.
  Future<void> _showAssignVolunteerDialog(String sosId) async {
    List<Map<String, dynamic>> volunteers = [];
    bool loadingVols = true;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            if (loadingVols) {
              widget.api
                  .get('/api/v1/coordinator/my-zone-volunteers')
                  .then((raw) {
                    final vols = (raw is List)
                        ? raw.cast<Map<String, dynamic>>()
                        : <Map<String, dynamic>>[];
                    setDialogState(() {
                      volunteers = vols;
                      loadingVols = false;
                    });
                  })
                  .catchError((_) {
                    setDialogState(() => loadingVols = false);
                  });
            }

            return Dialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Assign Volunteer',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Select a volunteer to investigate this SOS',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    if (loadingVols)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      )
                    else if (volunteers.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No volunteers found in your zones.'),
                      )
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 300),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: volunteers.length,
                          itemBuilder: (ctx, i) {
                            final v = volunteers[i];
                            final name = (v['full_name'] ?? 'Volunteer')
                                .toString();
                            final vid = (v['id'] ?? '').toString();
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: AppColors.primaryGreen
                                    .withValues(alpha: 0.15),
                                child: Text(
                                  name.isEmpty ? '?' : name[0].toUpperCase(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryGreen,
                                  ),
                                ),
                              ),
                              title: Text(
                                name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                v['phone']?.toString() ?? 'No phone',
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: FilledButton(
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _updateStatus(
                                    sosId,
                                    'acknowledged',
                                    assignedVolunteerId: vid,
                                  );
                                },
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.primaryGreen,
                                  minimumSize: const Size(0, 32),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                ),
                                child: const Text(
                                  'Assign',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showNavigationAppChooser(
    _SosDestination destination,
    String label,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Navigate to $label',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    backgroundColor: Color(0x1A34A853),
                    child: Icon(Icons.map, color: Color(0xFF34A853)),
                  ),
                  title: const Text('Google Maps'),
                  subtitle: const Text('Turn-by-turn directions'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _launchNavigation(
                      providerName: 'Google Maps',
                      appUri: Uri.parse(
                        'comgooglemaps://?daddr=${destination.latitude},${destination.longitude}&directionsmode=driving',
                      ),
                      fallbackUri: Uri.parse(
                        'https://www.google.com/maps/dir/?api=1&destination=${destination.latitude},${destination.longitude}',
                      ),
                    );
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    backgroundColor: Color(0x1A007AFF),
                    child: Icon(Icons.navigation, color: Color(0xFF007AFF)),
                  ),
                  title: const Text('Apple Maps'),
                  subtitle: const Text('Open with Apple Maps'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _launchNavigation(
                      providerName: 'Apple Maps',
                      appUri: Uri.parse(
                        'maps://?daddr=${destination.latitude},${destination.longitude}&dirflg=d',
                      ),
                      fallbackUri: Uri.parse(
                        'http://maps.apple.com/?daddr=${destination.latitude},${destination.longitude}&dirflg=d',
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _launchNavigation({
    required String providerName,
    required Uri appUri,
    required Uri fallbackUri,
  }) async {
    try {
      final openedApp = await launchUrl(
        appUri,
        mode: LaunchMode.externalApplication,
      );
      if (openedApp) return;

      final openedFallback = await launchUrl(
        fallbackUri,
        mode: LaunchMode.externalApplication,
      );
      if (!openedFallback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open $providerName.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Navigation launch failed: $e')));
    }
  }

  _SosDestination? _extractSosDestination(Map<String, dynamic> alert) {
    final candidates = <dynamic>[
      alert,
      alert['location'],
      alert['current_location'],
      alert['reporter_location'],
      alert['geo'],
      alert['geometry'],
    ];

    for (final candidate in candidates) {
      final parsed = _parseSosDestination(candidate);
      if (parsed != null) return parsed;
    }
    return null;
  }

  _SosDestination? _parseSosDestination(dynamic raw) {
    final map = _asMap(raw);
    if (map != null) {
      final lat = parseLat(
        map['lat'] ?? map['latitude'] ?? map['center_lat'] ?? map['y'],
      );
      final lng = parseLng(
        map['lng'] ??
            map['lon'] ??
            map['longitude'] ??
            map['center_lng'] ??
            map['x'],
      );
      if (lat != null && lng != null) {
        return _SosDestination(latitude: lat, longitude: lng);
      }

      final coordinates = map['coordinates'];
      if (coordinates is List && coordinates.length >= 2) {
        final lngValue = parseLng(coordinates[0]);
        final latValue = parseLat(coordinates[1]);
        if (latValue != null && lngValue != null) {
          return _SosDestination(latitude: latValue, longitude: lngValue);
        }
      }

      final nested = _parseSosDestination(
        map['location'] ?? map['point'] ?? map['geometry'],
      );
      if (nested != null) return nested;
    }

    if (raw is String) {
      final pointMatch = RegExp(
        r'POINT\(\s*(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*\)',
      ).firstMatch(raw);
      if (pointMatch != null) {
        final lng = double.tryParse(pointMatch.group(1)!);
        final lat = double.tryParse(pointMatch.group(2)!);
        if (lat != null && lng != null) {
          return _SosDestination(latitude: lat, longitude: lng);
        }
      }
    }

    return null;
  }

  Map<String, dynamic>? _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Missing Persons'),
              Tab(text: 'SOS Alerts'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                MissingTab(api: widget.api),
                _buildSosTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSosTab() {
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
                  'SOS Monitoring',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text('SOS alerts within your area.'),
                const SizedBox(height: 10),
                if (_error.isNotEmpty)
                  Text(
                    _error,
                    style: const TextStyle(color: AppColors.criticalRed),
                  ),
                if (_alerts.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: Text('No SOS alerts found.'),
                    ),
                  )
                else
                  ..._alerts.map(_buildAlertCard),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlertCard(Map<String, dynamic> alert) {
    final id = (alert['id'] ?? '').toString();
    final status = (alert['status'] ?? 'triggered').toString();
    final isActive = status == 'triggered';
    final isAcknowledged = status == 'acknowledged';
    final isResolved = status == 'resolved';
    final reporterName =
        (alert['reporter_name'] ?? alert['reporter_phone'] ?? 'Sahayanet User')
            .toString();
    final assignedVolName = (alert['assigned_volunteer_name'] ?? '').toString();
    final hasProof =
        alert['resolution_proof'] != null &&
        alert['resolution_proof'].toString().isNotEmpty;
    final destination = _extractSosDestination(alert);

    // Derive effective status label
    String statusLabel;
    Color statusColor;
    if (isResolved) {
      statusLabel = 'RESOLVED';
      statusColor = AppColors.primaryGreen;
    } else if (isAcknowledged && hasProof) {
      statusLabel = 'PROOF UPLOADED';
      statusColor = Colors.blue;
    } else if (isAcknowledged) {
      statusLabel = assignedVolName.isNotEmpty ? 'ASSIGNED' : 'ACKNOWLEDGED';
      statusColor = Colors.orange;
    } else if (isActive) {
      statusLabel = 'ACTIVE';
      statusColor = AppColors.criticalRed;
    } else {
      statusLabel = status.toUpperCase();
      statusColor = Colors.grey;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: isActive ? 2 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isActive
              ? AppColors.criticalRed.withValues(alpha: 0.3)
              : Colors.grey.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: isActive
              ? AppColors.criticalRed.withValues(alpha: 0.04)
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: isActive
                        ? AppColors.criticalRed
                        : Colors.grey.shade400,
                    foregroundColor: Colors.white,
                    child: Icon(isActive ? Icons.sos : Icons.check_circle),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isActive ? '🔴 SOS ACTIVE' : 'SOS Alert',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: isActive ? AppColors.criticalRed : null,
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
                          Icon(Icons.circle, color: Colors.white, size: 8),
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
                    Chip(
                      label: Text(
                        statusLabel,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      backgroundColor: statusColor.withValues(alpha: 0.1),
                      side: BorderSide(
                        color: statusColor.withValues(alpha: 0.3),
                      ),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // Reporter
              Text(
                'Reporter: $reporterName',
                style: TextStyle(
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              // Assigned volunteer
              if (assignedVolName.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.person, size: 14, color: Colors.blue),
                    const SizedBox(width: 4),
                    Text(
                      'Assigned to: $assignedVolName',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue,
                      ),
                    ),
                  ],
                ),
              ],
              // Proof indicator
              if (hasProof) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.green.withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.verified, color: Colors.green, size: 16),
                      SizedBox(width: 4),
                      Text(
                        'Proof uploaded by volunteer',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (alert['media_urls'] is List &&
                  (alert['media_urls'] as List).isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('📎 Has media attachments'),
                ),
              const SizedBox(height: 8),
              // Action buttons
              if (widget.user.isCoordinator || widget.user.isVolunteer)
                _buildActionButtons(
                  id,
                  status,
                  isActive,
                  isAcknowledged,
                  isResolved,
                  hasProof,
                  reporterName,
                  destination,
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
                    foregroundColor: Colors.red.withValues(alpha: 0.8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 0,
                    ),
                    minimumSize: const Size(0, 32),
                    side: BorderSide(color: Colors.red.withValues(alpha: 0.3)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons(
    String id,
    String status,
    bool isActive,
    bool isAcknowledged,
    bool isResolved,
    bool hasProof,
    String reporterName,
    _SosDestination? destination,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        if (destination != null)
          OutlinedButton.icon(
            onPressed: () =>
                _showNavigationAppChooser(destination, reporterName),
            icon: const Icon(Icons.navigation, size: 14),
            label: const Text('Navigate', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primaryGreen,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              minimumSize: const Size(0, 32),
              side: BorderSide(
                color: AppColors.primaryGreen.withValues(alpha: 0.4),
              ),
            ),
          ),
        // Acknowledge button
        OutlinedButton(
          onPressed: id.isEmpty || isAcknowledged || isResolved
              ? null
              : () => _updateStatus(id, 'acknowledged'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            minimumSize: const Size(0, 32),
            side: BorderSide(color: Colors.blue.withValues(alpha: 0.5)),
          ),
          child: const Text('Acknowledge', style: TextStyle(fontSize: 12)),
        ),
        // Assign Volunteer button (only for coordinators, when triggered or acknowledged)
        if (widget.user.isCoordinator && !isResolved)
          OutlinedButton.icon(
            onPressed: id.isEmpty ? null : () => _showAssignVolunteerDialog(id),
            icon: const Icon(Icons.person_add, size: 14),
            label: const Text(
              'Assign Volunteer',
              style: TextStyle(fontSize: 12),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.deepPurple,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              minimumSize: const Size(0, 32),
              side: BorderSide(color: Colors.deepPurple.withValues(alpha: 0.4)),
            ),
          ),
        // Resolve button - only enabled when acknowledged AND has proof
        FilledButton.tonal(
          onPressed: id.isEmpty || isResolved || (!isAcknowledged)
              ? null
              : () => _updateStatus(id, 'resolved'),
          style: (isActive || (isAcknowledged && hasProof))
              ? FilledButton.styleFrom(
                  backgroundColor: (isAcknowledged && hasProof)
                      ? AppColors.primaryGreen
                      : AppColors.criticalRed.withValues(alpha: 0.8),
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
          child: Text(
            isAcknowledged && hasProof ? 'Confirm & Resolve' : 'Resolve',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _SosDestination {
  const _SosDestination({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}
