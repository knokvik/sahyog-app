import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../../theme/app_colors.dart';

class SosAlertsPanel {
  static void show({
    required BuildContext context,
    required Map<String, Map<String, dynamic>> alerts,
    String? activeLocalUuid,
    VoidCallback? onCancelSos,
    required VoidCallback onGoToSosPanels,
    Function(LatLng location)? onNavigateToLocation,
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
                        '${alerts.length} Active SOS Alert${alerts.length > 1 ? 's' : ''}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const Text(
                        'Tap an alert to locate and navigate on map',
                        style: TextStyle(
                          color: AppColors.criticalRed,
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
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

                    final double? lat = alert['lat'] != null
                        ? double.tryParse(alert['lat'].toString())
                        : (alert['location'] is Map && alert['location']['coordinates'] is List
                            ? double.tryParse(alert['location']['coordinates'][1].toString())
                            : null);
                    final double? lng = alert['lng'] != null
                        ? double.tryParse(alert['lng'].toString())
                        : (alert['location'] is Map && alert['location']['coordinates'] is List
                            ? double.tryParse(alert['location']['coordinates'][0].toString())
                            : null);

                    return InkWell(
                      onTap: () {
                        Navigator.pop(context);
                        if (lat != null && lng != null && onNavigateToLocation != null) {
                          onNavigateToLocation(LatLng(lat, lng));
                        } else {
                          onGoToSosPanels();
                        }
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.grey[900]
                              : Colors.grey[50],
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).dividerColor.withValues(alpha: 0.1),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.grey.withValues(alpha: 0.12),
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.emergency_rounded,
                                color: AppColors.criticalRed,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    type,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Reported by $reporter',
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 12,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (lat != null && lng != null)
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryGreen.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.near_me_rounded,
                                  color: AppColors.primaryGreen,
                                  size: 16,
                                ),
                              )
                            else
                              Text(
                                '${DateTime.now().difference(time).inMinutes}m ago',
                                style: const TextStyle(
                                  color: AppColors.criticalRed,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
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
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    onCancelSos();
                  },
                  icon: const Icon(Icons.cancel, size: 18),
                  label: const Text(
                    'Stop SOS',
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.criticalRed,
                    side: BorderSide(
                      color: AppColors.criticalRed.withValues(alpha: 0.8),
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.pop(context);
                  onGoToSosPanels();
                },
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.criticalRed,
                  side: BorderSide(
                    color: AppColors.criticalRed.withValues(alpha: 0.7),
                    width: 1.4,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                child: const Text(
                  'Go to SOS Panels',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
