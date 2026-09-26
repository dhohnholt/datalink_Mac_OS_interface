# App Review notes

Paste the section below into **App Review Information → Notes** in App Store
Connect. It is written for a reviewer who has never seen an optical mark
scanner and does not have one on the desk.

Keep it in step with the entitlements. Everything it claims is checkable
against the build:

```bash
codesign -d --entitlements :- "AppStore/dist/DataLink Scanner.app"
```

---

## Paste this

DataLink Scanner reads paper multiple-choice answer sheets for teachers. It
scores them against an answer key and shows which questions a class got wrong.

**You do not need the scanner hardware to review this app.**

The app normally reads sheets from an Apperson DataLink 1200, a USB optical
mark reader. Since you will not have one, use the **Paper** tab instead: it
takes a PDF of scanned answer sheets and produces exactly the same result. A
sample PDF is attached to this submission. Open the app, choose **Paper**,
select the PDF, and the scored report appears in **Analysis**.

No account, no sign-in, and no network connection are needed to review it.
Everything works offline.

### Why each entitlement is here

**com.apple.security.cs.allow-unsigned-executable-memory** — The app is
written in Python and embeds CPython, which compiles and executes bytecode at
runtime and cannot start without this. No code is downloaded, fetched or
installed at any point: OpenCV, NumPy, Pillow and the poppler PDF tools are
all inside the signed bundle, and the app has no self-update mechanism of any
kind.

**com.apple.security.device.serial** — The DataLink 1200 presents itself as a
USB serial device. The app opens that port, sends the scanner's documented
command sequence, and reads back the marks. This is the app's core function.
It is used for nothing else.

**com.apple.security.network.server** — The interface is a local web page the
app serves to its own WKWebView over HTTP on 127.0.0.1, on an ephemeral port.
It binds to loopback only and accepts no connection from outside the machine.

**com.apple.security.network.client** — Two uses. The app's own WKWebView
connects to that loopback server, which the sandbox counts as an outbound
connection. Separately, a teacher may choose to send a scored report over
HTTPS to a web address they enter themselves; the app ships with no address
configured, so out of the box it makes no outbound connection at all.

**com.apple.security.files.user-selected.read-write** — Choosing a PDF through
an Open panel, and saving a CSV export through a Save panel. The app reaches
no file it was not handed this way.

### Privacy

Nothing is collected. No analytics, no crash reporting, no advertising, no
device identifiers, no account. Scanned sheets, student names and student ID
numbers are written only to the app's own container on the teacher's Mac.

Nothing is transmitted anywhere unless the teacher enters the address of their
own website and chooses to upload a report to it. The developer does not
operate or receive anything sent that way.

Privacy policy: https://dhohnholt.github.io/datalink_Mac_OS_interface/privacy.html
Support: https://dhohnholt.github.io/datalink_Mac_OS_interface/

### About the hardware name

Apperson is the manufacturer of the DataLink 1200. This is an independent
project and is not affiliated with or endorsed by Apperson. The app's own
interface says so on its first screen.

---

## Before submitting: the sample PDF

The notes promise a sample PDF and the reviewer needs it, because without it
they cannot exercise the app at all.

**Do not attach a real scan.** Every PDF under `Scans/` carries real students'
names and ID numbers. Produce a synthetic batch instead: blank forms filled in
by hand with invented IDs, scanned to PDF.

Attach it in App Store Connect under **App Review Information → Attachment**.
