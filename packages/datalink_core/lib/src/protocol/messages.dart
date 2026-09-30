import 'constants.dart';
import 'python_compat.dart';

/// How a non-record line from the scanner should be shown.
enum MessageKind { protocol, warning, error }

/// Classify one non-record line from the scanner.
///
/// `OK` is the reply to a command and belongs with the protocol chatter;
/// anything else stops the feed, so it is a warning the teacher sees without
/// turning protocol details on.
(MessageKind, String) describeMessage(String text) {
  final cleaned = pyStrip(text);
  if (cleaned.isEmpty || cleaned == 'OK' || cleaned.endsWith('OK')) {
    return (MessageKind.protocol, 'Scanner: $cleaned');
  }
  if (cleaned.startsWith(unreadableRecord)) {
    // The parser's own note about a line it could not read, already in plain
    // words. Wrapping it again would read as two errors.
    return (MessageKind.error, cleaned);
  }
  final described = scannerMessages[cleaned.toUpperCase()];
  if (described != null) return (MessageKind.warning, described);
  return (
    MessageKind.warning,
    'The scanner sent an unexpected message: $cleaned',
  );
}
