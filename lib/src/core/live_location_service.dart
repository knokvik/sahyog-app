import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'database_helper.dart';

/// Represents a live user location received from the server.
class LiveUserLocation {
  final String userId;
  final String role;
  final double lat;
  final double lng;
  final String name;
  final int timestamp;

  LiveUserLocation({
    required this.userId,
    required this.role,
    required this.lat,
    required this.lng,
    this.name = '',
    required this.timestamp,
  });

  factory LiveUserLocation.fromJson(Map<String, dynamic> json) {
    return LiveUserLocation(
      userId: json['userId']?.toString() ?? '',
      role: json['role']?.toString() ?? 'unknown',
      lat: (json['lat'] is num)
          ? (json['lat'] as num).toDouble()
          : double.tryParse(json['lat']?.toString() ?? '') ?? 0,
      lng: (json['lng'] is num)
          ? (json['lng'] as num).toDouble()
          : double.tryParse(json['lng']?.toString() ?? '') ?? 0,
      name: json['name']?.toString() ?? '',
      timestamp: json['timestamp'] is int
          ? json['timestamp'] as int
          : DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// Singleton service that:
///  1. Periodically sends the device's location to the server via Socket.io (every 5 seconds).
///  2. Listens for `location.update` events from the server and maintains a live map of user positions.
class LiveLocationService {
  LiveLocationService._();
  static final LiveLocationService instance = LiveLocationService._();

  Timer? _sendTimer;
  IO.Socket? _socket;
  String? _userId;
  String? _role;
  bool _running = false;

  /// Observable map of all live user locations from the server.
  final ValueNotifier<Map<String, LiveUserLocation>> liveLocations =
      ValueNotifier<Map<String, LiveUserLocation>>({});

  /// Start sending location updates and listening for incoming ones.
  void start({
    required String userId,
    required String role,
    required IO.Socket? socket,
  }) {
    if (_running) return;
    _userId = userId;
    _role = role;
    _socket = socket;
    _running = true;

    // Listen for incoming location updates
    _socket?.on('location.update', _onLocationUpdate);

    // Start sending own location every 5 seconds
    _sendTimer?.cancel();
    _sendTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _sendLocation(),
    );

    // Send immediately on start
    _sendLocation();

    debugPrint('[LiveLocation] Started for $role:$userId');
  }

  /// Stop sending and listening.
  void stop() {
    _running = false;
    _sendTimer?.cancel();
    _sendTimer = null;
    _socket?.off('location.update', _onLocationUpdate);
    debugPrint('[LiveLocation] Stopped');
  }

  void dispose() {
    stop();
    liveLocations.dispose();
  }

  void _onLocationUpdate(dynamic data) {
    try {
      Map<String, dynamic> json;
      if (data is String) {
        json = jsonDecode(data) as Map<String, dynamic>;
      } else if (data is Map) {
        json = Map<String, dynamic>.from(data);
      } else {
        return;
      }

      final loc = LiveUserLocation.fromJson(json);
      if (loc.userId.isEmpty) return;

      final current = Map<String, LiveUserLocation>.from(liveLocations.value);
      current[loc.userId] = loc;

      // Prune entries older than 60 seconds
      final cutoff = DateTime.now().millisecondsSinceEpoch - 60000;
      current.removeWhere((_, v) => v.timestamp < cutoff);

      liveLocations.value = current;
    } catch (e) {
      debugPrint('[LiveLocation] Parse error: $e');
    }
  }

  Future<void> _sendLocation() async {
    if (!_running || _socket == null || _userId == null) return;

    // Only send if volunteer/coordinator, or if user and SOS is active
    if (_role == 'user') {
      try {
        final incident = await DatabaseHelper.instance.getActiveIncident(
          _userId!,
        );
        if (incident == null) return; // No active SOS for citizen
      } catch (_) {
        return; // Safe fail
      }
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 4),
        ),
      );

      _socket!.emit('location.update', {
        'userId': _userId,
        'role': _role,
        'lat': position.latitude,
        'lng': position.longitude,
      });
    } catch (e) {
      // Silently ignore — might be permission denied, GPS off, etc.
      debugPrint('[LiveLocation] Send error: $e');
    }
  }
}
