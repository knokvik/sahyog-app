import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/location_service.dart';
import '../../core/models.dart';
import '../../core/socket_service.dart';
import '../../core/database_helper.dart';
import '../../core/sos_state_machine.dart';
import '../../core/sos_sync_engine.dart';
import '../../core/ble_advertiser_service.dart';
import '../../core/ble_scanner_service.dart';
import '../../core/ble_payload_codec.dart';
import 'mesh_alert_panel.dart';
import '../../theme/app_colors.dart';

class UserHomeTab extends StatefulWidget {
  const UserHomeTab({super.key, required this.api, required this.user});

  final ApiClient api;
  final AppUser user;

  @override
  State<UserHomeTab> createState() => _UserHomeTabState();
}

class _UserHomeTabState extends State<UserHomeTab>
    with AutomaticKeepAliveClientMixin {
  final _locationService = LocationService();
  final MapController _miniMapController = MapController();

  Position? _position;
  bool _loading = true;
  List<Map<String, dynamic>> _alerts = [];
  Timer? _pollTimer;

  Timer? _sosHoldTimer;
  int _sosHoldTicks = 0;
  bool _sosFired = false;
  String? _activeSosId;
  String? _activeLocalUuid; // UUID of the active local SOS incident

  // Track detected mesh beacons
  BleBeacon? _detectedBeacon;
  String _detectedDistance = '';

  // Track global SOS from sockets: {id: LatLng}
  final Map<String, LatLng> _globalActiveSos = {};

  @override
  void initState() {
    super.initState();
    _loadActiveSos();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _load(silent: true);
    });

    SocketService.instance.onNewSosAlert.addListener(_onRemoteSosReceived);
    SocketService.instance.onSosResolved.addListener(_onRemoteSosResolved);
    SosSyncEngine.instance.syncCompletionNotifier.addListener(
      _onBackgroundSyncComplete,
    );
    BleAdvertiserService.instance.ackReceivedNotifier.addListener(
      _onBleAckReceived,
    );
    BleScannerService.instance.beaconDetectedNotifier.addListener(
      _onMeshBeaconDetected,
    );
    BleScannerService.instance.distanceNotifier.addListener(
      _onMeshDistanceUpdated,
    );
  }

  void _onBackgroundSyncComplete() {
    final id = SosSyncEngine.instance.syncCompletionNotifier.value;
    if (id != null && mounted) {
      setState(() {
        _activeSosId = id;
        _sosFired = true;
      });
    }
  }

  Future<void> _loadActiveSos() async {
    // Check SharedPreferences for a persisted backend ID
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString('active_sos_id');
    if (savedId != null) {
      setState(() {
        _activeSosId = savedId;
        _sosFired = true;
      });
      return;
    }

    // Check SQLite for any active local incident
    final db = DatabaseHelper.instance;
    final active = await db.getActiveIncident(widget.user.id);
    if (active != null) {
      setState(() {
        _activeLocalUuid = active.uuid;
        _activeSosId = active.backendId;
        _sosFired = true;
      });
    }
  }

  void _onRemoteSosReceived() {
    final payload = SocketService.instance.onNewSosAlert.value;
    if (payload == null) return;

    final locRaw = payload['location'];
    if (locRaw is Map<String, dynamic> && locRaw['coordinates'] is List) {
      final coords = locRaw['coordinates'];
      if (coords.length >= 2) {
        final id = payload['id'].toString();
        if (id == _activeSosId) return;

        setState(() {
          _globalActiveSos[id] = LatLng(
            (coords[1] as num).toDouble(),
            (coords[0] as num).toDouble(),
          );
        });
      }
    }
  }

  void _onRemoteSosResolved() {
    final payload = SocketService.instance.onSosResolved.value;
    if (payload == null) return;

    final id = payload['id'].toString();
    setState(() {
      _globalActiveSos.remove(id);
    });
  }

  void _onBleAckReceived() async {
    final uuidHash = BleAdvertiserService.instance.ackReceivedNotifier.value;
    if (uuidHash == null || _activeLocalUuid == null) return;

    final db = DatabaseHelper.instance;
    final incident = await db.getIncidentByUuid(_activeLocalUuid!);
    if (incident != null && incident.uuidHash == uuidHash) {
      if (SosStateMachine.canTransition(
        incident.status,
        SosStatus.acknowledged,
      )) {
        await db.atomicUpdateIncident(
          incident.uuid,
          status: SosStatus.acknowledged,
        );
        SosLog.event(
          incident.uuid,
          'ACK_VIA_BLE',
          'Mesh responder help coming',
        );

        // Stop advertiser since we're acknowledged
        await BleAdvertiserService.instance.stopAdvertising(
          reason: 'ack_received',
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Help is on the way! (Received via BLE Mesh)'),
              backgroundColor: AppColors.primaryGreen,
            ),
          );
        }
      }
    }
  }

  void _onMeshBeaconDetected() {
    final beacon = BleScannerService.instance.beaconDetectedNotifier.value;
    if (beacon != null && mounted) {
      setState(() {
        _detectedBeacon = beacon;
        _detectedDistance =
            BleScannerService.instance.distanceNotifier.value[beacon
                .uuidHash] ??
            'Nearby';
      });
    }
  }

  void _onMeshDistanceUpdated() {
    if (_detectedBeacon != null && mounted) {
      final distance = BleScannerService
          .instance
          .distanceNotifier
          .value[_detectedBeacon!.uuidHash];
      if (distance != null && distance != _detectedDistance) {
        setState(() {
          _detectedDistance = distance;
        });
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _sosHoldTimer?.cancel();
    SocketService.instance.onNewSosAlert.removeListener(_onRemoteSosReceived);
    SocketService.instance.onSosResolved.removeListener(_onRemoteSosResolved);
    SosSyncEngine.instance.syncCompletionNotifier.removeListener(
      _onBackgroundSyncComplete,
    );
    BleAdvertiserService.instance.ackReceivedNotifier.removeListener(
      _onBleAckReceived,
    );
    BleScannerService.instance.beaconDetectedNotifier.removeListener(
      _onMeshBeaconDetected,
    );
    BleScannerService.instance.distanceNotifier.removeListener(
      _onMeshDistanceUpdated,
    );
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      if (!silent) {
        setState(() {
          _loading = true;
        });
      }

      Position? pos;
      try {
        pos = await _locationService.getCurrentPosition().timeout(
          const Duration(seconds: 5),
        );
      } catch (_) {}

      final disastersRaw = await widget.api.get('/api/v1/disasters');
      final disasters = (disastersRaw is List)
          ? disastersRaw.cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];

      if (!mounted) return;
      setState(() {
        _position = pos;
        _alerts = disasters;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  bool get wantKeepAlive => true;

  // ─────────────────────────────────────────────────────────
  // SOS Activation — State Machine Driven
  // ─────────────────────────────────────────────────────────

  Future<void> _triggerSOS() async {
    final db = DatabaseHelper.instance;

    // Prevent double-trigger: check if already active
    final existing = await db.getActiveIncident(widget.user.id);
    if (existing != null) {
      SosLog.event(existing.uuid, 'DOUBLE_TRIGGER_BLOCKED');
      setState(() {
        _activeLocalUuid = existing.uuid;
        _activeSosId = existing.backendId;
        _sosFired = true;
      });
      return;
    }

    // 1. Fetch location (12s timeout, fallback to null)
    Position? pos = _position;
    if (pos == null) {
      try {
        pos = await _locationService.getCurrentPosition().timeout(
          const Duration(seconds: 12),
        );
      } catch (_) {}
    }

    // 2. Create SOS incident with UUID
    final incident = SosIncident(
      reporterId: widget.user.id,
      lat: pos?.latitude,
      lng: pos?.longitude,
      type: 'Emergency',
      status: SosStatus.activating,
    );

    SosLog.event(
      incident.uuid,
      'ACTIVATE',
      'lat=${pos?.latitude}, lng=${pos?.longitude}',
    );

    // 3. Save to SQLite → transition to active_offline
    await db.insertSosIncident(incident);
    await db.atomicUpdateIncident(
      incident.uuid,
      status: SosStatus.activeOffline,
    );

    setState(() {
      _activeLocalUuid = incident.uuid;
      _sosFired = true;
    });

    // 4. Start BLE Mesh advertising immediately (zero-network resilience)
    await BleAdvertiserService.instance.startAdvertising(incident);

    // 4. Trigger immediate sync via engine
    // We let the engine's SocketExceptions and backoffs handle true offline scenarios
    // rather than using connectivity_plus, which can falsely report offline on local networks.
    SosLog.event(incident.uuid, 'IMMEDIATE_SYNC_ATTEMPT');
    await SosSyncEngine.instance.syncAll();

    // Check if sync was successful
    final updated = await db.getIncidentByUuid(incident.uuid);
    if (updated != null && updated.status == SosStatus.activeOnline) {
      setState(() {
        _activeSosId = updated.backendId;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('SOS Activated! Broadcasting to all responders...'),
            backgroundColor: AppColors.criticalRed,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SOS saved. Sync pending — will retry automatically.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  // ─────────────────────────────────────────────────────────
  // SOS Cancellation — State Machine Driven
  // ─────────────────────────────────────────────────────────

  Future<void> _cancelSOS() async {
    final db = DatabaseHelper.instance;
    final uuidToCancel = _activeLocalUuid;
    final backendIdToCancel = _activeSosId;

    SosLog.event(
      uuidToCancel ?? 'unknown',
      'CANCEL_INITIATED',
      'backendId=$backendIdToCancel',
    );

    // ── Immediately reset UI ──
    setState(() {
      _activeSosId = null;
      _activeLocalUuid = null;
      _sosFired = false;
      _sosHoldTicks = 0;
    });

    // Clear persisted ID
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('active_sos_id');

    // ── Update SQLite atomically ──
    if (uuidToCancel != null) {
      await db.atomicUpdateIncident(uuidToCancel, status: SosStatus.cancelled);
      SosLog.event(uuidToCancel, 'CANCEL_SQLITE', 'status=cancelled');

      // ── Stop BLE / Send Cancel Beacon ──
      final incident = await db.getIncidentByUuid(uuidToCancel);
      if (incident != null) {
        await BleAdvertiserService.instance.emitCancelBeacon(incident);
      }
    }

    // ── Case 1: Has backend ID — cancel on server ──
    if (backendIdToCancel != null) {
      try {
        await widget.api.put('/api/v1/sos/$backendIdToCancel/cancel');
        SosLog.event(
          uuidToCancel ?? 'unknown',
          'CANCEL_SERVER',
          'backendId=$backendIdToCancel',
        );
        // Mark cancellation as synced
        if (uuidToCancel != null) {
          await db.markCancellationSynced(uuidToCancel);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white),
                  SizedBox(width: 12),
                  Text('SOS Cancelled. You are marked as safe.'),
                ],
              ),
              backgroundColor: AppColors.primaryGreen,
              duration: Duration(seconds: 3),
            ),
          );
        }
      } catch (e) {
        SosLog.event(
          uuidToCancel ?? 'unknown',
          'CANCEL_SERVER_FAIL',
          'Will retry on reconnect. error=$e',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'SOS cancelled locally. Server will be notified when online.',
              ),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
      return;
    }

    // ── Case 2: No backend ID (offline SOS) — already cancelled in SQLite ──
    SosLog.event(
      uuidToCancel ?? 'unknown',
      'CANCEL_OFFLINE',
      'No backend ID — local record cancelled. Will not sync.',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 12),
              Text('Offline SOS cancelled. No data sent.'),
            ],
          ),
          backgroundColor: AppColors.primaryGreen,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  // ─────────────────────────────────────────────────────────
  // Build Methods
  // ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _load,
      child: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _UserStatusBanner(user: widget.user),
              const SizedBox(height: 16),
              Card(
                clipBehavior: Clip.antiAlias,
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SizedBox(height: 220, child: _buildMiniMap()),
              ),
              const SizedBox(height: 16),
              _buildEmergencySOSButton(),
              const SizedBox(height: 24),
              Row(
                children: [
                  const Icon(
                    Icons.emergency_share_outlined,
                    color: AppColors.criticalRed,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Recent Disaster Alerts',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_alerts.isEmpty)
                _EmptyAlertsState()
              else
                ..._alerts.map(
                  (alert) => _AlertCard(alert: alert, api: widget.api),
                ),
              const SizedBox(height: 32),
            ],
          ),
          if (_detectedBeacon != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: MeshAlertPanel(
                beacon: _detectedBeacon!,
                distance: _detectedDistance,
                onRespond: () {
                  BleScannerService.instance.sendAckBeacon(
                    _detectedBeacon!.uuidHash,
                  );
                  setState(() {
                    _detectedBeacon = null;
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Relay started! Acknowledgment sent via BLE.',
                      ),
                      backgroundColor: AppColors.primaryGreen,
                    ),
                  );
                },
                onDismiss: () {
                  setState(() {
                    _detectedBeacon = null;
                  });
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmergencySOSButton() {
    final double progress = (_sosHoldTicks / 50.0).clamp(0.0, 1.0);

    // If we have an active SOS, show the cancellation UI with HOLD mechanism
    if (_activeSosId != null || _sosFired) {
      return Column(
        children: [
          GestureDetector(
            onTapDown: (_) {
              _sosHoldTicks = 0;
              _sosHoldTimer = Timer.periodic(
                const Duration(milliseconds: 100),
                (timer) {
                  setState(() {
                    _sosHoldTicks++;
                    if (_sosHoldTicks >= 50) {
                      _sosHoldTimer?.cancel();
                      _cancelSOS();
                    }
                  });
                },
              );
            },
            onTapUp: (_) => _cancelHold(),
            onTapCancel: () => _cancelHold(),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.criticalRed,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.criticalRed.withOpacity(0.4),
                    blurRadius: 15,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_sosHoldTicks > 0)
                    Positioned.fill(
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: progress,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.emergency,
                        color: Colors.white,
                        size: 36,
                      ),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _sosHoldTicks > 0 ? 'RELEASING...' : 'SOS ACTIVE',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 20,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _sosHoldTicks > 0
                                ? 'Release in ${(5.0 - (_sosHoldTicks / 10)).toStringAsFixed(1)}s'
                                : 'Hold for 5 sec to cancel the SOS',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // ── Live Sync Status Strip ──
          ValueListenableBuilder<SosSyncStatus>(
            valueListenable: SosSyncEngine.instance.syncStatusNotifier,
            builder: (context, status, _) {
              if (status.phase == SosSyncPhase.idle) {
                // If SOS is active but synced, show confirmation
                if (_activeSosId != null) {
                  return _SyncStatusStrip(
                    icon: Icons.check_circle,
                    color: AppColors.primaryGreen,
                    message: 'SOS delivered to all responders',
                  );
                }
                // Active but not synced yet, waiting for connectivity
                return _SyncStatusStrip(
                  icon: Icons.wifi_off,
                  color: Colors.orange,
                  message: 'Offline — waiting for connection...',
                  showPulse: true,
                );
              }

              switch (status.phase) {
                case SosSyncPhase.connecting:
                  return _SyncStatusStrip(
                    icon: Icons.sync,
                    color: Colors.orange,
                    message: status.message,
                    showPulse: true,
                  );
                case SosSyncPhase.syncing:
                  return _SyncStatusStrip(
                    icon: Icons.cloud_upload,
                    color: Colors.blue,
                    message: status.message,
                    showPulse: true,
                  );
                case SosSyncPhase.waitingRetry:
                  return _SyncStatusStrip(
                    icon: Icons.timer,
                    color: Colors.orange,
                    message: status.message,
                    showPulse: true,
                  );
                case SosSyncPhase.synced:
                  return _SyncStatusStrip(
                    icon: Icons.check_circle,
                    color: AppColors.primaryGreen,
                    message: status.message,
                  );
                case SosSyncPhase.failed:
                  return _SyncStatusStrip(
                    icon: Icons.error,
                    color: AppColors.criticalRed,
                    message: status.message,
                  );
                default:
                  return const SizedBox.shrink();
              }
            },
          ),
        ],
      );
    }

    return GestureDetector(
      onTapDown: (_) {
        if (_sosFired) return;
        _sosHoldTicks = 0;
        _sosHoldTimer = Timer.periodic(const Duration(milliseconds: 100), (
          timer,
        ) {
          setState(() {
            _sosHoldTicks++;
            if (_sosHoldTicks >= 50) {
              _sosHoldTimer?.cancel();
              _sosFired = true;
              _triggerSOS();
            }
          });
        });
      },
      onTapUp: (_) => _cancelHold(),
      onTapCancel: () => _cancelHold(),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.criticalRed, width: 2),
          boxShadow: [
            if (_sosHoldTicks > 0)
              BoxShadow(
                color: AppColors.criticalRed.withOpacity(0.3),
                blurRadius: 10,
                spreadRadius: progress * 5,
              ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (!_sosFired && _sosHoldTicks > 0)
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: progress,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.criticalRed.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.emergency,
                  color: AppColors.criticalRed,
                  size: 36,
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'HOLD FOR SOS',
                      style: TextStyle(
                        color: AppColors.criticalRed,
                        fontWeight: FontWeight.bold,
                        fontSize: 20,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      (_sosHoldTicks > 0)
                          ? 'Holding... ${(5.0 - (_sosHoldTicks / 10)).toStringAsFixed(1)}s'
                          : 'Hold for 5 seconds to request help',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                        fontWeight: _sosHoldTicks > 0
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _cancelHold() {
    _sosHoldTimer?.cancel();
    setState(() {
      _sosHoldTicks = 0;
    });
  }

  Widget _buildMiniMap() {
    LatLng center = const LatLng(18.5204, 73.8567);
    if (_position != null) {
      center = LatLng(_position!.latitude, _position!.longitude);
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _miniMapController,
          options: MapOptions(initialCenter: center, initialZoom: 13),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.sahyog_app',
            ),
            MarkerLayer(
              markers: [
                if (_position != null)
                  Marker(
                    point: center,
                    width: 40,
                    height: 40,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.primaryGreen.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.person_pin_circle,
                          color: AppColors.primaryGreen,
                          size: 32,
                        ),
                      ),
                    ),
                  ),
                ..._globalActiveSos.entries.map((entry) {
                  return Marker(
                    point: entry.value,
                    width: 100,
                    height: 100,
                    child: const _PulsingMarkerWidget(),
                  );
                }),
              ],
            ),
          ],
        ),
        Positioned(
          top: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.my_location,
                  size: 14,
                  color: AppColors.primaryGreen,
                ),
                const SizedBox(width: 6),
                const Text(
                  'Live View',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _UserStatusBanner extends StatelessWidget {
  const _UserStatusBanner({required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primaryGreen.withOpacity(0.1), Colors.white],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primaryGreen.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.primaryGreen.withOpacity(0.2),
            child: const Icon(
              Icons.verified_user,
              color: AppColors.primaryGreen,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome, ${user.name}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  'Stay safe. Monitor active alerts below.',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.api});
  final Map<String, dynamic> alert;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    final severity = (alert['severity'] ?? 0).toInt();
    final isCritical = severity >= 4;
    final color = isCritical ? AppColors.criticalRed : Colors.orange;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withOpacity(0.2)),
      ),
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (ctx) => AlertDetailPage(alert: alert, api: api),
          ),
        ),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.warning_amber_rounded, color: color),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (alert['name'] ?? 'Disaster Alert').toString(),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      (alert['type'] ?? 'Unknown Type')
                          .toString()
                          .toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyAlertsState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(32),
      alignment: Alignment.center,
      child: Column(
        children: [
          Icon(Icons.shield_outlined, size: 48, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text(
            'No active alerts in your area',
            style: TextStyle(color: Colors.grey[500], fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class AlertDetailPage extends StatelessWidget {
  const AlertDetailPage({super.key, required this.alert, required this.api});
  final Map<String, dynamic> alert;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alert Details')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            (alert['name'] ?? 'Disaster Update').toString(),
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _Tag(
                label: (alert['type'] ?? 'Disaster').toString().toUpperCase(),
                color: AppColors.primaryGreen,
              ),
              const SizedBox(width: 8),
              _Tag(
                label: 'SEVERITY: ${alert['severity'] ?? 'N/A'}',
                color: AppColors.criticalRed,
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text(
            'Description',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          const SizedBox(height: 12),
          Text(
            (alert['description'] ??
                    'No detailed description available for this alert at this time. Please follow local news and official guidance.')
                .toString(),
            style: const TextStyle(
              fontSize: 15,
              height: 1.6,
              color: Colors.blueGrey,
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Affected Area',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              height: 250,
              color: Colors.grey[100],
              child: const Center(child: Text('Map View of Affected Area')),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _PulsingMarkerWidget extends StatefulWidget {
  const _PulsingMarkerWidget();

  @override
  State<_PulsingMarkerWidget> createState() => _PulsingMarkerWidgetState();
}

class _PulsingMarkerWidgetState extends State<_PulsingMarkerWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            Transform.scale(
              scale: _controller.value * 2.0,
              child: Opacity(
                opacity: 1.0 - _controller.value,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.criticalRed, width: 2),
                  ),
                ),
              ),
            ),
            Transform.scale(
              scale: ((_controller.value + 0.5) % 1.0) * 2.0,
              child: Opacity(
                opacity: 1.0 - ((_controller.value + 0.5) % 1.0),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.criticalRed, width: 2),
                  ),
                ),
              ),
            ),
            Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: AppColors.criticalRed,
                shape: BoxShape.circle,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Compact status strip shown below the SOS button during sync activity.
class _SyncStatusStrip extends StatelessWidget {
  const _SyncStatusStrip({
    required this.icon,
    required this.color,
    required this.message,
    this.showPulse = false,
  });

  final IconData icon;
  final Color color;
  final String message;
  final bool showPulse;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (showPulse) _PulsingDot(color: color),
        ],
      ),
    );
  }
}

/// Small pulsing dot to indicate active background activity.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});
  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: 0.3 + (_controller.value * 0.7),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}
