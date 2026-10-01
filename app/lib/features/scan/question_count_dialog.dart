import 'package:flutter/material.dart';

import '../../ui/widgets.dart';

/// "The key has answers through question 30, but this is set to 50. Use 30?"
///
/// Asked when the answer key stops short of the session's question count.
/// Returns true to score out of [suggested], false to keep [current]. [marks]
/// and [sheets] say what taking it up would leave out: marks students made
/// after question [suggested]. Nothing is left out when the key has only just
/// been scanned, and then the dialog says nothing about it.
Future<bool> questionCountDialog(
  BuildContext context, {
  required int current,
  required int suggested,
  int sheets = 0,
  int marks = 0,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    animationStyle: reducedMotion(context),
    barrierDismissible: false,
    builder: (context) {
      final loses = marks > 0;
      return AlertDialog(
        title: Text('This looks like a $suggested-question test'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The answer key has answers for questions 1 to $suggested and none after that, '
                'but this test is set to $current questions. Scored out of $current, every '
                'percentage would be wrong.',
              ),
              const SizedBox(height: 12),
              Text(
                loses
                    ? '$marks mark${marks == 1 ? '' : 's'} on $sheets sheet${sheets == 1 ? '' : 's'} '
                        'after question $suggested would be left out.'
                    : 'Answers after question $suggested will not be kept.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: loses,
            onPressed: () => Navigator.pop(context, false),
            child: Text('Keep $current questions'),
          ),
          FilledButton(
            autofocus: !loses,
            onPressed: () => Navigator.pop(context, true),
            child: Text('Use $suggested questions'),
          ),
        ],
      );
    },
  );
  return answer ?? false;
}
