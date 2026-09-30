/// The specification a teacher can hand to whoever builds their reporting site.
///
/// Copied verbatim from the original page (`buildPrompt` in index.html): it
/// describes the contract the upload client in `ttess.dart` was built against.
/// A test compares it with the client's constants so the two cannot drift.
library;

const String uploadSpecification = r'''Build an HTTPS endpoint that receives scored exam reports from DataLink
Scanner, a macOS app that reads Apperson DataLink 1200 answer sheets.

ONE URL, TWO REQUESTS

Both carry `Authorization: Bearer <token>` and `Accept: application/json`.
The app refuses any address that is not https, because the token is a header
on these requests and student data is in the body.

GET  -> which tests a report may be filed against:
        200 {"destinations": [
              {"exam_id": "...", "exam_title": "...", "test_code": "...",
               "unit_title": "...", "course_id": "...", "course_title": "..."}
            ]}
        An empty list is valid and the app says so rather than failing.

POST -> one scored run:
        body  {"exam_id": "<from the list above>", "analysis": { ... },
               "replace_run_id": "<optional unfinalized run UUID>"}
        200 or 201 {"run_id": "...", "status": "imported",
                    "review_url": "https://.../where/a/human/reads/it"}

ERRORS

Answer with the real HTTP status and a body of
{"error": {"code": "...", "message": "..."}}. The message is shown to the
teacher verbatim, so write it for them, not for a log.

Use 401, or the code "invalid_token", when the token is bad or withdrawn: the
app then erases its stored copy and asks the teacher to reconnect. Anything
transient should be a 5xx. The app retries twice, backing off, with a byte
for byte identical body.

TOKENS

The teacher generates a token on your site and pastes it into the app, which
stores it in the macOS Keychain and never writes it to a file, a log or an
error message. Tokens must begin with `dlk_live_` or the app rejects them
before sending anything. Issue one per teacher, let them revoke it, and
require nothing else: the app sends no email address, no password, no account
identifier of any kind.

THE ANALYSIS OBJECT

At most 5 MB encoded, or the app refuses to send it. Top level keys include:

  run_id          stable for one scored run
  exam            test_code, source_type, capture_method, question_count
  students        one entry per sheet: student id, name, per question answers
  scores          per student totals
  stats           per question statistics, difficulty and discrimination
  answer_key      the key the run was scored against
  review_items    sheets the app wants a human to look at

Store whatever you need and ignore the rest; treat unknown keys as forward
compatible rather than an error.

RUN IDS ARE AN AUDIT KEY

`analysis.run_id` identifies one scored run. The same run_id arriving twice is
a retry of a single upload, not two uploads: make the write idempotent on it
and return the original run_id. A re-score after the key or a sheet is
corrected arrives with a NEW run_id, and that one is a genuinely new record
which must not overwrite the first silently. A teacher has to be able to see
that a class was scored twice and why.

WHAT NOT TO DO

Do not ask the app for credentials of any kind beyond the token. Do not log
the authorization header, the full request body, student names or student IDs.
Redact secrets from errors and diagnostics. This data is about children.''';
