class AppUser {
  AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.organizationId,
    this.isActive = true,
    this.bloodGroup,
    this.medicalHistory,
    this.address,
    this.phone,
  });

  final String id;
  final String name;
  final String email;
  final String role;
  final String? organizationId;
  final bool isActive;
  final String? bloodGroup;
  final String? medicalHistory;
  final String? address;
  final String? phone;

  AppUser copyWith({
    String? id,
    String? name,
    String? email,
    String? role,
    String? organizationId,
    bool? isActive,
    String? bloodGroup,
    String? medicalHistory,
    String? address,
    String? phone,
  }) {
    return AppUser(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      role: role ?? this.role,
      organizationId: organizationId ?? this.organizationId,
      isActive: isActive ?? this.isActive,
      bloodGroup: bloodGroup ?? this.bloodGroup,
      medicalHistory: medicalHistory ?? this.medicalHistory,
      address: address ?? this.address,
      phone: phone ?? this.phone,
    );
  }

  bool get isVolunteer => role == 'volunteer';
  bool get isCoordinator => role == 'coordinator';
  bool get isAdmin => role == 'admin';
  bool get isOrganization => role == 'organization';
  bool get isUser => role == 'user';

  factory AppUser.fromSync(Map<String, dynamic> json) {
    return AppUser(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? 'Volunteer').toString(),
      email: (json['email'] ?? '').toString(),
      role: normalizeRole((json['role'] ?? 'volunteer').toString()),
      organizationId: json['organization_id']?.toString(),
      isActive: json['is_active'] is bool ? json['is_active'] as bool : true,
      bloodGroup: json['blood_group']?.toString(),
      medicalHistory: json['medical_history']?.toString(),
      address: json['address']?.toString(),
      phone: json['phone']?.toString(),
    );
  }

  factory AppUser.fromMe(Map<String, dynamic> json) {
    return AppUser(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? json['email'] ?? 'Volunteer').toString(),
      email: (json['email'] ?? '').toString(),
      role: normalizeRole((json['role'] ?? 'volunteer').toString()),
      organizationId: json['organization_id']?.toString(),
      isActive: json['is_active'] is bool ? json['is_active'] as bool : true,
      bloodGroup: json['blood_group']?.toString(),
      medicalHistory: json['medical_history']?.toString(),
      address: json['address']?.toString(),
      phone: json['phone']?.toString(),
    );
  }

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      name: json['name'] as String,
      email: json['email'] as String,
      role: json['role'] as String,
      organizationId: json['organizationId'] as String?,
      isActive: json['isActive'] as bool? ?? true,
      bloodGroup: json['bloodGroup'] as String?,
      medicalHistory: json['medicalHistory'] as String?,
      address: json['address'] as String?,
      phone: json['phone'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'role': role,
      'organizationId': organizationId,
      'isActive': isActive,
      'bloodGroup': bloodGroup,
      'medicalHistory': medicalHistory,
      'address': address,
      'phone': phone,
    };
  }
}

String normalizeRole(String rawRole) {
  const roleMap = {
    'volunteer': 'volunteer',
    'coordinator': 'coordinator',
    'admin': 'admin',
    'organization': 'organization',
    'org:user': 'volunteer',
    'org:volunteer': 'volunteer',
    'org:volunteer_head': 'coordinator',
    'org:coordinator': 'coordinator',
    'org:admin': 'admin',
    'org:organization': 'organization',
    'user': 'user',
  };

  return roleMap[rawRole] ??
      'user'; // Default to user if unknown for safety? Actually volunteer is safer for legacy, but let's stick to map.
}

double? parseLat(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

double? parseLng(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
