import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../../core/socket_service.dart';
import '../../theme/app_colors.dart';

class NearbySosRadarSheet extends StatefulWidget {
  const NearbySosRadarSheet({super.key, this.onNavigateToLocation});

  final Function(LatLng location)? onNavigateToLocation;

  static void show(BuildContext context, {Function(LatLng location)? onNavigateToLocation}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => NearbySosRadarSheet(onNavigateToLocation: onNavigateToLocation),
    );
  }

  @override
  State<NearbySosRadarSheet> createState() => _NearbySosRadarSheetState();
}

class _NearbySosRadarSheetState extends State<NearbySosRadarSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2, milliseconds: 500),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleScan() {
    setState(() {
      _isScanning = !_isScanning;
      if (_isScanning) {
        _controller.repeat();
      } else {
        _controller.stop();
        _controller.reset();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ValueListenableBuilder<Map<String, Map<String, dynamic>>>(
      valueListenable: SocketService.instance.liveSosAlerts,
      builder: (context, alerts, _) {
        final activeList = alerts.values.toList();
        final bool hasDetected = activeList.isNotEmpty;

        // Active theme color: Green if idle/clear, Red if distress detected
        final Color activeColor = (!_isScanning || !hasDetected)
            ? const Color(0xFF10B981) // Emerald Green
            : const Color(0xFFEF4444); // Critical Red

        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 30,
                spreadRadius: 4,
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Header: Title centered without red logo on top
              Stack(
                alignment: Alignment.center,
                children: [
                  Center(
                    child: Column(
                      children: [
                        Text(
                          'SOS MESH RADAR',
                          style: TextStyle(
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _isScanning
                              ? (hasDetected
                                  ? '🚨 Distress beacons detected nearby!'
                                  : 'Scanning BLE Mesh & P2P channels...')
                              : 'Tap the center circle to start scanning',
                          style: TextStyle(
                            color: isDark ? Colors.white54 : Colors.grey[600],
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    right: 0,
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(
                        Icons.close,
                        color: isDark ? Colors.white60 : Colors.grey[700],
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // ── Interactive Radar Display ──
              SizedBox(
                height: 200,
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Concentric Expanding Radar Waves (When scanning)
                    AnimatedBuilder(
                      animation: _controller,
                      builder: (context, child) {
                        return CustomPaint(
                          size: const Size(200, 200),
                          painter: _RadarWavePainter(
                            progress: _isScanning ? _controller.value : 0.0,
                            color: activeColor,
                            isDark: isDark,
                            isScanning: _isScanning,
                          ),
                        );
                      },
                    ),

                    // Rotating Scanning Beam (Only when scanning)
                    if (_isScanning)
                      AnimatedBuilder(
                        animation: _controller,
                        builder: (context, child) {
                          return Transform.rotate(
                            angle: _controller.value * 2 * math.pi,
                            child: Container(
                              width: 170,
                              height: 170,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: SweepGradient(
                                  center: Alignment.center,
                                  colors: [
                                    Colors.transparent,
                                    activeColor.withValues(alpha: 0.0),
                                    activeColor.withValues(alpha: 0.22),
                                  ],
                                  stops: const [0.0, 0.7, 1.0],
                                ),
                              ),
                            ),
                          );
                        },
                      ),

                    // ── Central Interactive Orb / Circle Button ──
                    GestureDetector(
                      onTap: _toggleScan,
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: (!_isScanning || !hasDetected)
                                ? const [
                                    Color(0xFF34D399),
                                    Color(0xFF10B981),
                                    Color(0xFF065F46),
                                  ]
                                : const [
                                    Color(0xFFFF4D4D),
                                    Color(0xFFDC2626),
                                    Color(0xFF991B1B),
                                  ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: activeColor.withValues(alpha: _isScanning ? 0.5 : 0.3),
                              blurRadius: _isScanning ? 24 : 12,
                              spreadRadius: _isScanning ? 4 : 1,
                            ),
                          ],
                        ),
                        child: Center(
                          child: Icon(
                            _isScanning ? Icons.sensors_rounded : Icons.power_settings_new_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Status Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.grey[100],
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark ? Colors.white12 : Colors.grey[300]!,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: activeColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      !_isScanning
                          ? 'RADAR STANDBY • TAP CENTER ORB TO SCAN'
                          : (hasDetected
                              ? '${activeList.length} ACTIVE DISTRESS SIGNAL${activeList.length > 1 ? 'S' : ''} DETECTED'
                              : 'GRID CLEAR • SCANNING BLE BEACONS'),
                      style: TextStyle(
                        color: activeColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Active Signals List when Detected
              if (_isScanning && hasDetected)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.28,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: activeList.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = activeList[index];
                      final type = (item['type'] ?? 'Emergency').toString();
                      final reporter = (item['reporter_name'] ?? 'Mesh Relay').toString();
                      final isMesh = item['relayed_via_mesh'] == true || item['source'] == 'mesh_ble';

                      final double? lat = item['lat'] != null
                          ? double.tryParse(item['lat'].toString())
                          : (item['location'] is Map && item['location']['coordinates'] is List
                              ? double.tryParse(item['location']['coordinates'][1].toString())
                              : null);
                      final double? lng = item['lng'] != null
                          ? double.tryParse(item['lng'].toString())
                          : (item['location'] is Map && item['location']['coordinates'] is List
                              ? double.tryParse(item['location']['coordinates'][0].toString())
                              : null);

                      return InkWell(
                        onTap: () {
                          if (lat != null && lng != null && widget.onNavigateToLocation != null) {
                            Navigator.pop(context);
                            widget.onNavigateToLocation!(LatLng(lat, lng));
                          }
                        },
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF1E293B) : Colors.grey[50],
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: const Color(0xFFEF4444).withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.warning_amber_rounded,
                                  color: Color(0xFFEF4444),
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      type.toUpperCase(),
                                      style: TextStyle(
                                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Reporter: $reporter',
                                      style: TextStyle(
                                        color: isDark ? Colors.white60 : Colors.grey[600],
                                        fontSize: 11,
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
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isMesh
                                        ? const Color(0xFF3B82F6).withValues(alpha: 0.12)
                                        : const Color(0xFF10B981).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    isMesh ? 'BLE MESH' : 'ONLINE',
                                    style: TextStyle(
                                      color: isMesh ? const Color(0xFF2563EB) : const Color(0xFF059669),
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _isScanning
                        ? 'Continuous background BLE mesh listener active.\nP2P distress signals broadcast without internet.'
                        : 'Tap the green power orb to activate real-time mesh radio frequency scanner.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: isDark ? Colors.white38 : Colors.grey[500],
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RadarWavePainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool isDark;
  final bool isScanning;

  _RadarWavePainter({
    required this.progress,
    required this.color,
    required this.isDark,
    required this.isScanning,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    if (isScanning) {
      // Draw 3 expanding sonar ripple rings
      for (int i = 0; i < 3; i++) {
        final ringProgress = (progress + (i * 0.33)) % 1.0;
        final radius = ringProgress * maxRadius;
        final opacity = (1.0 - ringProgress).clamp(0.0, 1.0);

        final paint = Paint()
          ..color = color.withValues(alpha: opacity * 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;

        canvas.drawCircle(center, radius, paint);
      }
    }

    // Static concentric grid circles
    final gridPaint = Paint()
      ..color = isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.grey.withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawCircle(center, maxRadius * 0.35, gridPaint);
    canvas.drawCircle(center, maxRadius * 0.70, gridPaint);
    canvas.drawCircle(center, maxRadius, gridPaint);

    // Crosshairs
    final crosshairPaint = Paint()
      ..color = isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.grey.withValues(alpha: 0.2)
      ..strokeWidth = 1;

    canvas.drawLine(Offset(center.dx - maxRadius, center.dy), Offset(center.dx + maxRadius, center.dy), crosshairPaint);
    canvas.drawLine(Offset(center.dx, center.dy - maxRadius), Offset(center.dx, center.dy + maxRadius), crosshairPaint);
  }

  @override
  bool shouldRepaint(covariant _RadarWavePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.isScanning != isScanning ||
      oldDelegate.isDark != isDark;
}
