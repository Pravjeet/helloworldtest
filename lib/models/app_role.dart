/// A role belonging to one college: `colleges/{collegeId}/roles/{id}`.
class AppRole {
  final String id;
  final String name;
  final String description;
  final Set<String> permissions;

  /// System roles cannot be deleted or renamed (currently only SuperAdmin).
  final bool isSystem;

  const AppRole({
    required this.id,
    required this.name,
    this.description = '',
    this.permissions = const {},
    this.isSystem = false,
  });

  factory AppRole.fromMap(String id, Map<String, dynamic> m) => AppRole(
    id: id,
    name: m['name'] as String? ?? id,
    description: m['description'] as String? ?? '',
    permissions: ((m['permissions'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet(),
    isSystem: m['isSystem'] as bool? ?? false,
  );

  Map<String, dynamic> toMap() => {
    'name': name,
    'description': description,
    'permissions': permissions.toList(),
    'isSystem': isSystem,
  };

  AppRole copyWith({
    String? name,
    String? description,
    Set<String>? permissions,
  }) => AppRole(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    permissions: permissions ?? this.permissions,
    isSystem: isSystem,
  );
}
