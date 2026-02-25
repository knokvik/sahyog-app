import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/socket_service.dart';
import '../../core/sos_sync_engine.dart';
import '../../core/database_helper.dart';
import '../../core/sos_state_machine.dart';
import '../../core/models.dart';
import '../../core/location_service.dart';
import '../../theme/app_colors.dart';

class GlobalSosIndicator extends StatefulWidget {
  const GlobalSosIndicator({
    super.key,
    required this.onTap,
    required this.user,
  });

  final VoidCallback onTap;
  final AppUser user;

  @override
  State<GlobalSosIndicator> createState() => _GlobalSosIndicatorState();
}

class _GlobalSosIndicatorState extends State<GlobalSosIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.4,
    ).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeOut));

    _fadeAnimation = Tween<double>(
      begin: 0.6,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeOut));
  }

  // ── SOS Triggering Logic ──
  int _sosHoldTicks = 0;
  Timer? _sosHoldTimer;
  bool _sosFired = false;
  final LocationService _locationService = LocationService();

  Future<void> _triggerSOS() async {
    final db = DatabaseHelper.instance;

    // Prevent double-trigger: check if already active
    final existing = await db.getActiveIncident(widget.user.id);
    if (existing != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('SOS Aleady Active!'),
            backgroundColor: AppColors.warningAmber,
          ),
        );
      }
      return;
    }

    // 1. Fetch location (12s timeout)
    double? lat, lng;
    try {
      final pos = await _locationService.getCurrentPosition().timeout(
        const Duration(seconds: 12),
      );
      lat = pos.latitude;
      lng = pos.longitude;
    } catch (_) {}

    // 2. Create SOS incident
    final incident = SosIncident(
      reporterId: widget.user.id,
      lat: lat,
      lng: lng,
      type: 'Emergency',
      status: SosStatus.activating,
    );

    // 3. Save to SQLite -> transition offline
    await db.insertSosIncident(incident);
    await db.atomicUpdateIncident(
      incident.uuid,
      status: SosStatus.activeOffline,
    );

    // 4. Force a network sync
    SosSyncEngine.instance.syncAll();

    if (mounted) {
      // Navigate to the SOS Home tab
      widget.onTap();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SOS Requested! Navigating to SOS Panel...'),
          backgroundColor: AppColors.criticalRed,
        ),
      );
    }
  }

  void _cancelHold() {
    _sosHoldTimer?.cancel();
    if (mounted) {
      setState(() {
        _sosHoldTicks = 0;
      });
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _sosHoldTimer?.cancel();
    super.dispose();
  }

  void _handleTap(
    BuildContext context,
    Map<String, Map<String, dynamic>> alerts,
  ) {
    if (alerts.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
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
                    color: AppColors.criticalRed.withOpacity(0.1),
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

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey[200]!),
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
                          Text(
                            '${DateTime.now().difference(time).inMinutes}m ago',
                            style: const TextStyle(
                              color: AppColors.criticalRed,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onTap();
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

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, Map<String, dynamic>>>(
      valueListenable: SocketService.instance.liveSosAlerts,
      builder: (context, alerts, _) {
        final count = alerts.length;
        final double progress = (_sosHoldTicks / 50.0).clamp(0.0, 1.0);

        return GestureDetector(
          onTap: () {
            if (count > 0) {
              _handleTap(context, alerts);
            } else {
              widget.onTap();
            }
          },
          onTapDown: (_) {
            if (_sosFired) return;
            _sosHoldTicks = 0;
            _sosHoldTimer = Timer.periodic(const Duration(milliseconds: 100), (
              timer,
            ) {
              if (!mounted) return;
              setState(() {
                _sosHoldTicks++;
                if (_sosHoldTicks >= 50) {
                  _sosHoldTimer?.cancel();
                  _sosFired = true;
                  _triggerSOS();
                }
              });
            });
          },
          onTapUp: (_) => _cancelHold(),
          onTapCancel: () => _cancelHold(),
          child: SizedBox(
            width: 70,
            height: 70,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Pulse waves (only when alerts exist)
                if (count > 0)
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      return Container(
                        width: 50 * _scaleAnimation.value,
                        height: 50 * _scaleAnimation.value,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.criticalRed.withOpacity(
                            _fadeAnimation.value,
                          ),
                        ),
                      );
                    },
                  ),
                // Progress Fill for HOLD Action
                if (_sosHoldTicks > 0)
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 4,
                      color: AppColors.primaryGreen,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                // Main Button
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.criticalRed,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.criticalRed.withOpacity(0.4),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.sos, color: Colors.white, size: 24),
                      Text(
                        count > 0 ? '$count' : 'SOS',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: count > 0 ? 11 : 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
