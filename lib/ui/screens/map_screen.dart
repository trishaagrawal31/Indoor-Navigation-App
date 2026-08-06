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
  StreamSubscription<String>? _motionErrorSub;

  @override
  void initState() {
    super.initState();
    widget.controller.start();
    _scanErrorSub = widget.controller.bleScanner.errors.listen(_showError);
    _motionErrorSub = widget.controller.motionService.errors.listen(_showError);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  @override
  void dispose() {
    _scanErrorSub?.cancel();
    _motionErrorSub?.cancel();
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
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
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
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Text(
                  'Where do you want to go?',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                _SearchBar(onTap: () => _openSearch(context)),
                if (topItems.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  const _SectionHeader(icon: Icons.star_outline, label: 'Popular items'),
                  const SizedBox(height: 12),
                  _PopularItemsGrid(storeMap: storeMap, items: topItems, onSelected: _selectItem),
                ],
                const SizedBox(height: 28),
                _SectionHeader(
                  icon: Icons.map_outlined,
                  label: 'Live map',
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Clear route',
                    visualDensity: VisualDensity.compact,
                    onPressed: controller.clearDestination,
                  ),
                ),
                const SizedBox(height: 12),
                _StatusCard(controller: controller),
                const SizedBox(height: 12),
                _MapFrame(controller: controller, storeMap: storeMap),
                _DirectionsList(controller: controller),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.label, this.trailing});

  final IconData icon;
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.search, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Text(
                'Search for an item…',
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 15),
              ),
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
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        mainAxisExtent: 76,
      ),
      children: items.map((item) {
        final beacon = storeMap.beaconById(item.beaconId);
        return _ItemCard(item: item, locationName: beacon?.name, onTap: () => onSelected(item));
      }).toList(),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item, required this.locationName, required this.onTap});

  final Item item;
  final String? locationName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: colorScheme.primaryContainer, shape: BoxShape.circle),
                child: Icon(Icons.inventory_2_outlined, size: 20, color: colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (locationName != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          locationName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final NavigationController controller;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final here = controller.currentBeacon?.name ?? 'Locating…';
    final there = controller.destinationBeacon?.name;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.my_location, size: 16, color: colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'You are near  ', style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                      TextSpan(text: here, style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.flag_outlined, size: 16, color: colorScheme.secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'Going to  ', style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                      TextSpan(
                        text: there ?? 'Pick a destination',
                        style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (controller.currentDistanceMeters != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.straighten, size: 16, color: colorScheme.tertiary),
                const SizedBox(width: 8),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'Distance  ', style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                      TextSpan(
                        text: _formatDistance(controller.currentDistanceMeters!),
                        style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }
}

class _MapFrame extends StatelessWidget {
  const _MapFrame({required this.controller, required this.storeMap});

  final NavigationController controller;
  final StoreMap storeMap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: colorScheme.surfaceContainerLow,
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
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
                livePosition: controller.liveUserPosition,
                headingDegrees: controller.headingDegrees,
                mapNorthOffsetDegrees: storeMap.mapNorthOffsetDegrees,
              ),
            ),
          ],
        ),
      ),
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
      height: 44,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        scrollDirection: Axis.horizontal,
        itemCount: path.length,
        separatorBuilder: (_, __) => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Icon(Icons.arrow_forward, size: 14),
        ),
        itemBuilder: (context, i) => Chip(
          label: Text(path[i].name),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
