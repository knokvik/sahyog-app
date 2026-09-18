class BleBeacon {
  final String type;
  final String? description;
  final int? uuidHash;

  BleBeacon({required this.type, this.description, this.uuidHash});

  String get incidentTypeString => type;
}
