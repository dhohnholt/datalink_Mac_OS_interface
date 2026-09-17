#!/usr/bin/env python3
"""Copy poppler's pdftoppm and pdfinfo into the app, with their libraries.

The paper pipeline shells out to those two tools to turn a PDF into images.
On a Mac with Homebrew they come from there, but the disk image has to work on
a machine that cannot install Homebrew at all — a district-managed laptop that
blocks GitHub, for instance — so the tools have to travel inside the bundle.

Swapping in a pure-Python renderer was the obvious alternative and it is not
safe here: rendering the same batch with pdfium instead of poppler changed two
of 450 responses, both on rows with almost no ink, and turning pdfium's
smoothing off left the answer key unreadable. The sheet calibration was
measured against poppler's output, so poppler is what ships.

A binary copied out of Homebrew still points at /opt/homebrew for its
libraries, which will not exist on the target Mac, so every reference is
rewritten to a path inside the bundle.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path


TOOLS = ("pdftoppm", "pdfinfo")
SYSTEM_PREFIXES = ("/usr/lib", "/System")


def load_commands(binary: Path) -> tuple[list[str], list[str]]:
    """The dylibs a Mach-O asks for, and the rpaths it resolves them against."""
    output = subprocess.run(
        ["/usr/bin/otool", "-l", str(binary)], capture_output=True, text=True
    ).stdout
    lines = output.splitlines()
    dependencies, rpaths = [], []
    for index, line in enumerate(lines):
        if "LC_LOAD_DYLIB" in line or "LC_RPATH" in line:
            wanted = "name " if "LC_LOAD_DYLIB" in line else "path "
            target = dependencies if "LC_LOAD_DYLIB" in line else rpaths
            for following in lines[index : index + 6]:
                if wanted in following:
                    target.append(following.strip().split(" ")[1])
                    break
    return dependencies, rpaths


def resolve(dependency: str, rpaths: list[str], origin: Path) -> Path | None:
    """Turn @rpath/@loader_path into a real file, the way dyld would."""
    if dependency.startswith("@rpath/"):
        for rpath in rpaths:
            candidate = Path(
                rpath.replace("@loader_path", str(origin.parent))
            ) / dependency[len("@rpath/") :]
            if candidate.exists():
                return candidate.resolve()
        return None
    if dependency.startswith("@loader_path"):
        candidate = Path(dependency.replace("@loader_path", str(origin.parent)))
        return candidate.resolve() if candidate.exists() else None
    candidate = Path(dependency)
    return candidate.resolve() if candidate.exists() else None


def closure(roots: list[Path]) -> set[Path]:
    """Everything the tools need that macOS will not already have."""
    found: set[Path] = set()
    queue = list(roots)
    while queue:
        item = queue.pop().resolve()
        if item in found or str(item).startswith(SYSTEM_PREFIXES) or not item.exists():
            continue
        found.add(item)
        dependencies, rpaths = load_commands(item)
        for dependency in dependencies:
            target = resolve(dependency, rpaths, item)
            if target and not str(target).startswith(SYSTEM_PREFIXES):
                queue.append(target)
    return found


def rewrite(
    copied: Path, origin: Path, mapping: dict[str, str], inside_library_dir: bool
) -> None:
    """Point a copied Mach-O at its neighbours in the bundle.

    Resolution is done against `origin`, not the copy: @rpath and @loader_path
    mean "next to the file that loaded me", and next to the copy there is
    nothing yet. Resolving against the copy silently matched nothing and left
    those references pointing at Homebrew.
    """
    dependencies, rpaths = load_commands(copied)
    arguments = []
    for dependency in dependencies:
        target = resolve(dependency, rpaths, origin)
        name = mapping.get(str(target)) if target else None
        if name is None:
            continue
        replacement = (
            f"@loader_path/{name}"
            if inside_library_dir
            else f"@executable_path/../Frameworks/poppler/{name}"
        )
        arguments += ["-change", dependency, replacement]
    if inside_library_dir:
        arguments += ["-id", f"@loader_path/{copied.name}"]
    if arguments:
        subprocess.run(
            ["/usr/bin/install_name_tool", *arguments, str(copied)],
            capture_output=True,
            check=False,
        )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: bundle_poppler.py <path to DataLink Scanner.app>")
        return 2
    app = Path(sys.argv[1])
    if not app.is_dir():
        print(f"No app bundle at {app}")
        return 1

    # Homebrew's poppler is built for the macOS it was bottled on — 26.0 —
    # so bundling it would only move the "too new to run" problem from the
    # Python to the PDF tools. conda-forge ships the same poppler version
    # built for macOS 11. DATALINK_POPPLER_PREFIX points at such a build;
    # docs/RELEASING.md says how to make one.
    prefix = os.environ.get("DATALINK_POPPLER_PREFIX")
    tools = []
    for name in TOOLS:
        if prefix:
            found = str(Path(prefix) / "bin" / name)
        else:
            found = shutil.which(name) or f"/opt/homebrew/bin/{name}"
        if not Path(found).exists():
            print(f"{name} was not found at {found}.")
            print("Set DATALINK_POPPLER_PREFIX to a conda-forge poppler prefix.")
            return 1
        tools.append(Path(found).resolve())

    helpers = app / "Contents" / "Helpers"
    libraries = app / "Contents" / "Frameworks" / "poppler"
    for directory in (helpers, libraries):
        directory.mkdir(parents=True, exist_ok=True)

    everything = closure(tools)
    dylibs = {path for path in everything if path.suffix == ".dylib"}
    mapping = {str(path): path.name for path in dylibs}

    for source in dylibs:
        shutil.copy2(source, libraries / source.name)
        (libraries / source.name).chmod(0o755)
    for source, name in zip(tools, TOOLS):
        shutil.copy2(source, helpers / name)
        (helpers / name).chmod(0o755)

    for source, name in zip(tools, TOOLS):
        rewrite(helpers / name, source, mapping, inside_library_dir=False)
    for source in dylibs:
        rewrite(libraries / source.name, source, mapping, inside_library_dir=True)

    # Rewriting load commands invalidates any signature the copies carried.
    for binary in [helpers / name for name in TOOLS] + [
        libraries / source.name for source in dylibs
    ]:
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(binary)],
            capture_output=True,
            check=False,
        )

    size = sum(path.stat().st_size for path in libraries.iterdir())
    size += sum((helpers / name).stat().st_size for name in TOOLS)
    print(f"Bundled poppler: {len(dylibs)} libraries, {size / 1048576:.0f} MB")

    # Prove it: the copies must run with Homebrew removed from the picture,
    # because that is the whole point and a dyld failure is otherwise only
    # discovered by whoever opens the app on a Mac without it.
    for name in TOOLS:
        checked = subprocess.run(
            [str(helpers / name), "-v"],
            capture_output=True,
            text=True,
            env={"PATH": "/usr/bin:/bin"},
        )
        reported = (checked.stderr or checked.stdout).strip().splitlines()
        first = reported[0] if reported else ""
        if "Library not loaded" in first or "dyld" in first or not first:
            print(f"The bundled {name} does not run on its own:")
            print(f"  {first or '(no output)'}")
            return 1
        print(f"  {name}: {first}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
