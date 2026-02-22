import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'database_helper.dart';
import 'sos_state_machine.dart';

/// User-visible sync status for the SOS indicator.
class SosSyncStatus {
  const SosSyncStatus({
    this.phase = SosSyncPhase.idle,
    this.attempt = 0,
    this.maxAttempts = 5,
    this.backoffSeconds = 0,
    this.message = '',
  });

  final SosSyncPhase phase;
  final int attempt;
  final int maxAttempts;
  final int backoffSeconds;
  final String message;

  static const idle = SosSyncStatus();
}

enum SosSyncPhase { idle, connecting, syncing, waitingRetry, synced, failed }

/// Production-grade SOS sync engine with:
/// - Mutex lock (only one sync cycle at a time)
/// - Exponential backoff (2^retryCount seconds, max 60s)
/// - Cancellation-aware (skips cancelled/resolved records)
/// - Max retry threshold (marks failed after MAX_RETRIES)
/// - Pending cancellation sync (cancels on server when back online)
class SosSyncEngine {
  static final SosSyncEngine instance = SosSyncEngine._internal();
  SosSyncEngine._internal();

  /// Max times we retry syncing a single incident before marking it failed.
  static const int maxRetries = 5;

  /// Whether a sync cycle is currently executing.
  bool _isSyncing = false;

  /// The API client — set via initialize().
  ApiClient? _api;

  /// Notifies listeners when an offline SOS is successfully synced.
  /// Value is the backend-assigned SOS ID.
  final ValueNotifier<String?> syncCompletionNotifier = ValueNotifier(null);

  /// Notifies listeners when a sync cycle completes (success or not).
  final ValueNotifier<int> syncCycleCounter = ValueNotifier(0);

  /// User-visible sync status — drives the retry indicator in the SOS button.
  final ValueNotifier<SosSyncStatus> syncStatusNotifier = ValueNotifier(
    SosSyncStatus.idle,
  );

  void initialize(ApiClient api) {
    _api = api;
  }

  /// Calculate exponential backoff delay.
  /// delay = min(2^retryCount * 1000ms, 60000ms)
  Duration _backoffDelay(int retryCount) {
    final ms = (1 << retryCount) * 1000; // 2^n * 1000
    return Duration(milliseconds: ms.clamp(1000, 60000));
  }

  /// Main sync entrypoint. Mutex-protected — only one execution at a time.
  ///
  /// 1. Marks expired incidents as failed
  /// 2. Syncs all active_offline incidents to the backend
  /// 3. Syncs pending cancellations to the backend
  Future<void> syncAll() async {
    if (_api == null) {
      SosLog.warn('SYNC_ENGINE', 'Not initialized — no API client');
      return;
    }

    // ── Mutex lock ──────────────────────────────────────
    if (_isSyncing) {
      SosLog.warn('SYNC_ENGINE', 'Already running — skipping');
      return;
    }
    _isSyncing = true;
    SosLog.warn('SYNC_ENGINE', 'Cycle started');
    syncStatusNotifier.value = const SosSyncStatus(
      phase: SosSyncPhase.connecting,
      message: 'Connecting to server...',
    );

    try {
      final db = DatabaseHelper.instance;

      // Step 1: Mark expired incidents as failed
      await _markExpiredIncidents(db);

      // Step 2: Sync active_offline incidents to backend
      await _syncPendingIncidents(db);

      // Step 3: Sync pending server-side cancellations
      await _syncPendingCancellations(db);

      syncCycleCounter.value++;
    } catch (e) {
      SosLog.warn('SYNC_ENGINE', 'Cycle error: $e');
    } finally {
      _isSyncing = false;
      SosLog.warn('SYNC_ENGINE', 'Cycle completed');
      // Only reset to idle if we're not in a terminal state
      final current = syncStatusNotifier.value.phase;
      if (current != SosSyncPhase.synced &&
          current != SosSyncPhase.failed &&
          current != SosSyncPhase.waitingRetry) {
        syncStatusNotifier.value = SosSyncStatus.idle;
      }
    }
  }

  /// Mark any incidents that have exceeded max retries as failed.
  Future<void> _markExpiredIncidents(DatabaseHelper db) async {
    final expired = await db.getExpiredIncidents(maxRetries);
    for (final incident in expired) {
      SosLog.event(
        incident.uuid,
        'MAX_RETRIES_EXCEEDED',
        'retryCount=${incident.retryCount}',
      );
      await db.atomicUpdateIncident(incident.uuid, status: SosStatus.failed);
    }
  }

  /// Sync all active_offline incidents to the backend.
  Future<void> _syncPendingIncidents(DatabaseHelper db) async {
    final syncable = await db.getSyncableIncidents(maxRetries);

    if (syncable.isEmpty) return;

    SosLog.warn('SYNC_ENGINE', '${syncable.length} incidents to sync');

    for (final incident in syncable) {
      // Double-check: re-read from DB to ensure status hasn't changed
      final fresh = await db.getIncidentByUuid(incident.uuid);
      if (fresh == null || !fresh.status.isSyncable) {
        SosLog.event(
          incident.uuid,
          'SYNC_SKIP',
          'status=${fresh?.status.value ?? "deleted"}',
        );
        continue;
      }

      // Transition to syncing
      final transitioned = await db.atomicUpdateIncident(
        incident.uuid,
        status: SosStatus.syncing,
      );
      if (!transitioned) continue;

      final attemptNum = incident.retryCount + 1;
      SosLog.event(
        incident.uuid,
        'SYNC_START',
        'attempt=$attemptNum/$maxRetries',
      );
      syncStatusNotifier.value = SosSyncStatus(
        phase: SosSyncPhase.syncing,
        attempt: attemptNum,
        maxAttempts: maxRetries,
        message: 'Sending SOS... (attempt $attemptNum/$maxRetries)',
      );

      try {
        final body = <String, dynamic>{
          'type': incident.type,
          'lat': (incident.lat != null && incident.lat != 0.0)
              ? incident.lat
              : 18.5204,
          'lng': (incident.lng != null && incident.lng != 0.0)
              ? incident.lng
              : 73.8567,
          'client_uuid': incident.source == 'mesh_relay'
              ? 'relay_${incident.uuidHash}'
              : incident.uuid,
          'source': incident.source,
          'hop_count': incident.hopCount,
        };

        if (incident.description != null) {
          body['description'] = incident.description;
        }

        final res = await _api!.post('/api/v1/sos', body: body);

        if (res is Map<String, dynamic> && res['id'] != null) {
          final backendId = res['id'].toString();

          // ── Race condition check ──
          // Re-read status: if user cancelled while we were awaiting the API call,
          // don't overwrite the cancellation.
          final postSyncCheck = await db.getIncidentByUuid(incident.uuid);
          if (postSyncCheck != null &&
              postSyncCheck.status == SosStatus.cancelled) {
            SosLog.event(
              incident.uuid,
              'SYNC_CANCELLED_DURING_FLIGHT',
              'User cancelled while API was in-flight. Cancelling on server.',
            );
            // Cancel on server too
            try {
              await _api!.put('/api/v1/sos/$backendId/cancel');
            } catch (_) {}
            continue;
          }

          await db.atomicUpdateIncident(
            incident.uuid,
            status: SosStatus.activeOnline,
            isSynced: true,
            backendId: backendId,
            deliveryChannel: 'internet',
          );

          // Persist the backend ID for UI recovery
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('active_sos_id', backendId);

          // Notify listeners (e.g., UserHomeTab) that sync completed
          syncCompletionNotifier.value = backendId;

          SosLog.event(
            incident.uuid,
            'SYNC_SUCCESS',
            'backendId=$backendId, channel=internet',
          );
          syncStatusNotifier.value = const SosSyncStatus(
            phase: SosSyncPhase.synced,
            message: 'SOS delivered to responders!',
          );
        }
      } catch (e) {
        // Revert to active_offline, increment retry count
        final newRetryCount = incident.retryCount + 1;
        await db.atomicUpdateIncident(
          incident.uuid,
          status: SosStatus.activeOffline,
          retryCount: newRetryCount,
        );
        SosLog.event(
          incident.uuid,
          'SYNC_FAIL',
          'error=$e, retryCount=$newRetryCount/$maxRetries',
        );

        if (newRetryCount >= maxRetries) {
          syncStatusNotifier.value = const SosSyncStatus(
            phase: SosSyncPhase.failed,
            message: 'Could not deliver SOS. Max retries reached.',
          );
        } else {
          // Apply exponential backoff with user-visible countdown
          final delay = _backoffDelay(newRetryCount);
          final delaySec = delay.inSeconds;
          SosLog.event(
            incident.uuid,
            'BACKOFF',
            'waiting ${delay.inMilliseconds}ms',
          );

          // Countdown loop so user sees "Retrying in 4s... 3s... 2s..."
          for (int s = delaySec; s > 0; s--) {
            syncStatusNotifier.value = SosSyncStatus(
              phase: SosSyncPhase.waitingRetry,
              attempt: newRetryCount,
              maxAttempts: maxRetries,
              backoffSeconds: s,
              message:
                  'Retrying in ${s}s... (attempt $newRetryCount/$maxRetries)',
            );
            await Future.delayed(const Duration(seconds: 1));
          }
        }
      }
    }
  }

  /// Sync cancellations to the server for incidents that were:
  /// - Cancelled locally after being synced to the server
  Future<void> _syncPendingCancellations(DatabaseHelper db) async {
    final pendingCancels = await db.getPendingCancellations();

    for (final incident in pendingCancels) {
      if (incident.backendId == null) continue;

      try {
        await _api!.put('/api/v1/sos/${incident.backendId}/cancel');
        await db.markCancellationSynced(incident.uuid);
        SosLog.event(
          incident.uuid,
          'CANCEL_SYNCED',
          'backendId=${incident.backendId}',
        );
      } catch (e) {
        SosLog.event(incident.uuid, 'CANCEL_SYNC_FAIL', 'error=$e');
        // Will retry on next connectivity restoration
      }
    }
  }
}
