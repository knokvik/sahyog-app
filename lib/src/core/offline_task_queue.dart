import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import 'api_client.dart';

/// Offline-first task action queue.
///
/// When a volunteer completes, accepts, or updates a task while offline,
/// the action is saved to a local SQLite queue. When connectivity is
/// restored, the queue automatically drains and syncs to the backend.
class OfflineTaskQueue {
  static final OfflineTaskQueue instance = OfflineTaskQueue._();
  OfflineTaskQueue._();

  Database? _db;
  ApiClient? _api;
  StreamSubscription? _connectivitySub;
  Timer? _retryTimer;
  bool _isSyncing = false;

  /// How many times we retry a queued action before marking it failed.
  static const int maxRetries = 5;

  /// Notifier for the UI: number of pending items in the queue.
  final ValueNotifier<int> pendingCount = ValueNotifier(0);

  /// Initialize the queue. Call once at app startup after login.
  Future<void> init(ApiClient api) async {
    _api = api;
    _db = await _openDb();
    await _refreshCount();

    // Listen for connectivity changes
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      // results is List<ConnectivityResult>
      final hasNet = results.any((r) => r != ConnectivityResult.none);
      if (hasNet) {
        syncAll(); // drain queue when we get internet
      }
    });

    // Also retry every 60 seconds as a safety net
    _retryTimer = Timer.periodic(const Duration(seconds: 60), (_) => syncAll());
  }

  Future<Database> _openDb() async {
    final dbPath = await getDatabasesPath();
    final p = join(dbPath, 'sahyog_task_queue.db');
    return openDatabase(
      p,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS task_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            action TEXT NOT NULL,
            payload TEXT NOT NULL,
            status TEXT DEFAULT 'pending',
            retry_count INTEGER DEFAULT 0,
            created_at TEXT NOT NULL,
            last_attempt TEXT
          )
        ''');
      },
    );
  }

  /// Enqueue a task action. Returns immediately.
  /// [action] is one of: 'update_status', 'upload_proof', 'vote_completion'
  /// [payload] is a JSON-serializable map with the request body.
  Future<void> enqueue({
    required String taskId,
    required String action,
    required Map<String, dynamic> payload,
  }) async {
    final db = _db;
    if (db == null) return;

    await db.insert('task_queue', {
      'task_id': taskId,
      'action': action,
      'payload': jsonEncode(payload),
      'status': 'pending',
      'retry_count': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
    await _refreshCount();

    // Immediately try to sync in case we're online
    syncAll();
  }

  /// Attempt to sync all pending items in FIFO order.
  Future<void> syncAll() async {
    if (_isSyncing || _api == null || _db == null) return;
    _isSyncing = true;

    try {
      final rows = await _db!.query(
        'task_queue',
        where: 'status = ? AND retry_count < ?',
        whereArgs: ['pending', maxRetries],
        orderBy: 'created_at ASC',
      );

      for (final row in rows) {
        final id = row['id'] as int;
        final taskId = row['task_id'] as String;
        final action = row['action'] as String;
        final payload =
            jsonDecode(row['payload'] as String) as Map<String, dynamic>;

        try {
          await _executeAction(taskId, action, payload);
          // Success — mark as synced
          await _db!.update(
            'task_queue',
            {
              'status': 'synced',
              'last_attempt': DateTime.now().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [id],
          );
        } catch (e) {
          // Failed — increment retry
          await _db!.update(
            'task_queue',
            {
              'retry_count': (row['retry_count'] as int) + 1,
              'last_attempt': DateTime.now().toIso8601String(),
              'status': ((row['retry_count'] as int) + 1 >= maxRetries)
                  ? 'failed'
                  : 'pending',
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          debugPrint('[OfflineTaskQueue] Sync failed for $taskId: $e');
        }
      }
    } finally {
      _isSyncing = false;
      await _refreshCount();
    }
  }

  Future<void> _executeAction(
    String taskId,
    String action,
    Map<String, dynamic> payload,
  ) async {
    switch (action) {
      case 'update_status':
        await _api!.patch('/api/v1/tasks/$taskId/status', body: payload);
        break;
      case 'vote_completion':
        await _api!.post(
          '/api/v1/tasks/$taskId/vote-completion',
          body: payload,
        );
        break;
      default:
        throw Exception('Unknown queued action: $action');
    }
  }

  Future<void> _refreshCount() async {
    if (_db == null) return;
    final result = await _db!.rawQuery(
      "SELECT COUNT(*) as cnt FROM task_queue WHERE status = 'pending'",
    );
    pendingCount.value = Sqflite.firstIntValue(result) ?? 0;
  }

  /// Check if we are currently offline.
  Future<bool> get isOffline async {
    final results = await Connectivity().checkConnectivity();
    return results.every((r) => r == ConnectivityResult.none);
  }

  void dispose() {
    _connectivitySub?.cancel();
    _retryTimer?.cancel();
    _db?.close();
    _db = null;
  }
}
