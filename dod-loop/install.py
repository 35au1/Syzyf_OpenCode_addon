#!/usr/bin/env python3
"""install.py - set up everything the DoD loop needs that is not in this folder.

Double-click on Windows, or run `python install.py`.

The repo ships the loop itself: dod-loop.ts, run-dod-loop.bat, definition-gui.ps1, status.ps1, the
.opencode template and verifier agent, and package.json + bun.lock. It cannot ship these:

  1. Bun          - runs dod-loop.ts
  2. opencode     - the TUI, which is also the server the loop talks to
  3. node_modules - restored by `bun install` from package.json + bun.lock
  4. your login   - opencode credentials live in your user profile, not in the folder
  5. source data  - the folder the Definition of Done points at

This script installs 1-3, verifies 4, and checks 5. It never touches .opencode/dod.md or anything
under projectfiles/: those are your content.

Flags:
  --check-only   report status, install nothing
  --no-pause     do not wait for a keypress at exit
"""

from __future__ import annotations

import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

PY_MIN = (3, 10)
HERE = Path(__file__).resolve().parent
WINDOWS = platform.system() == "Windows"
EXE = ".exe" if WINDOWS else ""

# Where the Bun installer puts things, and where opencode lands when installed through Bun.
BUN_BIN = Path.home() / ".bun" / "bin"
OPENCODE_BIN = Path.home() / ".opencode" / "bin"

# Files that must already be present. If one is missing the zip was extracted wrong.
REQUIRED = [
    Path("dod-loop.ts"),
    Path("run-dod-loop.bat"),
    Path("definition-gui.ps1"),
    Path("package.json"),
    Path(".opencode/dod.md"),
    Path(".opencode/agent/dod-verifier.md"),
]

OK, WARN, BAD = "ok", "warn", "FAILED"
results: list[tuple[str, str, str]] = []


def record(name: str, status: str, detail: str = "") -> None:
    results.append((name, status, detail))
    mark = {OK: "  [ok]  ", WARN: "  [warn]", BAD: "  [FAIL]"}[status]
    print(f"{mark} {name}" + (f" - {detail}" if detail else ""))


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    """Never raises. A missing binary and a crashing binary look the same to the caller."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=kw.pop("timeout", 300), **kw)
    except (OSError, subprocess.SubprocessError) as error:
        return subprocess.CompletedProcess(cmd, 1, "", str(error))


def find_tool(name: str) -> Path | None:
    """PATH first, then the two install locations. A fresh shell often lacks ~/.bun/bin on PATH,
    which is why run-dod-loop.bat prepends it, and why looking only at PATH reports false failures."""
    found = shutil.which(name)
    if found:
        return Path(found)
    for base in (BUN_BIN, OPENCODE_BIN):
        candidate = base / (name + EXE)
        if candidate.exists():
            return candidate
    return None

def version_of(text: str) -> tuple[int, ...]:
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", text or "")
    return tuple(int(part) for part in match.groups()) if match else (0, 0, 0)


# ---------------------------------------------------------------------------- 0. python


def check_python() -> bool:
    got = sys.version_info[:3]
    if got[:2] < PY_MIN:
        record("python", BAD, f"{'.'.join(map(str, got))}; need {'.'.join(map(str, PY_MIN))}+")
        return False
    record("python", OK, ".".join(map(str, got)))
    return True


# ---------------------------------------------------------------------------- 1. bun

BUN_MIN = (1, 3, 0)


def ensure_bun(check_only: bool) -> Path | None:
    found = find_tool("bun")
    if not found and not check_only:
        print("  installing Bun ...")
        if WINDOWS:
            run(["powershell", "-NoProfile", "-Command", "irm bun.com/install.ps1 | iex"], timeout=900)
        else:
            run(["bash", "-c", "curl -fsSL https://bun.sh/install | bash"], timeout=900)
        found = find_tool("bun")
    if not found:
        record("bun", BAD, "not installed; get it from https://bun.com/install")
        return None
    got = version_of(run([str(found), "--version"]).stdout)
    if got < BUN_MIN:
        record("bun", BAD, f"{'.'.join(map(str, got))} is too old, need {'.'.join(map(str, BUN_MIN))}+")
        return None
    record("bun", OK, f"{'.'.join(map(str, got))} at {found}")
    return found


# ---------------------------------------------------------------------------- 2. opencode

# The version this loop was checked against. Pinned so a new machine behaves like the old one; the
# TUI-owns-the-server arrangement in run-dod-loop.bat depends on `opencode --port` behaviour.
OPENCODE_PIN = "1.18.18"
OPENCODE_PACKAGE = "opencode-ai"


def ensure_opencode(bun: Path | None, check_only: bool) -> Path | None:
    found = find_tool("opencode")
    if not found and not check_only:
        if not bun:
            record("opencode", BAD, "cannot install without Bun")
            return None
        # Bun rather than npm deliberately: npm's global install needs a symlink that fails with
        # EPERM on Windows unless the shell is elevated.
        print(f"  installing {OPENCODE_PACKAGE}@{OPENCODE_PIN} with bun ...")
        done = run([str(bun), "install", "-g", f"{OPENCODE_PACKAGE}@{OPENCODE_PIN}"], timeout=900)
        if done.returncode != 0:
            record("opencode", BAD, (done.stderr or done.stdout).strip()[:200])
            return None
        found = find_tool("opencode")
    if not found:
        record("opencode", BAD, "not installed; see https://opencode.ai/docs")
        return None
    got = run([str(found), "--version"]).stdout.strip() or "unknown"
    if got.startswith(OPENCODE_PIN):
        record("opencode", OK, f"{got} at {found}")
    else:
        record("opencode", WARN, f"{got} at {found}; loop was checked against {OPENCODE_PIN}")
    return found


# ---------------------------------------------------------------------------- 3. files and deps

RUN_ID = re.compile(r"^\d{5}$")


def check_files() -> bool:
    missing = [str(rel) for rel in REQUIRED if not (HERE / rel).is_file()]
    if missing:
        record("folder contents", BAD, "missing " + ", ".join(missing))
        return False
    record("folder contents", OK, f"all {len(REQUIRED)} required files present")

    # Nothing is pre-created here. run-dod-loop.bat allocates projectfiles/<run id>/ at launch and
    # seeds the definition from the template, so that the operator reviews it before work starts.
    runs = HERE / "projectfiles"
    existing = sorted(d.name for d in runs.iterdir() if d.is_dir() and RUN_ID.match(d.name)) if runs.is_dir() else []
    if existing:
        record("runs", OK, f"{len(existing)} existing: {', '.join(existing[-5:])}")
    else:
        record("runs", OK, "no runs yet; the first launch creates projectfiles/00001")
    return True


def ensure_deps(bun: Path | None, check_only: bool) -> None:
    if check_only:
        present = (HERE / "node_modules").is_dir()
        record("dependencies", OK if present else WARN,
               "node_modules present" if present else "run `bun install` in this folder")
        return
    if not bun:
        record("dependencies", BAD, "skipped, no Bun")
        return
    done = run([str(bun), "install"], cwd=str(HERE), timeout=900)
    if done.returncode != 0:
        record("dependencies", BAD, (done.stderr or done.stdout).strip()[:200])
        return
    record("dependencies", OK, "bun install completed")


# ---------------------------------------------------------------------------- 4. login


def check_login(opencode: Path | None) -> None:
    """Advisory. Credentials are intentionally not carried in the folder, so this can only remind."""
    if not opencode:
        record("login", WARN, "skipped, no opencode")
        return
    done = run([str(opencode), "auth", "list"])
    output = (done.stdout + done.stderr).strip()
    if done.returncode == 0 and output and "opencode" in output.lower():
        record("login", OK, "a provider is authorised")
        return
    record("login", WARN, "run `opencode auth login` - the loop uses opencode Zen free models by default")


# ---------------------------------------------------------------------------- 5. source data


def source_paths() -> list[str]:
    """The absolute paths .opencode/dod.md names. A moved folder still points at the old machine."""
    rules = HERE / ".opencode" / "dod.md"
    if not rules.is_file():
        return []
    text = rules.read_text(encoding="utf-8", errors="replace")
    found = re.findall(r"`([A-Za-z]:\\[^`\n]+|/(?:home|Users)/[^`\n]+)`", text)
    unique: list[str] = []
    for path in found:
        if path not in unique and not path.lower().endswith(".md"):
            unique.append(path)
    return unique


# The example path in the shipped template. Recognised so a fresh clone reports "edit this" rather
# than a blocking failure about a folder that was never meant to exist.
PLACEHOLDER_MARKERS = ("path\\to\\your", "path/to/your")


def check_source() -> None:
    paths = source_paths()
    if not paths:
        record("source data", WARN, "no absolute path found in .opencode/dod.md")
        return
    for path in paths:
        if any(marker in path.lower() for marker in PLACEHOLDER_MARKERS):
            record("source data", WARN, f"{path} is the template example; edit .opencode/dod.md to name your real source")
            continue
        target = Path(path)
        if target.is_dir():
            files = sum(1 for item in target.rglob("*") if item.is_file())
            record("source data", OK, f"{path} ({files} files)")
        else:
            record("source data", BAD, f"{path} does not exist on this machine")
            print("          Copy that folder to exactly that path, or edit the path inside")
            print("          .opencode\\dod.md to wherever you put it. The loop cannot")
            print("          enumerate a source it cannot read, and it will never pass.")


# ---------------------------------------------------------------------------- main


def main() -> int:
    check_only = "--check-only" in sys.argv
    no_pause = "--no-pause" in sys.argv

    print("=== Definition of Done loop - install ===")
    print(f"folder: {HERE}")
    print(f"system: {platform.system()} {platform.release()}")
    print(f"mode:   {'check only' if check_only else 'install what is missing'}")
    print()

    if check_python():
        bun = ensure_bun(check_only)
        opencode = ensure_opencode(bun, check_only)
        check_files()
        ensure_deps(bun, check_only)
        check_login(opencode)
        check_source()

    failures = sum(1 for _, status, _ in results if status == BAD)
    warnings = sum(1 for _, status, _ in results if status == WARN)

    print()
    print("=== summary ===")
    if failures:
        print(f"{failures} blocking problem(s), {warnings} warning(s). Fix the [FAIL] lines above,")
        print("then run this again.")
    else:
        if warnings:
            print(f"No blockers, {warnings} warning(s) worth reading above.")
        print()
        print("Next:")
        print("  1. Open a NEW terminal if Bun or opencode were just installed, so PATH updates.")
        print("  2. Double-click run-dod-loop.bat")
        print()
        print("The TUI window it opens IS the server. Leave it open while the loop runs.")
        print("For an unattended run with no window to protect: set DOD_LOOP_NO_GUI=1 and watch")
        print("progress with:  powershell -ExecutionPolicy Bypass -File status.ps1")

    if not no_pause and sys.stdin and sys.stdin.isatty():
        try:
            input("\nPress Enter to close ... ")
        except (EOFError, KeyboardInterrupt):
            pass
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
