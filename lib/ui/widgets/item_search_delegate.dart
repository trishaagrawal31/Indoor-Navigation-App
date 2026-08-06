import 'package:flutter/material.dart';

import '../../models/item.dart';
import '../../models/store_map.dart';

/// Search-as-you-type over [StoreMap.items]. Returns the selected [Item], or
/// null if the user backs out without picking one.
class ItemSearchDelegate extends SearchDelegate<Item?> {
  ItemSearchDelegate(this.storeMap);

  final StoreMap storeMap;

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _resultsList(context);

  @override
  Widget buildSuggestions(BuildContext context) => _resultsList(context);

  Widget _resultsList(BuildContext context) {
    if (query.isEmpty) {
      return const Center(child: Text('Search for an item to find its room'));
    }
    final results = storeMap.searchItems(query);
    if (results.isEmpty) {
      return const Center(child: Text('No items found'));
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final item = results[index];
        final beacon = storeMap.beaconById(item.beaconId);
        return ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(item.name),
          subtitle: Text(beacon?.name ?? 'Unknown location'),
          onTap: () => close(context, item),
        );
      },
    );
  }
}
