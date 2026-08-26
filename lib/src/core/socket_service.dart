import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/material.dart';
import '../app.dart';
import '../features/home/sos_alerts_panel.dart';
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

  void initialize([BuildContext? context, bool isCoordinatorOrAdmin = true]) {
    if (_socket != null) {
      if (!_socket!.connected) {
        _socket!.connect();
      }
      return;
    }

    // Connect to the Node Express server url
    _socket = IO.io(
      AppConfig.baseUrl,
      IO.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .enableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(999)
          .setReconnectionDelay(1000)
          .setPath('/socket.io')
          .build(),
    );

    _socket!.onConnectError((data) {
      debugPrint('[Socket] Connection Error: $data');
    });

    _socket!.onConnect((_) {
      debugPrint('[Socket] Connected to Real-Time SOS Socket at ${AppConfig.baseUrl}');
    });

    _socket!.on('new_sos_alert', (raw) {
      debugPrint('[Socket] Received new_sos_alert: $raw');
      final data = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

      // 1. Update reactive notifiers
      onNewSosAlert.value = data;

      final id = data['id']?.toString() ??
          data['uuid']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString();
      final alerts = Map<String, Map<String, dynamic>>.from(
        liveSosAlerts.value,
      );
      alerts[id] = data;
      liveSosAlerts.value = alerts;

      // 2. Open configured SOS alerts bottom sheet popup from below
      final navContext = SahyogApp.navigatorKey.currentContext;
      if (navContext != null && navContext.mounted) {
        SosAlertsPanel.show(
          context: navContext,
          alerts: alerts,
          onGoToSosPanels: () {
            Navigator.of(navContext, rootNavigator: true).maybePop();
          },
        );
      } else {
        // Fallback to top-level floating snackbar
        final messenger = SahyogApp.scaffoldMessengerKey.currentState;
        if (messenger != null) {
          messenger.clearSnackBars();
          messenger.showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'EMERGENCY SOS: ${data['type'] ?? 'Help Needed'}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        if (data['reporter_name'] != null)
                          Text(
                            'From: ${data['reporter_name']}',
                            style: const TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              backgroundColor: AppColors.criticalRed,
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.only(top: 40, left: 16, right: 16),
              dismissDirection: DismissDirection.up,
              duration: const Duration(seconds: 10),
            ),
          );
        }
      }
    });

    _socket!.on('sos_resolved', (raw) {
      debugPrint('[Socket] Received sos_resolved: $raw');
      final data = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
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
    });

    _socket!.onDisconnect((_) {
      debugPrint('[Socket] Disconnected from Real-Time SOS Socket');
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
