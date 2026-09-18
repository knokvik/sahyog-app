import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'sos_sync_engine.dart';
import 'sos_state_machine.dart';
import 'api_client.dart';

/// Listens to connectivity changes and delegates SOS sync to [SosSyncEngine].
///
/// This service is the bridge between the OS-level connectivity events
/// and the mutex-locked sync engine. It does NOT contain any sync logic itself.
class ConnectivityService {
  static final ConnectivityService instance = ConnectivityService._internal();
  ConnectivityService._internal();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _periodicSync;

  void initialize(ApiClient api) {
    // Initialize the sync engine with the API client
    SosSyncEngine.instance.initialize(api);

    // Listen to connectivity changes
    _subscription = _connectivity.onConnectivityChanged.listen(
      _handleConnectionChange,
    );

    // Periodic fallback: every 30s, try syncing stuck records
    _periodicSync = Timer.periodic(const Duration(seconds: 30), (_) {
      SosSyncEngine.instance.syncAll();
    });
  }

  void dispose() {
    _subscription?.cancel();
    _periodicSync?.cancel();
  }

  Future<void> _handleConnectionChange(List<ConnectivityResult> results) async {
    if (results.any((r) => r != ConnectivityResult.none)) {
      SosLog.warn('CONNECTIVITY', 'Connection restored — triggering sync');
      // Small delay to let the connection stabilize
      await Future.delayed(const Duration(seconds: 2));
      await SosSyncEngine.instance.syncAll();
    }
  }

  /// Expose the sync completion notifier for backward compatibility
  /// (UserHomeTab listens to this)
  get syncCompletionNotifier => SosSyncEngine.instance.syncCompletionNotifier;
}
