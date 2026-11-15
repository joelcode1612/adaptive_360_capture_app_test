"""Toggle a host-testable pubspec for `flutter test` on Windows.

Why this exists
---------------
`dartcv4` (opencv_dart's native half) ships a pub build hook. Every Dart entry
point in this package -- `flutter test`, `dart run tool/...`, `flutter build` --
runs that hook first, and on Windows it configures CMake with MSVC and the
Windows SDK resource compiler. On a machine without the SDK's `rc.exe` the hook
fails, and *no* Dart code runs at all -- including unit tests that never touch
OpenCV.

Unit tests for the SQLite / sync / role layers do not need OpenCV, so this
script produces a pubspec without `opencv_dart` for the duration of a test run
and restores the original byte-for-byte afterwards.

Usage:
    python tool/host_test_pubspec.py off   # test-time pubspec (opencv_dart out)
    python tool/host_test_pubspec.py on    # restore the real pubspec

The restore is idempotent: running `on` twice is harmless.
"""

from __future__ import annotations

import io
import os
import sys

PUBSPEC = "pubspec.yaml"
BACKUP = os.path.join("tool", ".pubspec.host-test.bak")
BANNER = "# HOST-TEST VARIANT: opencv_dart and its build hook are removed so"


def read(path: str) -> str:
    return io.open(path, encoding="utf-8", newline="").read()


def write(path: str, text: str) -> None:
    io.open(path, "w", encoding="utf-8", newline="").write(text)


def disable() -> None:
    raw = read(PUBSPEC)
    if not os.path.exists(BACKUP):
        write(BACKUP, raw)
    nl = "\r\n" if "\r\n" in raw else "\n"
    lines = raw.split(nl)

    out: list[str] = []
    in_hooks = False
    for line in lines:
        stripped = line.strip()
        if stripped == "hooks:":
            in_hooks = True
            out.append(BANNER)
            out.append("# unit tests run. Restore with tool/host_test_pubspec.py on")
            out.append("# hooks:")
            continue
        if in_hooks:
            if stripped and not line.startswith(" "):
                in_hooks = False
            else:
                out.append("# " + line if stripped else line)
                continue
        if stripped.startswith("opencv_dart:"):
            out.append("# " + line)
            continue
        out.append(line)
    write(PUBSPEC, nl.join(out))
    print("pubspec: host-test variant written")


def restore() -> None:
    if not os.path.exists(BACKUP):
        print("pubspec: nothing to restore")
        return
    write(PUBSPEC, read(BACKUP))
    os.remove(BACKUP)
    print("pubspec: restored")


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "off":
        disable()
    elif mode == "on":
        restore()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
