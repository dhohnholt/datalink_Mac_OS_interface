# App Review notes

Paste the section below into **App Review Information → Notes** in App Store
Connect. It is written for a reviewer who has never seen an optical mark
scanner and does not have one on the desk.

This describes the Flutter edition (2.0 and later). Keep it in step with the
entitlements; everything it claims is checkable against the build:

```bash
./AppStore/build_flutter_appstore.sh     # or DATALINK_APPSTORE_CHECK=1 for the checks alone
codesign -d --entitlements :- "AppStore/flutter-dist/DataLink Scanner.app"
```

The script fails the build if the signed app carries any entitlement other than
the four below, or any of get-task-allow, allow-jit, allow-unsigned-executable-memory,
disable-library-validation or network.server.

---

## Paste this

DataLink Scanner reads paper multiple-choice answer sheets for teachers. It
scores them against an answer key and shows which questions a class got wrong.

**You do not need the scanner hardware to review this app.**

The app normally reads sheets from an Apperson DataLink 1200, a USB optical
mark reader. Since you will not have one, use the **Paper** tab instead: it
takes a PDF of scanned answer sheets and produces exactly the same result. A
sample PDF is attached to this submission. Open the app, choose **Paper**,
choose the PDF, enter the page number of the answer key (page 1 in the sample),
and press **Read the sheets**. The scored report appears under **Analysis**.

No account, no sign-in, and no network connection are needed to review it.
Everything works offline.

The app is written in Dart with Flutter. It runs no interpreter, compiles no
code at run time, downloads nothing, and has no self-update mechanism. Reading a
PDF, finding the marks on each sheet and scoring them are all done inside the
app; no other program or library is launched or installed.

### Why each entitlement is here

The app has exactly four, and nothing else.

**com.apple.security.app-sandbox** — Required for the Mac App Store.

**com.apple.security.device.serial** — The DataLink 1200 presents itself as a
USB serial device. The app opens that port, sends the scanner's documented
command sequence, and reads back the marks. This is the app's core function. It
is used for nothing else, and only when the teacher presses **Connect and start
session** (or **Run check** in Settings).

**com.apple.security.files.user-selected.read-write** — Choosing a PDF through
an Open panel, and saving a CSV or JSON export through a Save panel. The app
reaches no file it was not handed this way.

**com.apple.security.network.client** — One use. A teacher may choose to send a
scored report over HTTPS to a web address they enter themselves, with a
connection token that website issued. The app ships with no address configured,
so out of the box it makes no network connection at all, and it does not start
one until the teacher presses the upload button. The app does not listen for
connections: it has no server and no network.server entitlement.

### Keychain

If the teacher connects a website, its connection token is stored in their own
login Keychain, under this app's name, and nowhere else. The app reads it only
when the teacher opens Settings or the Send pane.

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
