class TrustedContact {
  final String id;
  final String name;
  final String phone;
  final String? email;
  final String? relationship;
  final bool isPrimary;

  TrustedContact({
    required this.id,
    required this.name,
    required this.phone,
    this.email,
    this.relationship,
    this.isPrimary = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'phone': phone,
      'email': email,
      'relationship': relationship,
      'isPrimary': isPrimary,
    };
  }

  factory TrustedContact.fromJson(Map<String, dynamic> json) {
    return TrustedContact(
      id: json['id'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String,
      email: json['email'] as String?,
      relationship: json['relationship'] as String?,
      isPrimary: json['isPrimary'] as bool? ?? false,
    );
  }

  TrustedContact copyWith({
    String? id,
    String? name,
    String? phone,
    String? email,
    String? relationship,
    bool? isPrimary,
  }) {
    return TrustedContact(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      relationship: relationship ?? this.relationship,
      isPrimary: isPrimary ?? this.isPrimary,
    );
  }
}
