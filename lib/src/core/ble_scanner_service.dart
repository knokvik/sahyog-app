import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:uuid/uuid.dart';
import 'api_client.dart';
import 'ble_payload_codec.dart';
import 'ble_advertiser_service.dart';
import 'database_helper.dart';
import 'sos_state_machine.dart';

/// Volunteer-side BLE Scanner Service.
///
/// Listens for Sahyog SOS beacons from nearby victim devices.
/// When a beacon is detected:
///   1. Decode and validate payload
///   2. Check for duplicates (UUID hash dedup in SQLite)
///   3. Save relay record if new
///   4. Attempt immediate RPC if internet available
///   5. Fall back to SyncEngine if RPC fails
///
/// Also handles:
///   - ACK beacon transmission (volunteer taps "Respond")
///   - Cancel beacon detection (mark relay as cancelled)
///   - RSSI-based distance estimation
class BleScannerService {
  static final BleScannerService instance = BleScannerService._internal();
  BleScannerService._internal();

  /// Whether the scanner is currently active
  bool _isScanning = false;

  /// API client for immediate relay RPC
  ApiClient? _api;

  /// Current user ID (reporter_id for relay records)
  String? _currentUserId;

  /// Stream subscription for scan results
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  /// Notifies listeners when a new SOS beacon is detected
  /// Value is the decoded BleBeacon
  final ValueNotifier<BleBeacon?> beaconDetectedNotifier = ValueNotifier(null);

  /// Notifies listeners with distance estimation updates
  /// Value is a map of {uuidHash: distanceLabel}
  final ValueNotifier<Map<int, String>> distanceNotifier = ValueNotifier({});

  /// Set of UUID hashes we've already processed (in-memory dedup)
  final Set<int> _processedHashes = {};

  bool get isScanning => _isScanning;

  /// Initialize with API client and user ID.
  void initialize(ApiClient api, String userId) {
    _api = api;
    _currentUserId = userId;
  }

  /// Start scanning for Sahyog BLE beacons.
  Future<void> startScanning() async {
    if (_isScanning) {
      SosLog.warn('BLE_SCANNER', 'Already scanning — skipping start');
      return;
    }

    try {
      // Check BLE availability
      if (await FlutterBluePlus.adapterState.first !=
          BluetoothAdapterState.on) {
        SosLog.warn('BLE_SCANNER', 'Bluetooth adapter is off');
        return;
      }

      _isScanning = true;

      // Listen to scan results
      _scanSubscription = FlutterBluePlus.onScanResults.listen(_onScanResults);

      // Start scanning — no service UUID filter, we use manufacturer data
      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 30),
      );

      SosLog.warn(
        'BLE_SCANNER',
        'Scan started — listening for Sahyog beacons (0x5348)',
      );

      // Periodic status log for debugging
      _startStatusTimer();
    } catch (e) {
      _isScanning = false;
      SosLog.warn('BLE_SCANNER', 'Failed to start scanning: $e');
    }
  }

  /// Stop scanning.
  Future<void> stopScanning() async {
    if (!_isScanning) return;

    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    _statusTimer?.cancel();
    _statusTimer = null;
    _scanSubscription?.cancel();
    _scanSubscription = null;
    _isScanning = false;
    _processedHashes.clear();

    SosLog.warn('BLE_SCANNER', 'Scan stopped');
  }

  Timer? _statusTimer;
  void _startStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (_isScanning) {
        SosLog.warn('BLE_SCANNER', 'Still scanning... current status: OK');
      } else {
        timer.cancel();
      }
    });
  }

  /// Process scan results — filter for Sahyog beacons.
  void _onScanResults(List<ScanResult> results) {
    for (final result in results) {
      _processResult(result);
    }
  }

  /// Process a single scan result.
  void _processResult(ScanResult result) {
    // Extract manufacturer data for Sahyog ID
    final mfgDataMap = result.advertisementData.manufacturerData;
    if (mfgDataMap.isEmpty) return;

    // Check if manufacturer ID matches Sahyog (0x5348)
    final dynamic rawData = mfgDataMap[kSahyogManufacturerId];
    if (rawData == null) return;

    // Decode payload
    final Uint8List sahyogData = Uint8List.fromList(List<int>.from(rawData));
    final beacon = BlePayloadCodec.decode(sahyogData);
    if (beacon == null) {
      SosLog.warn(
        'BLE_SCANNER',
        'Invalid payload from ${result.device.remoteId}',
      );
      return;
    }

    // RSSI-based distance estimation
    final distanceLabel = _estimateDistance(result.rssi);
    final hashStr = '0x${beacon.uuidHash.toRadixString(16)}';

    SosLog.event(
      hashStr,
      'BEACON_DETECTED',
      'rssi=${result.rssi}, distance=$distanceLabel, flag=0x${beacon.flag.toRadixString(16)}',
    );

    // Update distance notifier
    final distances = Map<int, String>.from(distanceNotifier.value);
    distances[beacon.uuidHash] = distanceLabel;
    distanceNotifier.value = distances;

    // Route by flag type
    if (beacon.isSos) {
      _handleSosBeacon(beacon, result.rssi);
    } else if (beacon.isCancel) {
      _handleCancelBeacon(beacon);
    } else if (beacon.isAck) {
      _handleAckBeacon(beacon);
    }
  }

  /// Handle a new SOS beacon — dedup, save, notify, relay.
  Future<void> _handleSosBeacon(BleBeacon beacon, int rssi) async {
    final hashStr = '0x${beacon.uuidHash.toRadixString(16)}';

    // In-memory dedup (fast path)
    if (_processedHashes.contains(beacon.uuidHash)) return;

    // SQLite dedup (persistent path)
    final db = DatabaseHelper.instance;
    final existing = await db.getRelayByUuidHash(beacon.uuidHash);
    if (existing != null) {
      SosLog.event(hashStr, 'RELAY_DEDUP', 'already exists in SQLite');
      _processedHashes.add(beacon.uuidHash);
      return;
    }

    SosLog.event(
      hashStr,
      'PAYLOAD_DECODED',
      'flag=SOS, lat=${beacon.lat}, lng=${beacon.lng}, type=${beacon.incidentTypeString}',
    );

    // Generate a relay UUID (different from victim's UUID, but shares hash)
    final relayUuid = const Uuid().v4();

    // Create relay record
    final relay = SosIncident(
      uuid: relayUuid,
      reporterId: _currentUserId ?? 'unknown_relay',
      lat: beacon.lat,
      lng: beacon.lng,
      type: beacon.incidentTypeString,
      status: SosStatus.activeOffline,
      source: 'mesh_relay',
      hopCount: 1,
      uuidHash: beacon.uuidHash,
    );

    // Save to SQLite
    await db.saveMeshRelay(relay);
    _processedHashes.add(beacon.uuidHash);

    SosLog.event(
      hashStr,
      'RELAY_SAVED',
      'source=mesh_relay, hop=1, relayUuid=$relayUuid',
    );

    // Notify UI
    beaconDetectedNotifier.value = beacon;

    // Attempt immediate RPC if API is available
    if (_api != null) {
      _attemptImmediateRelay(relay, hashStr);
    }
  }

  /// Attempt immediate RPC call for the relay.
  /// If it fails, the SyncEngine will pick it up later.
  Future<void> _attemptImmediateRelay(SosIncident relay, String hashStr) async {
    try {
      final body = <String, dynamic>{
        'type': relay.type,
        'lat': relay.lat,
        'lng': relay.lng,
        'client_uuid': 'relay_${relay.uuidHash}',
        'source': 'mesh_relay',
        'hop_count': relay.hopCount,
      };

      if (relay.description != null) {
        body['description'] = relay.description;
      }

      final res = await _api!.post('/api/v1/sos', body: body);

      if (res is Map<String, dynamic> && res['id'] != null) {
        final backendId = res['id'].toString();

        await DatabaseHelper.instance.atomicUpdateIncident(
          relay.uuid,
          status: SosStatus.activeOnline,
          isSynced: true,
          backendId: backendId,
          deliveryChannel: 'mesh_relay',
        );

        SosLog.event(
          hashStr,
          'RELAY_RPC',
          'attempt=1, result=success, backendId=$backendId',
        );
      }
    } catch (e) {
      SosLog.event(
        hashStr,
        'RELAY_RPC',
        'attempt=1, result=failed, error=$e — SyncEngine will retry',
      );
      // SyncEngine will pick this up via getSyncableRelays()
    }
  }

  /// Handle a cancel beacon — mark matching relay as cancelled.
  Future<void> _handleCancelBeacon(BleBeacon beacon) async {
    final hashStr = '0x${beacon.uuidHash.toRadixString(16)}';

    final db = DatabaseHelper.instance;
    final existing = await db.getRelayByUuidHash(beacon.uuidHash);

    if (existing != null && existing.status.isActive) {
      await db.atomicUpdateIncident(existing.uuid, status: SosStatus.cancelled);
      SosLog.event(hashStr, 'CANCEL_RECEIVED', 'relay marked as cancelled');
    }
  }

  /// Handle an ACK beacon — this is only relevant for victim devices.
  /// If we detect an ACK matching our active SOS, notify the UI.
  void _handleAckBeacon(BleBeacon beacon) {
    final hashStr = '0x${beacon.uuidHash.toRadixString(16)}';
    SosLog.event(hashStr, 'ACK_DETECTED', 'from volunteer device');
    // The victim's advertiser listens for this via its own callback
    // For scanner, we just log it
  }

  /// RSSI-based approximate distance estimation.
  String _estimateDistance(int rssi) {
    if (rssi > -50) return 'Very Close (~2m)';
    if (rssi > -70) return 'Nearby (~2-10m)';
    if (rssi > -85) return 'In Range (~10-30m)';
    return 'Far (>30m)';
  }

  /// Send an ACK beacon for a specific SOS UUID hash.
  ///
  /// Called when a volunteer taps "Respond" on a relayed SOS.
  /// This advertises an ACK flag so the victim device knows help is coming.
  Future<void> sendAckBeacon(int uuidHash) async {
    try {
      await BleAdvertiserService.instance.startAckAdvertising(uuidHash);

      SosLog.event(
        '0x${uuidHash.toRadixString(16)}',
        'ACK_BEACON_REQUEST',
        'Relay responder help is on the way',
      );
    } catch (e) {
      SosLog.warn('BLE_SCANNER', 'Failed to send ACK beacon: $e');
    }
  }

  /// Clean up resources.
  void dispose() {
    stopScanning();
    beaconDetectedNotifier.dispose();
    distanceNotifier.dispose();
  }
}
