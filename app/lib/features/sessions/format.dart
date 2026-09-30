/// "12 KB", "1.5 MB": the same rounding the old page used (one decimal under
/// 10, whole numbers above, nothing below a kilobyte but "bytes").
String formatBytes(int bytes) {
  if (bytes == 0) return '0 KB';
  const units = ['bytes', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value < 10 && unit > 0 ? value.toStringAsFixed(1) : value.round().toString();
  return '$text ${units[unit]}';
}

/// The line under "Storage": how much is kept, in what.
String storageSummary(Map<String, Object?> report) {
  final oldest = report['oldest'] as String?;
  var since = '';
  final when = oldest == null ? null : DateTime.tryParse(oldest);
  if (when != null) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    since = ' · oldest ${months[when.toLocal().month - 1]} ${when.toLocal().year}';
  }
  return '${formatBytes(report['total_bytes']! as int)} in total — '
      '${report['scans']} sheets across ${report['sessions']} sessions, '
      'plus ${report['log_files']} plain-text logs$since.';
}

/// "Everything is kept in …", or nothing when there is no folder yet.
String storagePathNote(Map<String, Object?> report) {
  final directory = report['directory'] as String?;
  if (directory == null || directory.isEmpty) return '';
  return 'Everything is kept in $directory. '
      'Deleting a session removes its scans and its log file.';
}

/// The choices for "Delete sessions older than", in days.
const List<(String label, int days)> pruneChoices = [
  ('3 years', 1095),
  ('2 years', 730),
  ('1 year', 365),
  ('6 months', 180),
  ('3 months', 90),
];
