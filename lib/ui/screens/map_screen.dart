import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/beacon.dart';
import '../../services/navigation_controller.dart';
import '../widgets/map_painter.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.controller});

  final NavigationController controller;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.start();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final storeMap = controller.storeMap;

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
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return Column(
            children: [
              _StatusBar(controller: controller),
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: storeMap.mapWidth / storeMap.mapHeight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        SvgPicture.asset(storeMap.mapAsset, fit: BoxFit.contain),
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
              ),
              _DirectionsList(controller: controller),
            ],
          );
        },
      ),
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
      padding: const EdgeInsets.all(12),
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
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        itemCount: path.length,
        separatorBuilder: (_, __) => const Icon(Icons.arrow_forward, size: 16),
        itemBuilder: (context, i) => Chip(label: Text(path[i].name)),
      ),
    );
  }
}
