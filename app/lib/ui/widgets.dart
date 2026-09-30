import 'package:flutter/material.dart';

/// Colours for things that are good, doubtful or bad. Never the only signal:
/// every use pairs one with words or an icon.
enum Tone { neutral, good, warn, bad }

extension ToneColors on Tone {
  Color foreground(ColorScheme scheme) => switch (this) {
        Tone.neutral => scheme.onSurfaceVariant,
        Tone.good => scheme.brightness == Brightness.dark
            ? const Color(0xFF7DDC9A)
            : const Color(0xFF0B6B2E),
        Tone.warn => scheme.brightness == Brightness.dark
            ? const Color(0xFFF2C46B)
            : const Color(0xFF8A5A00),
        Tone.bad => scheme.error,
      };

  Color background(ColorScheme scheme) => switch (this) {
        Tone.neutral => scheme.surfaceContainerHighest,
        Tone.good => scheme.brightness == Brightness.dark
            ? const Color(0xFF12301D)
            : const Color(0xFFE2F4E8),
        Tone.warn => scheme.brightness == Brightness.dark
            ? const Color(0xFF3A2C0C)
            : const Color(0xFFFBF0D5),
        Tone.bad => scheme.errorContainer,
      };

  IconData get icon => switch (this) {
        Tone.neutral => Icons.circle_outlined,
        Tone.good => Icons.check_circle_outline,
        Tone.warn => Icons.warning_amber_rounded,
        Tone.bad => Icons.error_outline,
      };
}

/// A titled card, the page's basic unit.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.semanticsLabel,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: semanticsLabel ?? title,
      child: Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(title, style: theme.textTheme.titleMedium),
                        ),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// A single figure with a label, announced as one thing.
class MetricTile extends StatelessWidget {
  const MetricTile({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(value, style: theme.textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }
}

/// A row of metrics that wraps instead of overflowing.
class MetricRow extends StatelessWidget {
  const MetricRow({super.key, required this.tiles});

  final List<MetricTile> tiles;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 16), child: Wrap(spacing: 12, runSpacing: 12, children: tiles));
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.message, this.icon = Icons.inbox_outlined});

  final String title;
  final String? message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: message == null ? title : '$title. $message',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: Icon(icon, size: 36, color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    message!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small status label: icon and words, tinted.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.text, this.tone = Tone.neutral});

  final String text;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.background(scheme),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(tone.icon, size: 14, color: tone.foreground(scheme))),
          const SizedBox(width: 4),
          Text(
            text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tone.foreground(scheme)),
          ),
        ],
      ),
    );
  }
}

/// A count on a tab or button; says how many in words for VoiceOver.
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, required this.noun});

  final int count;

  /// Singular noun, e.g. "item to review".
  final String noun;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '$count $noun${count == 1 ? '' : 's'}',
      excludeSemantics: true,
      child: Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(999)),
        child: Text(
          '$count',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onPrimary),
        ),
      ),
    );
  }
}

/// Transient feedback, announced to VoiceOver by the snack bar itself.
void showToast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        width: 480,
        duration: const Duration(milliseconds: 2800),
      ),
    );
}

/// Ask before something that cannot be undone. Returns true to go ahead.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'OK',
  bool destructive = false,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          autofocus: !destructive,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// Ask for a line of text. Returns null if cancelled.
Future<String?> promptDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String confirmLabel = 'Save',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

/// "Sep 16 6:05 PM" from an ISO timestamp, or an em dash.
String formatTimestamp(String? value) {
  if (value == null || value.isEmpty) return '—';
  final when = DateTime.tryParse(value);
  if (when == null) return '—';
  final local = when.toLocal();
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final half = local.hour < 12 ? 'AM' : 'PM';
  return '${months[local.month - 1]} ${local.day} $hour:$minute $half';
}
