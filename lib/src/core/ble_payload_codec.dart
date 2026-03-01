class BleBeacon {
  final String type;
  final String? description;
  final int? uuidHash;

  BleBeacon({required this.type, this.description, this.uuidHash});

  String get incidentTypeString => type;
}

/// Mesh SOS packet sent over P2P transport (Nearby Connections on Android).
class MeshSosPacket {
  MeshSosPacket({
    required this.uuid,
    required this.type,
    this.description,
    this.lat,
    this.lng,
    this.hopCount = 0,
    this.reporterName,
    this.reporterPhone,
    this.familyContacts = const [],
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String uuid;
  final String type;
  final String? description;
  final double? lat;
  final double? lng;
  final int hopCount;
  final String? reporterName;
  final String? reporterPhone;
  final List<Map<String, dynamic>> familyContacts;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'v': 2,
    'uuid': uuid,
    'type': type,
    'description': description,
    'lat': lat,
    'lng': lng,
    'hop': hopCount,
    'rn': reporterName,
    'rp': reporterPhone,
    'fc': familyContacts,
    'ts': createdAt.toIso8601String(),
  };

  factory MeshSosPacket.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> parseFc(dynamic raw) {
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      return [];
    }

    return MeshSosPacket(
      uuid: (json['uuid'] ?? '').toString(),
      type: (json['type'] ?? 'Emergency').toString(),
      description: (json['description'] as String?),
      lat: (json['lat'] is num) ? (json['lat'] as num).toDouble() : null,
      lng: (json['lng'] is num) ? (json['lng'] as num).toDouble() : null,
      hopCount: (json['hop'] is num) ? (json['hop'] as num).toInt() : 0,
      reporterName: json['rn']?.toString(),
      reporterPhone: json['rp']?.toString(),
      familyContacts: parseFc(json['fc']),
      createdAt: DateTime.tryParse((json['ts'] ?? '').toString()),
    );
  }
}

/// Stable 32-bit FNV-1a hash for identifiers (cross-device consistent).
int fnv1a32(String input) {
  const int fnvPrime = 0x01000193;
  int hash = 0x811C9DC5;
  for (final codeUnit in input.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * fnvPrime) & 0xFFFFFFFF;
  }
  // Convert to signed 32-bit int range for SQLite integer compatibility.
  if (hash & 0x80000000 != 0) {
    return -((~hash + 1) & 0xFFFFFFFF);
  }
  return hash;
}
