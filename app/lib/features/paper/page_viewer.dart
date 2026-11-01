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
  List<int> pages = const [],
  int? page,
  Uint8List? Function(int page)? loadPage,
}) {
  var index = pages.indexOf(page ?? -1);
  var shownTitle = title;
  var shownPicture = picture;
  return showDialog<void>(
    context: context,
    animationStyle: reducedMotion(context),
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void move(int offset) => setState(() {
          index += offset;
          shownTitle = 'Sheet ${pages[index]}';
          shownPicture = loadPage!(pages[index]);
        });
        return Dialog(
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
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            shownTitle,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  if (index >= 0 && loadPage != null)
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: index == 0 ? null : () => move(-1),
                          icon: const Icon(Icons.chevron_left),
                          label: const Text('Previous'),
                        ),
                        Text('${index + 1} of ${pages.length}'),
                        TextButton.icon(
                          onPressed: index == pages.length - 1
                              ? null
                              : () => move(1),
                          icon: const Icon(Icons.chevron_right),
                          label: const Text('Next'),
                        ),
                      ],
                    ),
                  Text(note, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 12),
                  Flexible(
                    child: shownPicture == null
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'This page is not in the cache any more. Read the batch again to bring it back.',
                            ),
                          )
                        : InteractiveViewer(
                            key: ValueKey(shownTitle),
                            maxScale: 6,
                            child: Semantics(
                              image: true,
                              label: shownTitle,
                              child: Image.memory(
                                shownPicture!,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
