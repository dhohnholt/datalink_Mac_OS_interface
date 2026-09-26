"""Client for the T-TESS reteach API.

Sends a scored item analysis straight to the teacher's T-TESS site so the
report does not have to be exported and uploaded by hand.

Two rules shape everything here. The connection token is a credential, so it
lives in the Keychain and never reaches a log line or an error message. And an
upload is an audit record, so a retry of one request keeps its run_id while a
corrected re-score gets a new one.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

from . import edition
from . import keychain


# No address ships with the app, in either edition.
#
# These used to default to one school's Supabase function and one school's
# T-TESS site, written into a public repository, which meant the store edition
# needed code to suppress somebody's personal details rather than simply not
# having them. The default is now nobody, and a teacher says where their own
# reports go. It is remembered in Settings, so it is asked for once.
#
# The environment variables still work, for a machine that wants to set this
# without touching the interface.
API_URL = os.environ.get("DATALINK_API_URL", "")
REVIEW_BASE_URL = os.environ.get("DATALINK_REVIEW_BASE_URL", "")
# Where the teacher goes to generate a token, and to read the reports this app
# uploads. Opened in the real browser, never inside the app's web view.
SITE_URL = os.environ.get("DATALINK_SITE_URL", "")
KEYCHAIN_SERVICE = os.environ.get("DATALINK_KEYCHAIN_SERVICE", "org.tmechs.datalink")
KEYCHAIN_ACCOUNT = os.environ.get(
    "DATALINK_KEYCHAIN_ACCOUNT", "scantron-upload-token"
)
REQUEST_TIMEOUT_SECONDS = float(
    os.environ.get("DATALINK_REQUEST_TIMEOUT_SECONDS", "30")
)
MAX_ANALYSIS_BYTES = int(os.environ.get("DATALINK_MAX_ANALYSIS_BYTES", "5242880"))

# The Developer ID build was made for one school and carries that school's
# address as its default. The store edition must not: it goes to strangers,
# and pointing their uploads at someone else's server would be wrong even if
# that server refused them. There the teacher gives their own address, and
# until they do there is nowhere to send anything.
_endpoint_override: str | None = None
_site_override: str | None = None


def set_endpoint(url: str | None) -> None:
    """Where reports are sent. Empty or None falls back to the environment."""
    global _endpoint_override
    _endpoint_override = (url or "").strip() or None


def set_site(url: str | None) -> None:
    """Where the teacher reads those reports, for the link in Settings."""
    global _site_override
    _site_override = (url or "").strip() or None


def api_url() -> str:
    if _endpoint_override:
        return _endpoint_override
    # The store edition ignores the environment as well, so that a variable
    # set for the other edition cannot quietly give it somewhere to send to.
    return "" if edition.sandboxed() else API_URL


def site_url() -> str:
    if _site_override:
        return _site_override
    return "" if edition.sandboxed() else SITE_URL


def review_base_url() -> str:
    if _site_override:
        return _site_override
    return "" if edition.sandboxed() else REVIEW_BASE_URL


TOKEN_PREFIX = "dlk_live_"
DESTINATION_CACHE_SECONDS = 15 * 60
MAX_RETRIES = 2


class UploadError(RuntimeError):
    """A failure worth showing the teacher, with the server's own wording."""

    def __init__(self, message: str, code: str = "error", retryable: bool = False):
        super().__init__(message)
        self.code = code
        self.retryable = retryable


def _require_https(url: str) -> None:
    if not url.lower().startswith("https://"):
        raise UploadError(
            "The upload address must use https. Refusing to send student data "
            "over an unencrypted connection.",
            code="insecure_url",
        )


def token() -> str | None:
    return keychain.get_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)


def save_token(value: str) -> None:
    value = (value or "").strip()
    if not value:
        raise UploadError("Paste the connection token first", code="empty_token")
    if not value.startswith(TOKEN_PREFIX):
        raise UploadError(
            f"That does not look like a DataLink connection token — they begin "
            f"with {TOKEN_PREFIX}",
            code="malformed_token",
        )
    keychain.set_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, value)


def forget_token() -> bool:
    return keychain.delete_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)


def _request(method: str, body: bytes | None, bearer: str) -> tuple[int, dict]:
    url = api_url()
    if not url:
        raise UploadError(
            "No upload address is set. Open Settings and enter the address of "
            "your own site before connecting.",
            code="no_endpoint",
        )
    _require_https(url)
    request = urllib.request.Request(url, data=body, method=method)
    request.add_header("Authorization", f"Bearer {bearer}")
    request.add_header("Accept", "application/json")
    if body is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(
            request, timeout=REQUEST_TIMEOUT_SECONDS
        ) as response:
            payload = response.read()
            return response.status, json.loads(payload) if payload else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw) if raw else {}
        except ValueError:
            return exc.code, {}
    except urllib.error.URLError as exc:
        # The reason can carry a host name but never the token, which is only
        # ever sent as a header.
        raise UploadError(
            f"Could not reach the site ({exc.reason}). Check the internet "
            "connection and try again.",
            code="service_unavailable",
            retryable=True,
        ) from None
    except TimeoutError:
        raise UploadError(
            f"The site did not respond within {REQUEST_TIMEOUT_SECONDS:.0f} seconds.",
            code="service_unavailable",
            retryable=True,
        ) from None


def _server_error(status: int, payload: dict) -> UploadError:
    error = payload.get("error") or {}
    code = str(error.get("code") or "")
    message = str(error.get("message") or "").strip()

    if status == 401 or code == "invalid_token":
        forget_token()
        return UploadError(
            message
            or "The connection token is no longer valid. Open Settings and "
            "paste a new one.",
            code="invalid_token",
        )
    if status == 403 or code == "exam_forbidden":
        return UploadError(
            message or "That test is not available to this account. Choose another.",
            code="exam_forbidden",
        )
    if code == "run_not_replaceable":
        return UploadError(
            message or "Those results are already finalized and cannot be replaced.",
            code="run_not_replaceable",
        )
    if status == 409 or code == "duplicate_run":
        return UploadError(
            message or "This scoring run has already been uploaded.",
            code="duplicate_run",
        )
    if status == 413 or code == "payload_too_large":
        return UploadError(
            message or "The analysis is larger than the 5 MB upload limit.",
            code="payload_too_large",
        )
    if status == 422 or code == "validation_failed":
        return UploadError(
            message or "The site rejected the analysis.", code="validation_failed"
        )
    if status == 503 or code == "service_unavailable":
        return UploadError(
            message or "The site is temporarily unavailable.",
            code="service_unavailable",
            retryable=True,
        )
    return UploadError(
        message or f"The site returned an unexpected response ({status}).",
        code=code or "unexpected",
        retryable=status >= 500,
    )


def fetch_destinations(bearer: str | None = None) -> list[dict]:
    bearer = bearer or token()
    if not bearer:
        raise UploadError("Connect DataLink to your site first", code="not_connected")
    status, payload = _request("GET", None, bearer)
    if status != 200:
        raise _server_error(status, payload)
    return list(payload.get("destinations") or [])


@dataclass
class DestinationCache:
    """Kept for 15 minutes, and refreshed on connect, on launch and before an
    upload once stale."""

    destinations: list[dict] = field(default_factory=list)
    fetched_at: float = 0.0

    @property
    def stale(self) -> bool:
        return (time.monotonic() - self.fetched_at) > DESTINATION_CACHE_SECONDS

    def refresh(self, bearer: str | None = None) -> list[dict]:
        self.destinations = fetch_destinations(bearer)
        self.fetched_at = time.monotonic()
        return self.destinations

    def get(self, bearer: str | None = None, force: bool = False) -> list[dict]:
        if force or self.stale or not self.destinations:
            return self.refresh(bearer)
        return self.destinations


def prepare_analysis(analysis: dict, test_code: str) -> tuple[dict, bytes]:
    """Stamp the destination onto the report and check it against the limit.

    schema_version and run_id are left exactly as scored: the run_id is what
    makes a retry the same audit record rather than a second one.
    """
    payload = json.loads(json.dumps(analysis))
    payload.setdefault("exam", {})
    payload["exam"]["test_code"] = test_code
    # source_type says how it reached T-TESS, which is the same either way.
    # capture_method keeps how the sheets were actually read, so a batch off a
    # document scanner is not recorded as having come from the device.
    payload["exam"].setdefault(
        "capture_method",
        "paper_scan"
        if payload["exam"].get("source_type") == "pdf_scan"
        else "datalink",
    )
    payload["exam"]["source_type"] = "datalink_direct"
    encoded = json.dumps(payload).encode("utf-8")
    if len(encoded) > MAX_ANALYSIS_BYTES:
        raise UploadError(
            f"The analysis is {len(encoded) / 1_048_576:.1f} MB, over the "
            f"{MAX_ANALYSIS_BYTES / 1_048_576:.0f} MB upload limit.",
            code="payload_too_large",
        )
    return payload, encoded


def upload(
    exam_id: str,
    analysis: dict,
    test_code: str,
    replace_run_id: str | None = None,
    bearer: str | None = None,
    sleep=time.sleep,
) -> dict:
    """Send one scored run. Retries only what is safe to retry."""
    bearer = bearer or token()
    if not bearer:
        raise UploadError("Connect DataLink to your site first", code="not_connected")
    if not exam_id:
        raise UploadError("Choose which test to upload to", code="no_destination")

    prepared, _ = prepare_analysis(analysis, test_code)
    request_body = {"exam_id": exam_id, "analysis": prepared}
    if replace_run_id:
        request_body["replace_run_id"] = replace_run_id
    body = json.dumps(request_body).encode("utf-8")

    attempt = 0
    while True:
        try:
            status, payload = _request("POST", body, bearer)
            if status in (200, 201):
                return {
                    "run_id": payload.get("run_id"),
                    "status": payload.get("status", "imported"),
                    "replaced_run_id": payload.get("replaced_run_id"),
                    "review_url": payload.get("review_url") or review_base_url(),
                }
            failure = _server_error(status, payload)
        except UploadError as exc:
            failure = exc
        if not failure.retryable or attempt >= MAX_RETRIES:
            raise failure
        # Same body, so the same run_id: a retry must not become a second
        # audit record.
        sleep(2**attempt)
        attempt += 1
