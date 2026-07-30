import 'dart:ui';

/// A physical BLE beacon mounted at an aisle end, plus its position on the store map.
class Beacon {
  final String id;
  final String bleId;
  final String name;
  final Offset position;

  const Beacon({
    required this.id,
    required this.bleId,
    required this.name,
    required this.position,
  });

  factory Beacon.fromJson(Map<String, dynamic> json) {
    return Beacon(
      id: json['id'] as String,
      bleId: json['bleId'] as String,
      name: json['name'] as String,
      position: Offset(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
      ),
    );
  }
}
