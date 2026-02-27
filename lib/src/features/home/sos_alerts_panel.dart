import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

class SosAlertsPanel {
  static void show({
    required BuildContext context,
    required Map<String, Map<String, dynamic>> alerts,
    String? activeLocalUuid,
    VoidCallback? onCancelSos,
    required VoidCallback onGoToSosPanels,
    void Function(double lat, double lng)? onSosLocationTap,
  }) {
    if (alerts.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.criticalRed.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.emergency_share,
                    color: AppColors.criticalRed,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${alerts.length} Active SOS Alerts',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const Text(
                        'Immediate assistance required',
                        style: TextStyle(
                          color: AppColors.criticalRed,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.4,
              ),
              child: SingleChildScrollView(
                child: Column(
                  children: alerts.values.toList().reversed.map((alert) {
                    final type = (alert['type'] ?? 'Emergency').toString();
                    final reporter = (alert['reporter_name'] ?? 'Unknown')
                        .toString();
                    final timeStr = alert['created_at']?.toString();
                    final time = timeStr != null
                        ? DateTime.tryParse(timeStr) ?? DateTime.now()
                        : DateTime.now();

                    // Extract location from alert data
                    final lat = _extractLat(alert);
                    final lng = _extractLng(alert);
                    final hasLocation = lat != null && lng != null;

                    return GestureDetector(
                      onTap: hasLocation && onSosLocationTap != null
                          ? () {
                              Navigator.pop(context);
                              onSosLocationTap(lat, lng);
                            }
                          : null,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.grey[900]
                              : Colors.grey[50],
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).dividerColor.withValues(alpha: 0.1),
                          ),
                        ),
                        child: Row(
                          children: [
                            const CircleAvatar(
                              backgroundColor: AppColors.criticalRed,
                              radius: 18,
                              child: Icon(
                                Icons.sos,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    type,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                    ),
                                  ),
                                  Text(
                                    'Reported by $reporter',
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '${DateTime.now().difference(time).inMinutes}m ago',
                                  style: const TextStyle(
                                    color: AppColors.criticalRed,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (hasLocation)
                                  const Padding(
                                    padding: EdgeInsets.only(top: 2),
                                    child: Icon(
                                      Icons.navigation,
                                      size: 14,
                                      color: AppColors.primaryGreen,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (activeLocalUuid != null && onCancelSos != null) ...[
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    onCancelSos();
                  },
                  icon: const Icon(Icons.cancel, size: 20),
                  label: const Text(
                    'STOP SOS',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                      fontSize: 14,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.criticalRed,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: const BorderSide(
                        color: AppColors.criticalRed,
                        width: 2,
                      ),
                    ),
                    elevation: 0,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  onGoToSosPanels();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.criticalRed,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                child: const Text(
                  'GO TO SOS PANELS',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Try to extract latitude from alert data
  static double? _extractLat(Map<String, dynamic> alert) {
    // Direct lat field
    final lat = alert['lat'] ?? alert['latitude'];
    if (lat != null) return double.tryParse(lat.toString());

    // From location field
    final loc = alert['location'];
    if (loc is Map) {
      final locLat = loc['lat'] ?? loc['latitude'] ?? loc['y'];
      if (locLat != null) return double.tryParse(locLat.toString());
      // GeoJSON: coordinates [lng, lat]
      if (loc['coordinates'] is List &&
          (loc['coordinates'] as List).length >= 2) {
        return double.tryParse((loc['coordinates'] as List)[1].toString());
      }
    }

    // WKT POINT(lng lat)
    if (loc is String && loc.startsWith('POINT(')) {
      final parts = loc
          .replaceFirst('POINT(', '')
          .replaceFirst(')', '')
          .split(' ');
      if (parts.length == 2) return double.tryParse(parts[1]);
    }

    return null;
  }

  /// Try to extract longitude from alert data
  static double? _extractLng(Map<String, dynamic> alert) {
    final lng = alert['lng'] ?? alert['lon'] ?? alert['longitude'];
    if (lng != null) return double.tryParse(lng.toString());

    final loc = alert['location'];
    if (loc is Map) {
      final locLng = loc['lng'] ?? loc['lon'] ?? loc['longitude'] ?? loc['x'];
      if (locLng != null) return double.tryParse(locLng.toString());
      if (loc['coordinates'] is List &&
          (loc['coordinates'] as List).length >= 2) {
        return double.tryParse((loc['coordinates'] as List)[0].toString());
      }
    }

    if (loc is String && loc.startsWith('POINT(')) {
      final parts = loc
          .replaceFirst('POINT(', '')
          .replaceFirst(')', '')
          .split(' ');
      if (parts.length == 2) return double.tryParse(parts[0]);
    }

    return null;
  }
}
