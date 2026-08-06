import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/beacon.dart';
import '../../models/item.dart';
import '../../models/store_map.dart';
import '../../services/navigation_controller.dart';
import '../widgets/item_search_delegate.dart';
import '../widgets/map_painter.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.controller});

  final NavigationController controller;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  StreamSubscription<String>? _scanErrorSub;

  @override
  void initState() {
    super.initState();
    widget.controller.start();
    _scanErrorSub = widget.controller.bleScanner.errors.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
      );
    });
  }

  @override
  void dispose() {
    _scanErrorSub?.cancel();
    super.dispose();
  }

  Future<void> _openSearch(BuildContext context) async {
    final storeMap = widget.controller.storeMap;
    final item = await showSearch(context: context, delegate: ItemSearchDelegate(storeMap));
    if (item != null) _selectItem(item);
  }

  void _selectItem(Item item) {
    final beacon = widget.controller.storeMap.beaconById(item.beaconId);
    if (beacon != null) widget.controller.setDestination(beacon);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final storeMap = controller.storeMap;
    final topItems = storeMap.items.take(4).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Indoor Navigation'),
        actions: [
          PopupMenuButton<Beacon>(
            icon: const Icon(Icons.place_outlined),
            tooltip: 'Choose destination',
            onSelected: controller.setDestination,
            itemBuilder: (context) => storeMap.beacons
                .map((b) => PopupMenuItem(value: b, child: Text(b.name)))
                .toList(),
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _SearchBar(onTap: () => _openSearch(context)),
                ),
                if (topItems.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: Text('Popular items', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _PopularItemsGrid(
                      storeMap: storeMap,
                      items: topItems,
                      onSelected: _selectItem,
                    ),
                  ),
                ],
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text('Map', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                _StatusBar(controller: controller),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: AspectRatio(
                    aspectRatio: storeMap.mapWidth / storeMap.mapHeight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        SvgPicture.asset(
                          storeMap.mapAsset,
                          fit: BoxFit.contain,
                          placeholderBuilder: (context) => const Center(child: CircularProgressIndicator()),
                          errorBuilder: (context, error, stackTrace) => Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                'Failed to load ${storeMap.mapAsset}:\n$error',
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          ),
                          semanticsLabel: 'Store map',
                        ),
                        CustomPaint(
                          painter: MapPainter(
                            mapSize: Size(storeMap.mapWidth, storeMap.mapHeight),
                            path: controller.currentPath,
                            userLocation: controller.currentBeacon,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _DirectionsList(controller: controller),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.search),
              SizedBox(width: 12),
              Text('Search for an item...'),
            ],
          ),
        ),
      ),
    );
  }
}

class _PopularItemsGrid extends StatelessWidget {
  const _PopularItemsGrid({required this.storeMap, required this.items, required this.onSelected});

  final StoreMap storeMap;
  final List<Item> items;
  final ValueChanged<Item> onSelected;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 2.4,
      children: items.map((item) {
        final beacon = storeMap.beaconById(item.beaconId);
        return Card(
          margin: EdgeInsets.zero,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onSelected(item),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.inventory_2_outlined, size: 20),
                  const SizedBox(height: 6),
                  Text(item.name, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (beacon != null)
                    Text(
                      beacon.name,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.controller});

  final NavigationController controller;

  @override
  Widget build(BuildContext context) {
    final here = controller.currentBeacon?.name ?? 'Locating…';
    final there = controller.destinationBeacon?.name ?? 'Pick a destination';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text('You are near: $here  →  Going to: $there'),
    );
  }
}

class _DirectionsList extends StatelessWidget {
  const _DirectionsList({required this.controller});

  final NavigationController controller;

  @override
  Widget build(BuildContext context) {
    final path = controller.currentPath;
    if (path.length < 2) return const SizedBox.shrink();

    return SizedBox(
      height: 120,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: path.length,
        separatorBuilder: (_, __) => const Icon(Icons.arrow_forward, size: 16),
        itemBuilder: (context, i) => Chip(label: Text(path[i].name)),
      ),
    );
  }
}
