/// Noticing that a session was set up for more questions than its test has.
///
/// The count is typed before the first sheet goes in, and the key sheet is the
/// first thing scanned. A 30-question key scanned into a 50-question session
/// has answers through 30 and nothing after, which is the mistake showing
/// itself. This only reads that; it never changes anything.
library;

/// How many questions an answer key was marked for, when that is fewer than
/// the [current] count: the place of its last answer, provided every question
/// after it is blank.
///
/// Null when the key reaches the end of the session's questions (nothing to
/// suggest) and when it has no answers at all (nothing to go on). A blank in
/// the middle does not stop the suggestion; that is a separate problem the
/// answer-key check already reports, and the end of the key is still where
/// the test stops.
///
/// [responses] are the key's stored responses: `''` for a blank, `'*'` for
/// several marks, a letter for an answer.
int? questionCountFromKey(List<String> responses, int current) {
  var last = 0;
  for (var index = 0; index < responses.length && index < current; index++) {
    if (responses[index].isNotEmpty) last = index + 1;
  }
  if (last == 0 || last >= current) return null;
  return last;
}
