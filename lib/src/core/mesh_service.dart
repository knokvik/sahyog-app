import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'app_config.dart';
import 'socket_service.dart';

class MeshService {
  static final MeshService instance = MeshService._internal();
  MeshService._internal();

  final Strategy strategy = Strategy.P2P_CLUSTER; // CLUSTER is required for true M-to-N mesh topologies
  final String serviceId = 'com.sahyog.mesh'; // Unique identifier for our app

  bool isBroadcasting = false;
  bool isScanning = false;
  
  // Track recently processed payloads to avoid infinite loops
  final Set<String> _processedPayloadIds = {};
  
  // Track known endpoints to prevent infinite reconnect loops
  final Set<String> _knownEndpoints = {};

  Future<bool> requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
      Permission.nearbyWifiDevices,
    ].request();

    bool allGranted = true;
    statuses.forEach((key, value) {
      if (!value.isGranted) allGranted = false;
    });
    return allGranted;
  }

  /// Called by the victim when offline to start sending distress signals
  Future<void> startBroadcastingSOS(Map<String, dynamic> payload) async {
    if (isBroadcasting) return;
    
    bool hasPermissions = await requestPermissions();
    if (!hasPermissions) return;

    try {
      isBroadcasting = true;
      String encodedPayload = jsonEncode(payload);

      await Nearby().startAdvertising(
        "SOS_VICTIM", // Name
        strategy,
        onConnectionInitiated: (String id, ConnectionInfo info) async {
          // Auto-accept connection from any rescuer/relay
          await Nearby().acceptConnection(
            id,
            onPayLoadRecieved: (endpointId, receivedPayload) {
               // We only send, we don't expect to receive payloads when broadcasting SOS
            },
            onPayloadTransferUpdate: (endpointId, payloadTransferUpdate) {},
          );
        },
        onConnectionResult: (String id, Status status) async {
          if (status == Status.CONNECTED) {
            // Once connected, immediately send the distress payload
            await Nearby().sendBytesPayload(id, Uint8List.fromList(utf8.encode(encodedPayload)));
            
            // Disconnect after sending to free up Bluetooth connection slots
            Future.delayed(const Duration(seconds: 3), () {
              Nearby().disconnectFromEndpoint(id);
            });
          }
        },
        onDisconnected: (String id) {
          debugPrint("Mesh Disconnected from: $id");
        },
        serviceId: serviceId,
      );
      debugPrint("Started BLE Mesh SOS Broadcasting");
    } catch (e) {
      isBroadcasting = false;
      debugPrint("Broadcasting Error: $e");
    }
  }

  void stopBroadcasting() {
    Nearby().stopAdvertising();
    Nearby().stopAllEndpoints();
    isBroadcasting = false;
    _knownEndpoints.clear();
  }

  /// Broadcast a cancellation signal so nearby phones remove this SOS
  Future<void> broadcastCancellation(String uuid) async {
    stopBroadcasting();

    bool hasPermissions = await requestPermissions();
    if (!hasPermissions) return;

    try {
      isBroadcasting = true;
      final cancelPayload = jsonEncode({
        'uuid': uuid,
        'action': 'cancel',
        'hop_count': 0,
      });

      await Nearby().startAdvertising(
        "SOS_CANCEL",
        strategy,
        onConnectionInitiated: (String id, ConnectionInfo info) async {
          await Nearby().acceptConnection(
            id,
            onPayLoadRecieved: (e, p) {},
            onPayloadTransferUpdate: (e, p) {},
          );
        },
        onConnectionResult: (String id, Status status) async {
          if (status == Status.CONNECTED) {
            await Nearby().sendBytesPayload(id, Uint8List.fromList(utf8.encode(cancelPayload)));
            
            Future.delayed(const Duration(seconds: 3), () {
              Nearby().disconnectFromEndpoint(id);
            });
          }
        },
        onDisconnected: (String id) {},
        serviceId: serviceId,
      );
      debugPrint("Broadcasting SOS cancellation for: $uuid");

      // Keep broadcasting for 15 seconds then stop
      Future.delayed(const Duration(seconds: 15), () {
        stopBroadcasting();
      });
    } catch (e) {
      isBroadcasting = false;
      debugPrint("Cancel broadcast error: $e");
    }
  }

  /// Called by the Mesh Radar UI to discover nearby SOS signals
  Future<void> startRadarScanner() async {
    if (isScanning) return;
    
    bool hasPermissions = await requestPermissions();
    if (!hasPermissions) return;

    try {
      isScanning = true;
      await Nearby().startDiscovery(
        "RESCUER_NODE",
        strategy,
        onEndpointFound: (String id, String userName, String serviceId) async {
          // Prevent infinite reconnect loop to the same broadcast session
          if (_knownEndpoints.contains(id)) return;
          
          if (userName.startsWith("SOS_VICTIM") || userName.startsWith("RELAY_NODE") || userName.startsWith("SOS_CANCEL")) {
            _knownEndpoints.add(id);
            
            // Found a distress signal, relay, or cancellation — request connection
            await Nearby().requestConnection(
              "RESCUER_NODE",
              id,
              onConnectionInitiated: (id, info) async {
                await Nearby().acceptConnection(
                  id,
                  onPayLoadRecieved: (endpointId, payload) async {
                    if (payload.type == PayloadType.BYTES) {
                      String data = utf8.decode(payload.bytes!);
                      await _processReceivedPayload(data);
                    }
                  },
                  onPayloadTransferUpdate: (endpointId, payloadTransferUpdate) {},
                );
              },
              onConnectionResult: (id, status) {
                if (status == Status.CONNECTED) {
                   debugPrint("Connected to distress node: $id");
                } else {
                   // If connection failed, allow retrying later
                   _knownEndpoints.remove(id);
                }
              },
              onDisconnected: (id) {},
            );
          }
        },
        onEndpointLost: (String? id) {},
        serviceId: serviceId,
      );
      debugPrint("Started BLE Mesh Radar Scanning");
    } catch (e) {
      isScanning = false;
      debugPrint("Scanning Error: $e");
    }
  }

  void stopRadarScanner() {
    Nearby().stopDiscovery();
    isScanning = false;
    _knownEndpoints.clear();
  }

  Future<void> _processReceivedPayload(String rawData) async {
    try {
      Map<String, dynamic> data = jsonDecode(rawData);
      String uuid = data['uuid'] ?? '';
      String action = data['action'] ?? 'sos';

      // Handle cancellation packets
      if (action == 'cancel') {
        debugPrint("Received mesh cancellation for: $uuid");
        // Remove from live alerts on this phone's radar
        final current = Map<String, Map<String, dynamic>>.from(
          SocketService.instance.liveSosAlerts.value,
        );
        current.removeWhere((key, value) {
          return value['client_uuid'] == uuid || key == uuid;
        });
        SocketService.instance.liveSosAlerts.value = current;
        return;
      }

      if (_processedPayloadIds.contains(uuid)) return; // Prevent loops
      _processedPayloadIds.add(uuid);

      int hopCount = (data['hop_count'] ?? 0) as int;
      if (hopCount >= 3) {
        debugPrint("Hop limit reached for SOS: $uuid");
        return; 
      }

      data['hop_count'] = hopCount + 1;
      data['relayed_via_mesh'] = true;
      data['source'] = 'mesh_ble';

      // Ensure the received SOS is immediately visible on the local device's radar
      final currentAlerts = Map<String, Map<String, dynamic>>.from(
        SocketService.instance.liveSosAlerts.value,
      );
      currentAlerts[uuid] = data;
      SocketService.instance.liveSosAlerts.value = currentAlerts;

      final connectivityResult = await Connectivity().checkConnectivity();
      bool hasInternet = !connectivityResult.contains(ConnectivityResult.none);

      if (hasInternet) {
        // We have internet! Push to backend
        debugPrint("Mesh node has internet. Relaying SOS to server...");
        final response = await http.post(
          Uri.parse('${AppConfig.baseUrl}/api/v1/mesh/sync'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'packets': [data]
          }),
        );
        if (response.statusCode == 200) {
          debugPrint("Successfully relayed mesh payload to server");
        }
      } else {
        // No internet. Re-broadcast as a relay node
        debugPrint("Mesh node offline. Re-broadcasting as Relay Node...");
        startBroadcastingRelay(data);
      }
    } catch (e) {
      debugPrint("Error processing mesh payload: $e");
    }
  }

  Future<void> startBroadcastingRelay(Map<String, dynamic> payload) async {
    // Stop current scanning/broadcasting to switch roles if necessary
    stopBroadcasting();
    stopRadarScanner();
    
    try {
      isBroadcasting = true;
      String encodedPayload = jsonEncode(payload);

      await Nearby().startAdvertising(
        "RELAY_NODE",
        strategy,
        onConnectionInitiated: (String id, ConnectionInfo info) async {
          await Nearby().acceptConnection(
            id,
            onPayLoadRecieved: (e, p) {},
            onPayloadTransferUpdate: (e, p) {},
          );
        },
        onConnectionResult: (String id, Status status) async {
          if (status == Status.CONNECTED) {
            await Nearby().sendBytesPayload(id, Uint8List.fromList(utf8.encode(encodedPayload)));
          }
        },
        onDisconnected: (String id) {},
        serviceId: serviceId,
      );
    } catch (e) {
      isBroadcasting = false;
    }
  }
}
