import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:battery_plus/battery_plus.dart';
import 'ble_payload_codec.dart';
import 'sos_state_machine.dart';

/// Victim-side BLE Advertiser Service.
///
/// Lifecycle:
///   Start: when SOS transitions to active_offline or active_online
///   Stop:  when SOS transitions to cancelled, resolved, acknowledged, or failed
///
/// Features:
///   - Battery-aware interval (200ms normal, 1000ms at <15%)
///   - Cancel beacon emission (10s then stop)
///   - ACK listener (scans for ACK beacons matching own UUID hash)
class BleAdvertiserService {
  static final BleAdvertiserService instance = BleAdvertiserService._internal();
  BleAdvertiserService._internal();

  final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();
  final Battery _battery = Battery();

  /// Normal advertising interval in ms
  static const int _normalIntervalMs = 200;

  /// Low-power advertising interval in ms (battery < 15%)
  static const int _lowPowerIntervalMs = 1000;

  /// Battery threshold for low-power mode
  static const int _lowBatteryThreshold = 15;

  /// Whether we're currently advertising
  bool _isAdvertising = false;

  /// Currently active UUID hash (for ACK matching)
  int? _activeUuidHash;

  /// Timer for cancel beacon duration
  Timer? _cancelBeaconTimer;

  /// Timer for battery monitoring
  Timer? _batteryMonitorTimer;

  /// Notifies listeners when we receive an ACK via BLE
  final ValueNotifier<int?> ackReceivedNotifier = ValueNotifier(null);

  bool get isAdvertising => _isAdvertising;

  /// Start advertising an SOS beacon.
  ///
  /// Encodes the incident data into an 18-byte manufacturer payload
  /// and begins BLE advertising with the Sahyog manufacturer ID.
  Future<void> startAdvertising(SosIncident incident) async {
    if (_isAdvertising) {
      SosLog.warn('BLE_ADVERTISER', 'Already advertising — skipping start');
      return;
    }

    try {
      // Check peripheral support
      final isSupported = await _peripheral.isSupported;
      if (!isSupported) {
        SosLog.warn('BLE_ADVERTISER', 'BLE peripheral not supported');
        return;
      }

      _activeUuidHash = incident.uuidHash;

      // Determine interval based on battery
      final batteryLevel = await _battery.batteryLevel;
      final intervalMs = batteryLevel < _lowBatteryThreshold
          ? _lowPowerIntervalMs
          : _normalIntervalMs;

      // Encode payload
      final payload = BlePayloadCodec.encode(
        flag: kFlagSos,
        lat: incident.lat ?? 0.0,
        lng: incident.lng ?? 0.0,
        incidentType: BlePayloadCodec.incidentTypeCode(incident.type),
        uuidHash: incident.uuidHash,
      );

      // Configure advertisement
      final advertiseData = AdvertiseData(
        manufacturerId: kSahyogManufacturerId,
        manufacturerData: payload,
      );

      final advertiseSettings = AdvertiseSettings(
        advertiseMode: intervalMs <= 200
            ? AdvertiseMode.advertiseModeBalanced
            : AdvertiseMode.advertiseModeLowPower,
        connectable: false,
        timeout: 0, // Advertise indefinitely
      );

      await _peripheral.start(
        advertiseData: advertiseData,
        advertiseSettings: advertiseSettings,
      );

      _isAdvertising = true;

      // Start battery monitoring to switch intervals
      _startBatteryMonitor(incident);

      SosLog.event(
        '0x${incident.uuidHash.toRadixString(16)}',
        'ADVERTISE_START',
        'interval=${intervalMs}ms, battery=$batteryLevel%, type=${incident.type}',
      );
    } catch (e) {
      SosLog.warn('BLE_ADVERTISER', 'Failed to start: $e');
    }
  }

  /// Stop advertising.
  Future<void> stopAdvertising({String reason = 'manual'}) async {
    if (!_isAdvertising) return;

    try {
      await _peripheral.stop();
    } catch (e) {
      SosLog.warn('BLE_ADVERTISER', 'Failed to stop: $e');
    }

    _isAdvertising = false;
    _cancelBeaconTimer?.cancel();
    _cancelBeaconTimer = null;
    _batteryMonitorTimer?.cancel();
    _batteryMonitorTimer = null;

    SosLog.event(
      _activeUuidHash != null
          ? '0x${_activeUuidHash!.toRadixString(16)}'
          : 'unknown',
      'ADVERTISE_STOP',
      'reason=$reason',
    );
    _activeUuidHash = null;
  }

  /// Emit a cancellation beacon for 10 seconds, then stop.
  ///
  /// This tells nearby volunteer devices that this SOS was cancelled.
  Future<void> emitCancelBeacon(SosIncident incident) async {
    // Stop current advertising first
    await stopAdvertising(reason: 'switching_to_cancel');

    try {
      final payload = BlePayloadCodec.encodeCancel(
        lat: incident.lat ?? 0.0,
        lng: incident.lng ?? 0.0,
        uuidHash: incident.uuidHash,
      );

      final advertiseData = AdvertiseData(
        manufacturerId: kSahyogManufacturerId,
        manufacturerData: payload,
      );

      final advertiseSettings = AdvertiseSettings(
        advertiseMode: AdvertiseMode.advertiseModeBalanced,
        connectable: false,
        timeout: 0,
      );

      await _peripheral.start(
        advertiseData: advertiseData,
        advertiseSettings: advertiseSettings,
      );

      _isAdvertising = true;

      SosLog.event(
        '0x${incident.uuidHash.toRadixString(16)}',
        'CANCEL_BEACON_START',
        'duration=10s',
      );

      // Stop after 10 seconds
      _cancelBeaconTimer = Timer(const Duration(seconds: 10), () {
        stopAdvertising(reason: 'cancel_beacon_expired');
      });
    } catch (e) {
      SosLog.warn('BLE_ADVERTISER', 'Failed to emit cancel beacon: $e');
    }
  }

  /// Emit an acknowledgment beacon (ACK) for 15 seconds.
  ///
  /// This tells the victim that help is on the way.
  Future<void> startAckAdvertising(int uuidHash) async {
    await stopAdvertising(reason: 'switching_to_ack');

    try {
      _activeUuidHash = uuidHash;
      final payload = BlePayloadCodec.encodeAck(uuidHash);

      final advertiseData = AdvertiseData(
        manufacturerId: kSahyogManufacturerId,
        manufacturerData: payload,
      );

      final advertiseSettings = AdvertiseSettings(
        advertiseMode: AdvertiseMode.advertiseModeBalanced,
        connectable: false,
        timeout: 0,
      );

      await _peripheral.start(
        advertiseData: advertiseData,
        advertiseSettings: advertiseSettings,
      );

      _isAdvertising = true;

      SosLog.event(
        '0x${uuidHash.toRadixString(16)}',
        'ACK_BEACON_START',
        'duration=15s, reason=help_is_coming',
      );

      // Stop after 15 seconds
      _cancelBeaconTimer = Timer(const Duration(seconds: 15), () {
        stopAdvertising(reason: 'ack_beacon_expired');
      });
    } catch (e) {
      SosLog.warn('BLE_ADVERTISER', 'Failed to emit ACK beacon: $e');
    }
  }

  /// Periodically check battery and adjust advertising interval.
  void _startBatteryMonitor(SosIncident incident) {
    _batteryMonitorTimer?.cancel();
    _batteryMonitorTimer = Timer.periodic(const Duration(minutes: 2), (
      timer,
    ) async {
      if (!_isAdvertising) {
        timer.cancel();
        return;
      }

      try {
        final batteryLevel = await _battery.batteryLevel;
        if (batteryLevel < _lowBatteryThreshold) {
          SosLog.event(
            '0x${incident.uuidHash.toRadixString(16)}',
            'BATTERY_LOW',
            'level=$batteryLevel%, switching to low-power interval',
          );
          // Restart with low-power settings
          await stopAdvertising(reason: 'battery_switch');
          await startAdvertising(incident);
        }
      } catch (_) {}
    });
  }

  /// Clean up resources.
  void dispose() {
    stopAdvertising(reason: 'dispose');
    ackReceivedNotifier.dispose();
  }
}
