/// A searchable item and the beacon nearest to where it's kept.
class Item {
  final String name;
  final String beaconId;

  const Item({required this.name, required this.beaconId});

  factory Item.fromJson(Map<String, dynamic> json) {
    return Item(
      name: json['name'] as String,
      beaconId: json['beaconId'] as String,
    );
  }
}
