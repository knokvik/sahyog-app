import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_payload_codec.dart';
import 'database_helper.dart';
import 'sos_state_machine.dart';
import 'sos_sync_engine.dart';

class MeshRelayService {
  MeshRelayService._();
  static final MeshRelayService instance = MeshRelayService._();

  static const String _serviceId = 'com.example.sahyog_app';
  static const Strategy _strategy = Strategy.P2P_CLUSTER;

  static const String _meshReporterId = 'mesh_relay';
  static const int _maxHopCount = 3;

  final Set<String> _connectedEndpoints = <String>{};
  final Set<String> _seenUuids = <String>{};

  Timer? _broadcastTimer;
  bool _running = false;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  Future<void> start() async {
    if (!Platform.isAndroid) return;
    if (_running) return;
    _running = true;

    await _initNotifications();
    await _ensureNearbyPermissions();

    final prefs = await SharedPreferences.getInstance();
    final userName = prefs.getString('mesh_device_name') ?? 'Sahyog Relay';

    try {
      await Nearby().startAdvertising(
        userName,
        _strategy,
        serviceId: _serviceId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );

      await Nearby().startDiscovery(
        userName,
        _strategy,
        serviceId: _serviceId,
        onEndpointFound: _onEndpointFound,
        onEndpointLost: (id) => _onEndpointLost(id),
      );
    } catch (e) {
      SosLog.warn('MESH', 'Failed to start Nearby: $e');
    }

    // Periodically try to broadcast any active offline SOS as a mesh packet.
    _broadcastTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      await _broadcastActiveOfflineIfAny();
    });
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (!_running) return;
    _running = false;

    _broadcastTimer?.cancel();
    _broadcastTimer = null;

    try {
      Nearby().stopAdvertising();
      Nearby().stopDiscovery();
      for (final id in _connectedEndpoints.toList()) {
        Nearby().disconnectFromEndpoint(id);
      }
    } catch (_) {}
    _connectedEndpoints.clear();
  }

  Future<void> _broadcastActiveOfflineIfAny() async {
    try {
      final db = DatabaseHelper.instance;
      // Any active_offline incident (direct) should be broadcast if not synced.
      final incidents = await db.getSyncableIncidents(SosSyncEngine.maxRetries);
      if (incidents.isEmpty) return;

      // Prefer direct incidents; if not, still broadcast the earliest one.
      final SosIncident incident = incidents.firstWhere(
        (i) => i.source == 'direct',
        orElse: () => incidents.first,
      );

      if (incident.hopCount > _maxHopCount) return;

      // Only broadcast when we have at least one connected endpoint; otherwise
      // discovery/advertising will connect naturally.
      if (_connectedEndpoints.isEmpty) return;

      final packet = MeshSosPacket(
        uuid: incident.uuid,
        type: incident.type,
        description: incident.description,
        lat: incident.lat,
        lng: incident.lng,
        hopCount: incident.hopCount,
        createdAt: incident.createdAt,
      );

      final bytes = utf8.encode(jsonEncode(packet.toJson()));
      for (final endpointId in _connectedEndpoints) {
        try {
          await Nearby().sendBytesPayload(endpointId, bytes);
        } catch (_) {}
      }
    } catch (e) {
      SosLog.warn('MESH_BROADCAST', '$e');
    }
  }

  void _onEndpointFound(String id, String name, String serviceId) {
    // Actively request connection to found endpoints.
    try {
      Nearby().requestConnection(
        'Sahyog',
        id,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (_) {}
  }

  void _onEndpointLost(String? id) {
    if (id != null) {
      _connectedEndpoints.remove(id);
    }
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) {
    // Auto-accept so SOS relay works hands-free.
    try {
      Nearby().acceptConnection(
        id,
        onPayLoadRecieved: (endpointId, payload) async {
          if (payload.type != PayloadType.BYTES) return;
          final data = payload.bytes;
          if (data == null) return;
          await _handleIncomingBytes(endpointId, data);
        },
        onPayloadTransferUpdate: (endpointId, update) {},
      );
    } catch (e) {
      SosLog.warn('MESH_ACCEPT', '$e');
    }
  }

  void _onConnectionResult(String id, Status status) {
    if (status == Status.CONNECTED) {
      _connectedEndpoints.add(id);
    } else {
      _connectedEndpoints.remove(id);
    }
  }

  void _onDisconnected(String? id) {
    if (id != null) {
      _connectedEndpoints.remove(id);
    }
  }

  Future<void> _handleIncomingBytes(String endpointId, List<int> bytes) async {
    try {
      final str = utf8.decode(bytes);
      final json = jsonDecode(str);
      if (json is! Map<String, dynamic>) return;

      final pkt = MeshSosPacket.fromJson(json);
      if (pkt.uuid.isEmpty) return;

      // Deduplicate quickly in-memory
      if (_seenUuids.contains(pkt.uuid)) return;
      _seenUuids.add(pkt.uuid);

      if (pkt.hopCount >= _maxHopCount) return;

      final db = DatabaseHelper.instance;
      final existing = await db.getIncidentByUuid(pkt.uuid);
      if (existing != null) {
        return;
      }

      final relayIncident = SosIncident(
        uuid: pkt.uuid,
        reporterId: _meshReporterId,
        lat: pkt.lat,
        lng: pkt.lng,
        type: pkt.type,
        description: pkt.description ?? 'Relayed via mesh (Nearby)',
        status: SosStatus.activating,
        source: 'mesh_relay',
        hopCount: pkt.hopCount + 1,
        uuidHash: fnv1a32(pkt.uuid),
        deliveryChannel: 'mesh',
      );

      await db.insertSosIncident(relayIncident);
      await db.atomicUpdateIncident(
        relayIncident.uuid,
        status: SosStatus.activeOffline,
      );

      await _showIncomingNotification(pkt);

      // Trigger the existing retrying sync engine (keeps current behaviour).
      await SosSyncEngine.instance.syncAll();

      // Re-broadcast for multi-hop reach.
      final rebroadcast = MeshSosPacket(
        uuid: pkt.uuid,
        type: pkt.type,
        description: pkt.description,
        lat: pkt.lat,
        lng: pkt.lng,
        hopCount: pkt.hopCount + 1,
        createdAt: pkt.createdAt,
      );
      final outBytes = utf8.encode(jsonEncode(rebroadcast.toJson()));
      for (final id in _connectedEndpoints) {
        if (id == endpointId) continue;
        try {
          await Nearby().sendBytesPayload(id, outBytes);
        } catch (_) {}
      }
    } catch (e) {
      SosLog.warn('MESH_RX', '$e');
    }
  }

  Future<void> _initNotifications() async {
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const settings = InitializationSettings(android: android);
      await _notifications.initialize(settings);
    } catch (_) {}
  }

  Future<void> _showIncomingNotification(MeshSosPacket pkt) async {
    try {
      const androidDetails = AndroidNotificationDetails(
        'mesh_sos_channel',
        'Mesh SOS',
        channelDescription: 'Nearby SOS relays received via Bluetooth/Wi‑Fi',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
      );
      const details = NotificationDetails(android: androidDetails);

      await _notifications.show(
        fnv1a32(pkt.uuid).abs() % 100000,
        'Nearby SOS detected',
        '${pkt.type}${pkt.description != null ? " — ${pkt.description}" : ""}. Tap to open Sahyog.',
        details,
      );
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('MESH: notification failed: $e');
      }
    }
  }

  Future<void> _ensureNearbyPermissions() async {
    // Nearby requires a mix of Bluetooth and Location permissions depending on Android version.
    final perms = <Permission>[
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.nearbyWifiDevices,
      Permission.notification,
    ];
    await perms.request();
  }
}
