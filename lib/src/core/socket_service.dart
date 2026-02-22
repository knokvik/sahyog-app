import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'app_config.dart';

class SocketService {
  static final SocketService instance = SocketService._internal();

  SocketService._internal();

  IO.Socket? _socket;

  // Let the UI know there's a new SOS so it can trigger a board refresh
  final ValueNotifier<Map<String, dynamic>?> onNewSosAlert = ValueNotifier(
    null,
  );
  final ValueNotifier<Map<String, dynamic>?> onSosResolved = ValueNotifier(
    null,
  );

  /// Tracks all currently active SOS alerts received via socket
  final ValueNotifier<Map<String, Map<String, dynamic>>> liveSosAlerts =
      ValueNotifier({});

  void initialize(BuildContext context, bool isCoordinatorOrAdmin) {
    if (_socket != null) return;

    // Connect to the Node Express server url
    _socket = IO.io(AppConfig.baseUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'path': '/socket.io/', // Explicit path for reliability
    });

    _socket!.onConnectError((data) {
      print('Socket Connection Error: $data');
    });

    _socket!.onConnect((_) {
      print('Connected to Real-Time SOS Socket at ${AppConfig.baseUrl}');
    });

    _socket!.on('new_sos_alert', (data) {
      if (context.mounted) {
        // Show a highly visible red toast for ALL users
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'EMERGENCY SOS: ${data['type'] ?? 'Help Needed'} from ${data['reporter_name'] ?? 'Unknown'}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            backgroundColor: AppColors.criticalRed,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.only(top: 60, left: 16, right: 16),
            dismissDirection: DismissDirection.up,
            duration: const Duration(seconds: 10),
          ),
        );

        // Trigger a reload for any listening active boards & map
        if (data is Map<String, dynamic>) {
          onNewSosAlert.value = data;

          final alerts = Map<String, Map<String, dynamic>>.from(
            liveSosAlerts.value,
          );
          final id = data['id']?.toString();
          if (id != null) {
            alerts[id] = data;
            liveSosAlerts.value = alerts;
          }
        }
      }
    });

    _socket!.on('sos_resolved', (data) {
      if (data is Map<String, dynamic>) {
        onSosResolved.value = data;

        final id = data['id']?.toString();
        if (id != null) {
          final alerts = Map<String, Map<String, dynamic>>.from(
            liveSosAlerts.value,
          );
          if (alerts.containsKey(id)) {
            alerts.remove(id);
            liveSosAlerts.value = alerts;
          }
        }
      }
    });

    _socket!.onDisconnect((_) {
      print('Disconnected from Real-Time SOS Socket');
    });
  }

  void setInitialAlerts(List<Map<String, dynamic>> alerts) {
    final Map<String, Map<String, dynamic>> map = {};
    for (var a in alerts) {
      final id = a['id']?.toString();
      if (id != null &&
          a['status'] != 'resolved' &&
          a['status'] != 'cancelled') {
        map[id] = a;
      }
    }
    liveSosAlerts.value = map;
  }

  void dispose() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }
}
