import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/scope.dart';

/// Cover thumbnail (pre-generated 256 px JPEG, decoded at display size).
class CoverThumb extends StatelessWidget {
  final String? hash;
  final double size;
  final double radius;
  const CoverThumb({super.key, required this.hash, required this.size, this.radius = 4});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(radius)),
      child: Icon(Icons.music_note, size: size * 0.45, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
    );
    final h = hash;
    if (h == null) return placeholder;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.file(
        File(AppScope.read(context).thumbPath(h)),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * dpr).round().clamp(32, 256),
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}
