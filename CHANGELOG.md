# Changelog

Starts at 1.9.5. Earlier releases are in the
[tags](https://github.com/dhohnholt/datalink_Mac_OS_interface/tags) and their
commit history.

Two editions are built from this one codebase, and they update on separate
clocks: the Homebrew build updates with `brew upgrade`, and the Mac App Store
build updates only when Apple approves a new submission. An entry says which
edition it changed when it is not both.

## 1.9.5

**Both editions**

* No upload address ships with the app any more. It used to default to one
  school's Supabase function and one school's T-TESS site, written into a
  public repository, which meant the App Store edition needed code to suppress
  somebody's personal details rather than simply not having them. A teacher now
  enters their own address in Settings, and is asked once. A test asserts that
  no real address appears in `ttess.py`, so it cannot creep back.
* A re-scored run can replace an existing one on the receiving site
  (`replace_run_id`), instead of arriving as a second record, with a
  `run_not_replaceable` error for a site that has already finalized results.
* A visual pass over the workspace: one colour ramp in place of twenty-five
  one-off greys, lighter greens, 40px controls, 12px cards, and shadows that
  lift a surface rather than float it. Two older responsive faults went with
  it — the tab strip used to overflow and widen the whole document at narrow
  widths, and the field grid stayed two-wide down to 375px.

**App Store edition only**

* First build that Apple will accept. It is sandboxed, signed for
  distribution, and carries the `Info.plist` build metadata PyInstaller does
  not write.
* Updates through the App Store: the in-app updater, the daily check and the
  menu item are all inert there, because a store app that updates itself is a
  rejection.
* Nothing is installed at runtime; OpenCV, NumPy, Pillow and poppler are in the
  bundle.
* The Keychain is read in process rather than through a helper binary.
* For a teacher with no site of their own, Settings carries the full
  specification of what the app sends and what it expects back, with a button
  that copies it.

## Releasing: two things that have gone wrong more than once

Both cost real time, and both look like a working release until something
downstream refuses it.

**The wrong artifact under the right filename.** A build writes to `dist/` or
`AppStore/dist/` under the name the previous, good artifact had. It has
happened three ways: a testable App Store package that is deliberately not
submittable was uploaded instead of the real one and consumed a build number;
and a release run rebuilt a disk image and an installer over a notarized pair
and left them unstapled under the shipping names after its notarization was
interrupted. Keep one artifact per directory, check what is actually in a file
before sending it, and rename anything that must not ship so its name says so.

**Building a disk image at all.** `release.sh` no longer builds one; pass
`--with-dmg` if a release genuinely needs it. Homebrew installs from the tag
tarball and compiles the app locally, so the image is not what anybody here
runs, and the app Homebrew installs is ad-hoc signed and never quarantined —
Apple notarization does nothing for it. The image exists only for someone who
downloads it rather than using brew. Notarization of it has hung for
45 minutes at a stretch.

Notarization, for the avoidable confusion it causes: the App Store build never
needs it, because App Store Connect notarizes during review. A disk image
needs it only if somebody downloads it, and then it needs it regardless of
which certificate signed it. Certificates do not replace notarization; they
are what makes it possible.
