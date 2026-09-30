/// Raised for anything worth showing the teacher. The message is the text that
/// appears on screen, so it is kept identical to the Python original.
class DataLinkError implements Exception {
  const DataLinkError(this.message);

  final String message;

  @override
  String toString() => message;
}
