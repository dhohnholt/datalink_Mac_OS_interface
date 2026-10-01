import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../ui/widgets.dart';

/// A scanned page in a dialog, for reading off what the reader could not: a
/// name on a sheet, or the key's marks. Zoom with a pinch or scroll.
Future<void> showPagePicture(
  BuildContext context, {
  required String title,
  required String note,
  required Uint8List? picture,
}) {
  return showDialog<void>(
    context: context,
    animationStyle: reducedMotion(context),
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 900),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.titleMedium))),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Text(note, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              Flexible(
                child: picture == null
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('This page is not in the cache any more. Read the batch again to bring it back.'),
                      )
                    : InteractiveViewer(
                        maxScale: 6,
                        child: Semantics(
                          image: true,
                          label: title,
                          child: Image.memory(picture, fit: BoxFit.contain, gaplessPlayback: true),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
