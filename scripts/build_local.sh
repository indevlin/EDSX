#!/usr/bin/env bash
#
# scripts/build_local.sh — build, smoke-test and package an EDSX
# binary the same way the Release workflow does, on this machine.
#
# Each step mirrors one in .github/workflows/release.yml, so a divergence
# between this and CI is the runner rather than the tree.
#
# PyInstaller does not cross-compile: this builds for the platform it runs
# on.  Linux and macOS run it directly; on Windows use Git Bash or MSYS2.
#
# Usage:
#   scripts/build_local.sh                 build, test, package
#   scripts/build_local.sh --no-package    build and test only
#   scripts/build_local.sh --skip-tests    build and package, no smoke test
#   scripts/build_local.sh --dir           directory layout instead of onefile
#   scripts/build_local.sh --sign          also sign with SIGNING_KEY
#
set -euo pipefail

# Resolved before the cd below, so --help still finds this file when the
# script is invoked by a relative path from somewhere else.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PACKAGE=1
RUN_TESTS=1
ONEDIR=0
SIGN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-package) PACKAGE=0 ;;
    --skip-tests) RUN_TESTS=0 ;;
    --dir)        ONEDIR=1; PACKAGE=0 ;;
    --sign)       SIGN=1 ;;
    -h|--help)    awk 'NR>1 && /^#/ { sub(/^#[[:space:]]?/, ""); print; next }
                       NR>1 { exit }' "$SELF"; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\n\033[96m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── Platform ─────────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Linux)                      OS=linux;   PLATFORM="linux-$(uname -m)" ;;
  Darwin)                     OS=macos
                              case "$(uname -m)" in
                                arm64) PLATFORM="macos-arm64" ;;
                                *)     PLATFORM="macos-x86_64" ;;
                              esac ;;
  MINGW*|MSYS*|CYGWIN*)       OS=windows; PLATFORM="windows-x86_64" ;;
  *) die "Unsupported platform: $(uname -s)" ;;
esac

VERSION="$(tr -d '[:space:]' < version)"
say "EDSX ${VERSION} — ${PLATFORM}"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || die "No python3 on PATH. Set PYTHON=/path/to/python."
echo "python:      $("$PY" --version 2>&1)  ($(command -v "$PY"))"

# ── Preflight: the same paths the workflow's verify job checks ───────────────
# packaging/edsx.spec is the file most likely to be lost to .gitignore, and
# the failure it produces three steps later does not name the cause.
say "Preflight"
MISSING=0
for path in packaging/edsx.spec edsx.py version \
            licenses LICENSE THIRD-PARTY-NOTICES.md requirements-dev.txt; do
  [ -e "$path" ] || { echo "  missing: $path"; MISSING=1; }
done
[ "$MISSING" -eq 0 ] || die "Checkout is incomplete. Check .gitignore is not excluding these."

# Ignored-but-required: present here, so the build works locally and fails
# in CI.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  for path in packaging/edsx.spec edsx.py version; do
    if git check-ignore -q "$path" 2>/dev/null; then
      warn "$path is git-ignored — it will be missing from a CI checkout."
    fi
  done
fi

# edsx.py reads ./version at import time; edsx.spec bundles that same file
# for the frozen binary. Check agreement before spending minutes freezing.
REPORTED="$("$PY" edsx.py --version)"
[ "$REPORTED" = "$VERSION" ] \
  || die "edsx.py reports '$REPORTED' but the version file says '$VERSION'."
echo "  all required paths present; version $VERSION"

# ── Build tooling ────────────────────────────────────────────────────────────
# Nothing is needed at runtime beyond the standard library; PyInstaller is
# required only to freeze.
"$PY" - <<'EOF' || die "Build dependencies missing. Run: pip install -r requirements-dev.txt"
import importlib.util, sys
missing = [m for m in ("PyInstaller",) if importlib.util.find_spec(m) is None]
if missing:
    print("  missing modules: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
print("  build dependencies present")
EOF

# The frozen build fails the same way but with a worse error.
"$PY" -c "import edsx" >/dev/null \
  || die "edsx.py does not import cleanly — fix that before freezing."
echo "  edsx.py imports on a bare interpreter"

# ── Build ────────────────────────────────────────────────────────────────────
say "Building"
rm -rf build dist
if [ "$ONEDIR" -eq 1 ]; then
  "$PY" -m PyInstaller packaging/edsx.spec --noconfirm --clean -D
else
  "$PY" -m PyInstaller packaging/edsx.spec --noconfirm --clean
fi

case "$OS" in
  windows) BIN="dist/EDSX.exe" ;;
  *)       BIN="dist/EDSX" ;;
esac
[ -e "$BIN" ] || die "Build produced no $BIN — see the PyInstaller output above."
chmod +x "$BIN" 2>/dev/null || true
echo "  built: $BIN ($(du -h "$BIN" | cut -f1))"

# ── Smoke test ───────────────────────────────────────────────────────────────
# A binary can start and still have lost a module to PyInstaller's analysis,
# so --selftest exercises the parser and resolver inside the frozen build.
# It runs offline: no network, no cached data.
if [ "$RUN_TESTS" -eq 1 ] && [ "$ONEDIR" -eq 0 ]; then
  say "Smoke test"

  set +e
  OUTPUT="$("./$BIN" --version 2>&1)"; RC=$?
  set -e
  echo "  --- binary output (exit $RC) ---"
  printf '%s\n' "$OUTPUT" | sed 's/^/  /'
  echo "  --------------------------------"
  [ "$RC" -eq 0 ] || die "Binary exited with status $RC."

  ACTUAL="$(printf '%s\n' "$OUTPUT" | tail -n1 | tr -d '[:space:]')"
  [ -n "$ACTUAL" ] || die "No output from the binary."
  [ "$ACTUAL" = "$VERSION" ] \
    || die "Version mismatch: binary reported '$ACTUAL', version says '$VERSION'."
  echo "  version OK: $ACTUAL"

  set +e
  ST="$("./$BIN" --selftest 2>&1)"; RC=$?
  set -e
  printf '%s\n' "$ST" | sed 's/^/  /'
  [ "$RC" -eq 0 ] || die "Selftest failed with status $RC."
fi

# ── Package ──────────────────────────────────────────────────────────────────
# The binary embeds the CPython runtime and the PyInstaller bootloader, so
# every archive carries their licence texts.
if [ "$PACKAGE" -eq 1 ]; then
  say "Packaging"
  STEM="EDSX-${VERSION}-${PLATFORM}"

  case "$OS" in
    windows)
      if command -v 7z >/dev/null 2>&1; then
        7z a "dist/${STEM}.zip" "./dist/EDSX.exe" \
          ./LICENSE ./THIRD-PARTY-NOTICES.md ./licenses >/dev/null
      else
        "$PY" - "$STEM" <<'EOF'
import sys, zipfile
from pathlib import Path
stem = sys.argv[1]
with zipfile.ZipFile(f"dist/{stem}.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.write("dist/EDSX.exe", "EDSX.exe")
    for f in ("LICENSE", "THIRD-PARTY-NOTICES.md"):
        z.write(f, f)
    for p in Path("licenses").rglob("*"):
        if p.is_file():
            z.write(p, str(p))
EOF
      fi
      ART="dist/${STEM}.zip" ;;
    *)
      # Bare executable on macOS too: no .app bundle, so no ditto branch.
      tar -czf "dist/${STEM}.tar.gz" -C dist EDSX \
        -C .. LICENSE THIRD-PARTY-NOTICES.md licenses
      ART="dist/${STEM}.tar.gz" ;;
  esac
  echo "  packaged: $ART ($(du -h "$ART" | cut -f1))"

  # ── Optional signature, same key and namespace as the workflow ────────────
  if [ "$SIGN" -eq 1 ]; then
    if [ -z "${SIGNING_KEY:-}" ] && [ -z "${SIGNING_KEY_FILE:-}" ]; then
      warn "--sign given but neither SIGNING_KEY nor SIGNING_KEY_FILE is set; skipping."
    else
      KEY="${SIGNING_KEY_FILE:-}"
      TMPKEY=""
      if [ -z "$KEY" ]; then
        TMPKEY="$(mktemp)"; chmod 600 "$TMPKEY"
        printf '%s\n' "$SIGNING_KEY" > "$TMPKEY"
        KEY="$TMPKEY"
      fi
      ssh-keygen -Y sign -f "$KEY" -n "edsx.release" "$ART"
      [ -n "$TMPKEY" ] && rm -f "$TMPKEY"
      echo "  signed: ${ART}.sig"
    fi
  fi

  # ── Checksum ──────────────────────────────────────────────────────────────
  ( cd dist
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum EDSX-* | grep -v '\.sha256' | grep -v '\.sig' \
        > "EDSX-${VERSION}.sha256"
    else
      shasum -a 256 EDSX-* | grep -v '\.sha256' | grep -v '\.sig' \
        > "EDSX-${VERSION}.sha256"
    fi
    cat "EDSX-${VERSION}.sha256" | sed 's/^/  /' )

  say "Done"
  ls -la dist/
else
  say "Done"
  ls -la dist/
fi
