import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

/// Battery-aware power management service.
///
/// Monitors battery level and switches the app between normal and
/// low-power modes to preserve battery during field operations.
///
/// Low Power Mode (triggers at ≤ 20%):
///   • GPS tracking interval increases from 10s → 5 minutes.
///   • Mesh broadcasting is paused.
///   • Polling intervals are doubled.
///
/// Critical Power Mode (triggers at ≤ 10%):
///   • GPS tracking stops entirely.
///   • Only essential SOS functionality remains active.
class BatteryAdaptiveService {
  static final BatteryAdaptiveService instance = BatteryAdaptiveService._();
  BatteryAdaptiveService._();

  final Battery _battery = Battery();
  StreamSubscription? _batterySub;
  Timer? _checkTimer;

  /// Current battery percentage (updated periodically).
  final ValueNotifier<int> batteryLevel = ValueNotifier(100);

  /// Current power mode.
  final ValueNotifier<PowerMode> powerMode = ValueNotifier(PowerMode.normal);

  /// Thresholds
  static const int lowBatteryThreshold = 20;
  static const int criticalBatteryThreshold = 10;

  /// GPS intervals per mode (in seconds)
  static const Map<PowerMode, int> gpsIntervals = {
    PowerMode.normal: 10,
    PowerMode.low: 300, // 5 minutes
    PowerMode.critical: 0, // disabled
  };

  /// Polling multiplier per mode
  static const Map<PowerMode, double> pollingMultiplier = {
    PowerMode.normal: 1.0,
    PowerMode.low: 2.0, // double the polling intervals
    PowerMode.critical: 4.0, // quadruple
  };

  /// Initialize the service. Call once at app startup.
  Future<void> init() async {
    // Get initial level
    try {
      batteryLevel.value = await _battery.batteryLevel;
    } catch (_) {
      batteryLevel.value = 100; // assume full if we can't read
    }
    _updatePowerMode();

    // Listen for battery state changes (charging/discharging)
    _batterySub = _battery.onBatteryStateChanged.listen((_) async {
      try {
        batteryLevel.value = await _battery.batteryLevel;
      } catch (_) {}
      _updatePowerMode();
    });

    // Also poll every 2 minutes as a safety net
    _checkTimer = Timer.periodic(const Duration(minutes: 2), (_) async {
      try {
        batteryLevel.value = await _battery.batteryLevel;
      } catch (_) {}
      _updatePowerMode();
    });
  }

  void _updatePowerMode() {
    final level = batteryLevel.value;
    final oldMode = powerMode.value;
    PowerMode newMode;

    if (level <= criticalBatteryThreshold) {
      newMode = PowerMode.critical;
    } else if (level <= lowBatteryThreshold) {
      newMode = PowerMode.low;
    } else {
      newMode = PowerMode.normal;
    }

    if (newMode != oldMode) {
      powerMode.value = newMode;
      debugPrint(
        '[BatteryAdaptive] Mode changed: ${oldMode.name} → ${newMode.name} '
        '(battery: $level%)',
      );
    }
  }

  /// Get the recommended GPS tracking interval in seconds.
  /// Returns 0 if GPS should be disabled.
  int get gpsInterval => gpsIntervals[powerMode.value] ?? 10;

  /// Get the recommended polling multiplier.
  double get pollMultiplier => pollingMultiplier[powerMode.value] ?? 1.0;

  /// Whether mesh broadcasting should be active.
  bool get isMeshEnabled => powerMode.value == PowerMode.normal;

  /// Whether the app should minimize all non-essential background work.
  bool get isCritical => powerMode.value == PowerMode.critical;

  void dispose() {
    _batterySub?.cancel();
    _checkTimer?.cancel();
  }
}

enum PowerMode { normal, low, critical }
