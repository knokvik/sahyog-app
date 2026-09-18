import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'sos_state_machine.dart';

/// SQLite database helper — single source of truth for offline SOS data.
///
/// Schema version history:
///   v1: local_incidents (legacy)
///   v2: local_incidents + retry_count
///   v3: sos_incidents (UUID PK, full state machine)
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('sahyog_offline.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 4,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // Legacy table (kept for migration safety)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_incidents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        reporter_id TEXT NOT NULL,
        location_lat REAL,
        location_lng REAL,
        media_paths TEXT,
        captured_at TEXT NOT NULL,
        status TEXT DEFAULT 'pending_sync',
        retry_count INTEGER DEFAULT 0
      )
    ''');

    // New production-grade SOS table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sos_incidents (
        uuid TEXT PRIMARY KEY,
        reporter_id TEXT NOT NULL,
        lat REAL,
        lng REAL,
        type TEXT DEFAULT 'Emergency',
        description TEXT,
        status TEXT NOT NULL DEFAULT 'activating',
        is_synced INTEGER DEFAULT 0,
        retry_count INTEGER DEFAULT 0,
        delivery_channel TEXT,
        backend_id TEXT,
        source TEXT DEFAULT 'direct',
        hop_count INTEGER DEFAULT 0,
        uuid_hash INTEGER,
        relay_device_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      try {
        await db.execute(
          'ALTER TABLE local_incidents ADD COLUMN retry_count INTEGER DEFAULT 0',
        );
      } catch (_) {}
    }
    if (oldVersion < 3) {
      // Create the new sos_incidents table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS sos_incidents (
          uuid TEXT PRIMARY KEY,
          reporter_id TEXT NOT NULL,
          lat REAL,
          lng REAL,
          type TEXT DEFAULT 'Emergency',
          description TEXT,
          status TEXT NOT NULL DEFAULT 'activating',
          is_synced INTEGER DEFAULT 0,
          retry_count INTEGER DEFAULT 0,
          delivery_channel TEXT,
          backend_id TEXT,
          source TEXT DEFAULT 'direct',
          hop_count INTEGER DEFAULT 0,
          uuid_hash INTEGER,
          relay_device_id TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 4) {
      // Add BLE mesh columns to existing sos_incidents table
      try {
        await db.execute(
          "ALTER TABLE sos_incidents ADD COLUMN source TEXT DEFAULT 'direct'",
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE sos_incidents ADD COLUMN hop_count INTEGER DEFAULT 0',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE sos_incidents ADD COLUMN uuid_hash INTEGER',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE sos_incidents ADD COLUMN relay_device_id TEXT',
        );
      } catch (_) {}
    }
  }

  // ─────────────────────────────────────────────────────────────
  // SOS Incident Operations (New state-machine-based API)
  // ─────────────────────────────────────────────────────────────

  /// Insert a new SOS incident. UUID is the primary key.
  Future<void> insertSosIncident(SosIncident incident) async {
    final db = await database;
    await db.insert(
      'sos_incidents',
      incident.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    SosLog.event(
      incident.uuid,
      'SQLITE_WRITE',
      'status=${incident.status.value}',
    );
  }

  /// Atomic state transition — updates status, retry_count, synced flag, etc.
  /// within a single transaction. Returns true if the update was applied.
  Future<bool> atomicUpdateIncident(
    String uuid, {
    SosStatus? status,
    bool? isSynced,
    int? retryCount,
    String? deliveryChannel,
    String? backendId,
  }) async {
    final db = await database;

    return await db.transaction((txn) async {
      // Read current state inside the transaction for consistency
      final rows = await txn.query(
        'sos_incidents',
        where: 'uuid = ?',
        whereArgs: [uuid],
      );

      if (rows.isEmpty) {
        SosLog.warn('ATOMIC_UPDATE', 'Incident $uuid not found in SQLite');
        return false;
      }

      final current = SosIncident.fromMap(rows.first);

      // Validate state transition if status is being changed
      if (status != null && status != current.status) {
        if (!SosStateMachine.canTransition(current.status, status)) {
          SosLog.warn(
            'ATOMIC_UPDATE',
            'Forbidden: ${current.status.value} → ${status.value} for $uuid',
          );
          return false;
        }
        SosLog.event(
          uuid,
          'STATUS_CHANGE',
          '${current.status.value} → ${status.value}',
        );
      }

      final updates = <String, dynamic>{
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (status != null) updates['status'] = status.value;
      if (isSynced != null) updates['is_synced'] = isSynced ? 1 : 0;
      if (retryCount != null) updates['retry_count'] = retryCount;
      if (deliveryChannel != null)
        updates['delivery_channel'] = deliveryChannel;
      if (backendId != null) updates['backend_id'] = backendId;

      await txn.update(
        'sos_incidents',
        updates,
        where: 'uuid = ?',
        whereArgs: [uuid],
      );

      return true;
    });
  }

  /// Get all incidents that are eligible for syncing:
  /// status = active_offline AND retry_count < maxRetries
  Future<List<SosIncident>> getSyncableIncidents(int maxRetries) async {
    final db = await database;
    final rows = await db.query(
      'sos_incidents',
      where: 'status = ? AND retry_count < ?',
      whereArgs: [SosStatus.activeOffline.value, maxRetries],
      orderBy: 'created_at ASC',
    );
    return rows.map((r) => SosIncident.fromMap(r)).toList();
  }

  /// Get incidents that were cancelled offline and need server-side cancellation.
  /// These have: status = cancelled, is_synced = true (were synced), backend_id != null
  /// We track a separate flag isn't needed — if status=cancelled and backend_id is set,
  /// we know the server needs to be notified.
  Future<List<SosIncident>> getPendingCancellations() async {
    final db = await database;
    final rows = await db.query(
      'sos_incidents',
      where:
          'status = ? AND backend_id IS NOT NULL AND delivery_channel IS NOT NULL',
      whereArgs: [SosStatus.cancelled.value],
    );
    // Filter: only those that haven't had their cancellation acknowledged
    // We use delivery_channel as a proxy: once cancelled on server, we clear it
    return rows.map((r) => SosIncident.fromMap(r)).toList();
  }

  /// Mark a cancelled incident as having been cancelled on the server too.
  Future<void> markCancellationSynced(String uuid) async {
    final db = await database;
    await db.update(
      'sos_incidents',
      {
        'delivery_channel': null,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'uuid = ? AND status = ?',
      whereArgs: [uuid, SosStatus.cancelled.value],
    );
  }

  /// Get the most recent active SOS for a given reporter.
  Future<SosIncident?> getActiveIncident(String reporterId) async {
    final db = await database;
    final activeStatuses = [
      SosStatus.activating.value,
      SosStatus.activeOffline.value,
      SosStatus.syncing.value,
      SosStatus.activeOnline.value,
      SosStatus.acknowledged.value,
    ];
    final placeholders = activeStatuses.map((_) => '?').join(',');
    final rows = await db.query(
      'sos_incidents',
      where: 'reporter_id = ? AND status IN ($placeholders)',
      whereArgs: [reporterId, ...activeStatuses],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SosIncident.fromMap(rows.first);
  }

  /// Get a single incident by UUID.
  Future<SosIncident?> getIncidentByUuid(String uuid) async {
    final db = await database;
    final rows = await db.query(
      'sos_incidents',
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
    if (rows.isEmpty) return null;
    return SosIncident.fromMap(rows.first);
  }

  /// Get incidents that have exceeded max retries and need to be marked failed.
  Future<List<SosIncident>> getExpiredIncidents(int maxRetries) async {
    final db = await database;
    final rows = await db.query(
      'sos_incidents',
      where: 'status = ? AND retry_count >= ?',
      whereArgs: [SosStatus.activeOffline.value, maxRetries],
    );
    return rows.map((r) => SosIncident.fromMap(r)).toList();
  }

  // ─────────────────────────────────────────────────────────────
  // BLE Mesh Relay Operations
  // ─────────────────────────────────────────────────────────────

  /// Check if a relay record with this UUID hash already exists.
  Future<SosIncident?> getRelayByUuidHash(int uuidHash) async {
    final db = await database;
    final rows = await db.query(
      'sos_incidents',
      where: 'uuid_hash = ?',
      whereArgs: [uuidHash],
    );
    if (rows.isEmpty) return null;
    return SosIncident.fromMap(rows.first);
  }

  /// Save a mesh relay record. The UUID is generated by the relay device
  /// but the uuid_hash maps back to the victim's original SOS.
  Future<void> saveMeshRelay(SosIncident relay) async {
    final db = await database;
    await db.insert(
      'sos_incidents',
      relay.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Get all relay records that need to be synced to backend.
  Future<List<SosIncident>> getSyncableRelays(int maxRetries) async {
    final db = await database;
    final rows = await db.query(
      'sos_incidents',
      where: 'status = ? AND source = ? AND retry_count < ?',
      whereArgs: [SosStatus.activeOffline.value, 'mesh_relay', maxRetries],
      orderBy: 'created_at ASC',
    );
    return rows.map((r) => SosIncident.fromMap(r)).toList();
  }

  // ─────────────────────────────────────────────────────────────
  // Legacy Operations (kept for backward compat, will be removed)
  // ─────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getPendingIncidents() async {
    final db = await database;
    return db.query(
      'local_incidents',
      where: 'status = ?',
      whereArgs: ['pending_sync'],
    );
  }

  Future<int> markIncidentSynced(int id) async {
    final db = await database;
    return db.update(
      'local_incidents',
      {'status': 'synced'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> incrementRetryCount(int id) async {
    final db = await database;
    return db.rawUpdate(
      'UPDATE local_incidents SET retry_count = retry_count + 1 WHERE id = ?',
      [id],
    );
  }

  Future<int> markIncidentFailed(int id) async {
    final db = await database;
    return db.update(
      'local_incidents',
      {'status': 'failed_sync'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteAllPendingIncidents() async {
    final db = await database;
    return db.delete(
      'local_incidents',
      where: 'status = ?',
      whereArgs: ['pending_sync'],
    );
  }

  Future<void> close() async {
    final db = await database;
    db.close();
    _database = null;
  }
}
