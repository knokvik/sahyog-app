/// Deterministic state machine for Manual SOS lifecycle.
///
/// States:
///   idle → activating → active_offline → syncing → active_online → acknowledged → resolved
///   Any active state → cancelled (terminal)
///   active_offline → failed (terminal, after max retries)
library;

import 'package:uuid/uuid.dart';

// ─────────────────────────────────────────────────────────────
// SOS Status Enum
// ─────────────────────────────────────────────────────────────

enum SosStatus {
  idle,
  activating,
  activeOffline,
  syncing,
  activeOnline,
  acknowledged,
  cancelled,
  resolved,
  failed;

  String get value {
    switch (this) {
      case SosStatus.idle:
        return 'idle';
      case SosStatus.activating:
        return 'activating';
      case SosStatus.activeOffline:
        return 'active_offline';
      case SosStatus.syncing:
        return 'syncing';
      case SosStatus.activeOnline:
        return 'active_online';
      case SosStatus.acknowledged:
        return 'acknowledged';
      case SosStatus.cancelled:
        return 'cancelled';
      case SosStatus.resolved:
        return 'resolved';
      case SosStatus.failed:
        return 'failed';
    }
  }

  static SosStatus fromString(String s) {
    switch (s) {
      case 'idle':
        return SosStatus.idle;
      case 'activating':
        return SosStatus.activating;
      case 'active_offline':
        return SosStatus.activeOffline;
      case 'syncing':
        return SosStatus.syncing;
      case 'active_online':
        return SosStatus.activeOnline;
      case 'acknowledged':
        return SosStatus.acknowledged;
      case 'cancelled':
        return SosStatus.cancelled;
      case 'resolved':
        return SosStatus.resolved;
      case 'failed':
        return SosStatus.failed;
      default:
        return SosStatus.idle;
    }
  }

  /// Terminal states cannot transition to anything.
  bool get isTerminal =>
      this == SosStatus.cancelled ||
      this == SosStatus.resolved ||
      this == SosStatus.failed;

  /// Active states represent a live, unresolved SOS.
  bool get isActive =>
      this == SosStatus.activating ||
      this == SosStatus.activeOffline ||
      this == SosStatus.syncing ||
      this == SosStatus.activeOnline ||
      this == SosStatus.acknowledged;

  /// Can this status be synced to the backend?
  bool get isSyncable => this == SosStatus.activeOffline;

  /// Should BLE advertiser be running?
  bool get isBleAdvertisable =>
      this == SosStatus.activeOffline ||
      this == SosStatus.syncing ||
      this == SosStatus.activeOnline;
}

// ─────────────────────────────────────────────────────────────
// SOS Incident Model
// ─────────────────────────────────────────────────────────────

class SosIncident {
  SosIncident({
    String? uuid,
    required this.reporterId,
    this.lat,
    this.lng,
    this.type = 'Emergency',
    this.description,
    this.status = SosStatus.activating,
    this.isSynced = false,
    this.retryCount = 0,
    this.deliveryChannel,
    this.backendId,
    this.source = 'direct',
    this.hopCount = 0,
    this.uuidHash,
    this.relayDeviceId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : uuid = uuid ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String uuid;
  final String reporterId;
  final double? lat;
  final double? lng;
  final String type;
  final String? description;
  final SosStatus status;
  final bool isSynced;
  final int retryCount;
  final String? deliveryChannel;
  final String? backendId;
  final String source;
  final int hopCount;
  final int? uuidHash;
  final String? relayDeviceId;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Create a copy with updated fields.
  SosIncident copyWith({
    SosStatus? status,
    bool? isSynced,
    int? retryCount,
    String? deliveryChannel,
    String? backendId,
    double? lat,
    double? lng,
    String? source,
    int? hopCount,
    int? uuidHash,
    String? relayDeviceId,
  }) {
    return SosIncident(
      uuid: uuid,
      reporterId: reporterId,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      type: type,
      description: description,
      status: status ?? this.status,
      isSynced: isSynced ?? this.isSynced,
      retryCount: retryCount ?? this.retryCount,
      deliveryChannel: deliveryChannel ?? this.deliveryChannel,
      backendId: backendId ?? this.backendId,
      source: source ?? this.source,
      hopCount: hopCount ?? this.hopCount,
      uuidHash: uuidHash ?? this.uuidHash,
      relayDeviceId: relayDeviceId ?? this.relayDeviceId,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  /// Serialize to SQLite row.
  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'reporter_id': reporterId,
      'lat': lat,
      'lng': lng,
      'type': type,
      'description': description,
      'status': status.value,
      'is_synced': isSynced ? 1 : 0,
      'retry_count': retryCount,
      'delivery_channel': deliveryChannel,
      'backend_id': backendId,
      'source': source,
      'hop_count': hopCount,
      'uuid_hash': uuidHash,
      'relay_device_id': relayDeviceId,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  /// Deserialize from SQLite row.
  factory SosIncident.fromMap(Map<String, dynamic> map) {
    return SosIncident(
      uuid: map['uuid'] as String,
      reporterId: map['reporter_id'] as String,
      lat: map['lat'] as double?,
      lng: map['lng'] as double?,
      type: (map['type'] as String?) ?? 'Emergency',
      description: map['description'] as String?,
      status: SosStatus.fromString((map['status'] as String?) ?? 'idle'),
      isSynced: (map['is_synced'] as int?) == 1,
      retryCount: (map['retry_count'] as int?) ?? 0,
      deliveryChannel: map['delivery_channel'] as String?,
      backendId: map['backend_id'] as String?,
      source: (map['source'] as String?) ?? 'direct',
      hopCount: (map['hop_count'] as int?) ?? 0,
      uuidHash: map['uuid_hash'] as int?,
      relayDeviceId: map['relay_device_id'] as String?,
      createdAt:
          DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(map['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// State Transition Validator
// ─────────────────────────────────────────────────────────────

class SosStateMachine {
  SosStateMachine._();

  /// Allowed transitions map.
  static const Map<SosStatus, Set<SosStatus>> _transitions = {
    SosStatus.idle: {SosStatus.activating},
    SosStatus.activating: {SosStatus.activeOffline, SosStatus.cancelled},
    SosStatus.activeOffline: {
      SosStatus.syncing,
      SosStatus.cancelled,
      SosStatus.failed,
      SosStatus.acknowledged, // BLE ACK received while offline
    },
    SosStatus.syncing: {
      SosStatus.activeOnline,
      SosStatus.activeOffline, // Revert on sync failure
      SosStatus.cancelled,
    },
    SosStatus.activeOnline: {
      SosStatus.acknowledged,
      SosStatus.cancelled,
      SosStatus.resolved,
    },
    SosStatus.acknowledged: {SosStatus.resolved, SosStatus.cancelled},
    // Terminal states — no outbound transitions
    SosStatus.cancelled: {},
    SosStatus.resolved: {},
    SosStatus.failed: {},
  };

  /// Check whether transitioning from [from] to [to] is allowed.
  static bool canTransition(SosStatus from, SosStatus to) {
    return _transitions[from]?.contains(to) ?? false;
  }

  /// Attempt a state transition. Returns the new status if allowed,
  /// or null if the transition is forbidden.
  static SosStatus? tryTransition(SosStatus from, SosStatus to) {
    if (canTransition(from, to)) return to;
    SosLog.warn(
      'FORBIDDEN_TRANSITION',
      'Cannot transition from ${from.value} to ${to.value}',
    );
    return null;
  }
}

// ─────────────────────────────────────────────────────────────
// Structured Logging
// ─────────────────────────────────────────────────────────────

class SosLog {
  SosLog._();

  static void event(String uuid, String event, [String? detail]) {
    final msg = '[SOS:$uuid] $event${detail != null ? ' — $detail' : ''}';
    // ignore: avoid_print
    print(msg);
  }

  static void warn(String event, String detail) {
    // ignore: avoid_print
    print('[SOS:WARNING] $event — $detail');
  }
}
