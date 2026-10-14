#!/usr/bin/env bash
# Secret-free, restartable downloader for one server-scoped donor prefix in B2.
# Every remote key and local path is fail-closed; downloads become visible only
# after a private-temp capture, size/hash validation, and atomic replacement.
set -uo pipefail

BUCKET="computational-genomics"
MANIFEST=".genome-manifest.json"
B2_VERSION="4.7.1"
MAX_STREAMS_PER_FILE=8
KEYRING_VERSION="25.7.0"
KEYRING_SERVICE="org.synthoria.genome-sync.b2"
B2_RUN=(uvx --from "b2==${B2_VERSION}" b2)

usage() {
  cat <<'EOF'
Explicitly synchronize your genome data.

USAGE:
  B2_APPLICATION_KEY_ID=<keyID> B2_APPLICATION_KEY=<appKey> \
    genome-sync setup [options] <donor>

  genome-sync [sync] [options]
  genome-sync status
  genome-sync destination <directory>

ONE-OFF / RECOVERY:
  B2_APPLICATION_KEY_ID=<keyID> B2_APPLICATION_KEY=<appKey> \
    genome-sync [options] <donor>

ARGUMENTS:
  donor          your registered donor id (for example syn3); setup only

OPTIONS:
  -d, --dest DIR       setup destination (suggested: ~/Genome/<donor>)
      --only WHICH     sync only one of: lab | results | ensemble
      --exclude WHICH  skip one of: lab | results | ensemble
      --prune          delete previously managed files that are absent from the
                       new active snapshot (default: keep them under _retained/)
      --jobs N         download up to N objects concurrently (default: 4,
                       range 1..16); verification and installation stay serial.
                       --jobs 1 is the fully serial path.
  -y, --yes            do not ask for confirmation
  -n, --dry-run        show what would change, then stop
  -h, --help           show this help

REMOTE LAYOUT:
  <sample>/lab/                     current verified raw/lab snapshot
  <sample>/results/                 current verified result snapshot
  ensemble/                         cross-assay view, when produced

LOCAL LAYOUT:
  AGENTS.md / CLAUDE.md              verified root brief for frontier agents
  <sample>/lab/                      current verified raw/lab files
  <sample>/results/                  current verified result files
  _retained/                         kept files no longer in the active snapshot
  .genome-manifest.json              active plan map and verified local hashes

Only stable lab and donor-results-completion/v3 views are eligible. The
embedded plan digest and activation timestamp prevent rollback; obsolete plan
directories and attempt trees are never download candidates.

SETUP AND UPDATES:
  setup asks for results, lab, or both (default: results), validates the scoped
  B2 key, stores it in the operating system's secure credential service, and
  remembers the selection, donor, and destination. Later interactive runs show
  the saved choice and allow a one-run section override; a one-off run asks the
  same question with "both" as its default. The selected sections are downloaded
  whole. Noninteractive callers pass --only or --exclude.
  Downloads are differential.
  Retention is the default: a previously managed file that is absent from the
  new active snapshot keeps its bytes but is moved to `_retained/` and recorded
  in the manifest's `retained_files` map instead of `files`, so the live tree
  always mirrors the active snapshot exactly. Deleting retained files is a
  separate explicit choice — pass --prune when you want them removed. A later
  snapshot that re-adds a retained file restores it from `_retained/` without
  re-downloading.
  `genome-sync destination <directory>` changes only the saved destination. It
  uses the existing Keychain/Credential Locker entry and never moves or syncs
  files; the directory must already exist.
  Windows currently requires Git Bash or WSL because this client is Bash.
EOF
}

COMMAND=""
case "${1:-}" in
  setup|sync|status|destination) COMMAND="$1"; shift ;;
esac
DEST=""; DEST_EXPLICIT=0; ONLY=""; EXCLUDE=""; FILTER_EXPLICIT=0
PRUNE=0; DRYRUN=0; ASSUME_YES=0; JOBS=4; JOBS_EXPLICIT=0; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -d|--dest) DEST="${2:?--dest needs a directory}"; DEST_EXPLICIT=1; shift 2 ;;
    --only) ONLY="${2:?--only needs lab|results|ensemble}"; FILTER_EXPLICIT=1; shift 2 ;;
    --exclude) EXCLUDE="${2:?--exclude needs lab|results|ensemble}"; FILTER_EXPLICIT=1; shift 2 ;;
    --prune) PRUNE=1; shift ;;
    --jobs) JOBS="${2:?--jobs needs a number 1..16}"; JOBS_EXPLICIT=1; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -n|--dry-run) DRYRUN=1; shift ;;
    --) shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done ;;
    -*) echo "unknown option: $1" >&2; usage; exit 1 ;;
    *) POS+=("$1"); shift ;;
  esac
done
set -- ${POS+"${POS[@]}"}
if [ -z "$COMMAND" ]; then
  if [ "$#" -gt 0 ]; then COMMAND="one-off"; else COMMAND="sync"; fi
fi
if [ "$#" -gt 1 ]; then
  echo "error: expected at most one donor argument" >&2
  usage >&2
  exit 1
fi
KEY_ID="${B2_APPLICATION_KEY_ID:-}"
APP_KEY="${B2_APPLICATION_KEY:-}"
DONOR="${1:-}"

for section in "$ONLY" "$EXCLUDE"; do
  case "$section" in
    ""|lab|results|ensemble) ;;
    *) echo "error: --only/--exclude must be lab, results, or ensemble (got '$section')" >&2; exit 1 ;;
  esac
done
if [ -n "$ONLY" ] && [ -n "$EXCLUDE" ]; then
  echo "error: use either --only or --exclude, not both" >&2
  exit 1
fi

case "$JOBS" in
  ''|*[!0-9]*) echo "error: --jobs must be an integer between 1 and 16 (got '$JOBS')" >&2; exit 1 ;;
esac
if [ "$JOBS" -lt 1 ] || [ "$JOBS" -gt 16 ]; then
  echo "error: --jobs must be between 1 and 16 (got '$JOBS')" >&2
  exit 1
fi

if [ "$COMMAND" != "destination" ] && ! command -v uvx >/dev/null 2>&1; then
  echo "error: uvx is required; install uv from https://docs.astral.sh/uv/" >&2
  exit 1
fi
if [ "$COMMAND" != "one-off" ] && [ "$COMMAND" != "destination" ] \
  && ! command -v uv >/dev/null 2>&1; then
  echo "error: uv is required for secure credential storage; reinstall uv from https://docs.astral.sh/uv/" >&2
  exit 1
fi
PY=()
# The console entry point passes the interpreter uv resolved for the package, so the
# embedded Python never depends on the donor's own python3 (stock macOS ships 3.9).
if [ -n "${GENOME_SYNC_PYTHON:-}" ] && [ -x "${GENOME_SYNC_PYTHON}" ]; then
  PY=("$GENOME_SYNC_PYTHON")
else
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then PY=("$candidate"); break; fi
  done
fi
[ "${#PY[@]}" -eq 0 ] && PY=(uv run --no-project python3)

CONFIG_ROOT="${XDG_CONFIG_HOME:-${HOME:?HOME is required}/.config}/genome-sync"
CONFIG_FILE="${CONFIG_ROOT}/config.json"
STATE_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/genome-sync"
LOG_FILE="${STATE_ROOT}/sync.log"

config_read() {
  "${PY[@]}" - "$CONFIG_FILE" <<'PYEOF'
import json
import os
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    observed = path.lstat()
except FileNotFoundError:
    raise SystemExit("genome-sync is not configured; run `genome-sync setup <donor>`")
if stat.S_ISLNK(observed.st_mode) or not stat.S_ISREG(observed.st_mode):
    raise SystemExit(f"unsafe genome-sync config path: {path}")
if observed.st_mode & 0o077:
    raise SystemExit(f"genome-sync config must be private (chmod 600 {path})")
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except (OSError, ValueError) as error:
    raise SystemExit(f"invalid genome-sync config: {error}") from error
schema_version = payload.get("schema_version")
# v3 configs carry a retired payload-selection key. Nothing picks payloads any
# more, so that key is simply not read: every donor who ran `setup` before this
# change holds a v3 file, and refusing it would strand them.
if schema_version not in {
    "genome-sync-config/v2",
    "genome-sync-config/v3",
    "genome-sync-config/v4",
}:
    raise SystemExit("unsupported genome-sync config schema")
donor = payload.get("donor")
destination = payload.get("destination")
only = payload.get("only", "")
exclude = payload.get("exclude", "")
if not isinstance(donor, str) or not donor or donor in {".", ".."} or any(character not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" for character in donor):
    raise SystemExit("invalid donor in genome-sync config")
if not isinstance(destination, str) or not os.path.isabs(destination) or any(character in destination for character in "\n\r\t"):
    raise SystemExit("invalid destination in genome-sync config")
if only not in {"", "lab", "results", "ensemble"} or exclude not in {"", "lab", "results", "ensemble"}:
    raise SystemExit("invalid section selection in genome-sync config")
if only and exclude:
    raise SystemExit("genome-sync config cannot combine only and exclude")
print(donor)
print(destination)
print(only)
print(exclude)
print("END", end="")
PYEOF
}

config_write() {
  local donor="$1"
  local destination="$2"
  local only="$3"
  local exclude="$4"
  "${PY[@]}" - "$CONFIG_ROOT" "$CONFIG_FILE" "$donor" "$destination" "$only" "$exclude" <<'PYEOF'
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
path = Path(sys.argv[2])
donor = sys.argv[3]
destination = sys.argv[4]
only = sys.argv[5]
exclude = sys.argv[6]
if root.exists():
    observed = root.lstat()
    if stat.S_ISLNK(observed.st_mode) or not stat.S_ISDIR(observed.st_mode):
        raise SystemExit(f"unsafe genome-sync config directory: {root}")
else:
    root.mkdir(parents=True, mode=0o700)
os.chmod(root, 0o700)
descriptor, temporary_name = tempfile.mkstemp(prefix="config.", dir=root)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "schema_version": "genome-sync-config/v4",
                "donor": donor,
                "destination": destination,
                "only": only,
                "exclude": exclude,
            },
            handle,
            sort_keys=True,
            separators=(",", ":"),
        )
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary_name, 0o600)
    os.replace(temporary_name, path)
    directory_fd = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
PYEOF
}

credential_store() {
  local operation="$1"
  local donor="$2"
  uv run --no-project --with "keyring==${KEYRING_VERSION}" python3 -c '
import json
import os
import sys

import keyring
from keyring.errors import KeyringError, PasswordDeleteError

operation, service, donor = sys.argv[1:]
backend = keyring.get_keyring()

def secure(candidate):
    module = type(candidate).__module__
    if module in {
        "keyring.backends.macOS",
        "keyring.backends.Windows",
        "keyring.backends.SecretService",
        "keyring.backends.kwallet",
    }:
        return True
    children = getattr(candidate, "backends", ())
    return bool(children) and all(secure(child) for child in children)

backend_name = f"{type(backend).__module__}.{type(backend).__qualname__}"
if not secure(backend):
    raise SystemExit(
        "no supported secure OS credential store is available "
        f"(detected {backend_name}); unlock/install Keychain, Credential Locker, "
        "Secret Service, or KWallet, then rerun setup"
    )

try:
    if operation == "set":
        key_id = os.environ.get("GENOME_SYNC_KEY_ID", "")
        application_key = os.environ.get("GENOME_SYNC_APPLICATION_KEY", "")
        if not key_id or not application_key:
            raise SystemExit("missing credentials for secure storage")
        keyring.set_password(
            service,
            donor,
            json.dumps(
                {"key_id": key_id, "application_key": application_key},
                sort_keys=True,
                separators=(",", ":"),
            ),
        )
    elif operation == "get":
        encoded = keyring.get_password(service, donor)
        if encoded is None:
            raise SystemExit(f"no stored credential for {donor}; rerun `genome-sync setup {donor}`")
        payload = json.loads(encoded)
        key_id = payload.get("key_id")
        application_key = payload.get("application_key")
        if not isinstance(key_id, str) or not key_id or not isinstance(application_key, str) or not application_key:
            raise SystemExit("stored genome-sync credential is malformed")
        print(key_id)
        print(application_key, end="")
    elif operation == "status":
        present = keyring.get_password(service, donor) is not None
        print(f"credential_backend={backend_name}")
        print(f"credential_present={str(present).lower()}")
    elif operation == "delete":
        try:
            keyring.delete_password(service, donor)
        except PasswordDeleteError:
            pass
    else:
        raise SystemExit(f"unsupported credential operation: {operation}")
except (KeyringError, ValueError, TypeError) as error:
    raise SystemExit(f"OS credential store failed: {error}") from error
' "$operation" "$KEYRING_SERVICE" "$donor"
}

config_field() {
  printf '%s\n' "$config_payload" | sed -n "${1}p"
}

config_payload=""
configured_destination=""
configured_only=""
configured_exclude=""
SETUP_REPEATED=0
case "$COMMAND" in
  setup)
    if [ -z "$DONOR" ] || [ -z "$KEY_ID" ] || [ -z "$APP_KEY" ]; then
      echo "error: setup needs B2_APPLICATION_KEY_ID, B2_APPLICATION_KEY, and <donor>" >&2
      usage >&2
      exit 1
    fi
    if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
      config_payload="$(config_read)" || exit 1
      configured_donor="$(config_field 1)"
      if [ "$(config_field 5)" != "END" ]; then
        echo "error: incomplete genome-sync config" >&2
        exit 1
      fi
      if [ "$configured_donor" = "$DONOR" ]; then
        configured_destination="$(config_field 2)"
        configured_only="$(config_field 3)"
        configured_exclude="$(config_field 4)"
        SETUP_REPEATED=1
        if [ "$FILTER_EXPLICIT" -eq 0 ]; then
          ONLY="$configured_only"
          EXCLUDE="$configured_exclude"
        fi
      fi
    fi
    ;;
  sync)
    if [ -n "$DONOR" ]; then
      echo "error: sync uses the configured donor; run setup to change it" >&2
      exit 1
    fi
    if [ "$DEST_EXPLICIT" -eq 1 ]; then
      echo "error: sync uses the configured destination; run setup --dest DIR to change it" >&2
      exit 1
    fi
    config_payload="$(config_read)" || exit 1
    DONOR="$(config_field 1)"
    DEST="$(config_field 2)"
    configured_only="$(config_field 3)"
    configured_exclude="$(config_field 4)"
    if [ "$(config_field 5)" != "END" ]; then
      echo "error: incomplete genome-sync config" >&2
      exit 1
    fi
    if [ "$FILTER_EXPLICIT" -eq 0 ]; then
      ONLY="$configured_only"
      EXCLUDE="$configured_exclude"
    fi
    DEST_EXPLICIT=1
    credential_payload="$(credential_store get "$DONOR")" || exit 1
    KEY_ID="${credential_payload%%$'\n'*}"
    APP_KEY="${credential_payload#*$'\n'}"
    unset credential_payload
    ;;
  status)
    if [ -n "$DONOR" ] || [ "$DEST_EXPLICIT" -eq 1 ] || [ -n "$ONLY" ] || [ -n "$EXCLUDE" ] \
      || [ "$PRUNE" -eq 1 ] || [ "$DRYRUN" -eq 1 ] \
      || [ "$JOBS_EXPLICIT" -eq 1 ]; then
      echo "error: status accepts no donor or sync options" >&2
      exit 1
    fi
    config_payload="$(config_read)" || exit 1
    DONOR="$(config_field 1)"
    DEST="$(config_field 2)"
    configured_only="$(config_field 3)"
    configured_exclude="$(config_field 4)"
    if [ "$(config_field 5)" != "END" ]; then
      echo "error: incomplete genome-sync config" >&2
      exit 1
    fi
    if [ -n "$configured_only" ]; then
      configured_selection="$configured_only"
    elif [ -n "$configured_exclude" ]; then
      configured_selection="all except ${configured_exclude}"
    else
      configured_selection="results and lab"
    fi
    printf 'donor=%s\ndestination=%s\ndefault_selection=%s\n' "$DONOR" "$DEST" "$configured_selection"
    credential_store status "$DONOR" || exit 1
    if [ -f "$DEST/$MANIFEST" ]; then
      printf 'local_manifest=%s\n' "$DEST/$MANIFEST"
    else
      printf 'local_manifest=missing\n'
    fi
    printf 'sync_log=%s\n' "$LOG_FILE"
    exit 0
    ;;
  destination)
    if [ -z "$DONOR" ] || [ "$DEST_EXPLICIT" -eq 1 ] || [ -n "$ONLY" ] \
      || [ -n "$EXCLUDE" ] \
      || [ "$PRUNE" -eq 1 ] || [ "$DRYRUN" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ] \
      || [ "$JOBS_EXPLICIT" -eq 1 ]; then
      echo "error: usage: genome-sync destination <directory>" >&2
      exit 1
    fi
    requested_destination="$DONOR"
    config_payload="$(config_read)" || exit 1
    DONOR="$(config_field 1)"
    configured_destination="$(config_field 2)"
    ONLY="$(config_field 3)"
    EXCLUDE="$(config_field 4)"
    if [ "$(config_field 5)" != "END" ]; then
      echo "error: incomplete genome-sync config" >&2
      exit 1
    fi
    DEST="$requested_destination"
    DEST_EXPLICIT=1
    ;;
  one-off)
    if [ -z "$KEY_ID" ] || [ -z "$APP_KEY" ] || [ -z "$DONOR" ]; then
      echo "error: one-off sync needs B2_APPLICATION_KEY_ID, B2_APPLICATION_KEY, and <donor>" >&2
      usage >&2
      exit 1
    fi
    ;;
esac

case "$DONOR" in
  *[!A-Za-z0-9._-]*|.|..) echo "error: donor must be one canonical path segment" >&2; exit 1 ;;
esac

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; BL=$'\033[36m'; Y=$'\033[33m'; R=$'\033[31m'; X=$'\033[0m'
else
  B=""; D=""; G=""; BL=""; Y=""; R=""; X=""
fi
hr() { printf "%s────────────────────────────────────────────────────────%s\n" "$D" "$X"; }
say() { printf "%b\n" "$*"; }
human() { awk "BEGIN{ bytes=$1; if(bytes>=1073741824) printf \"%.1f GB\", bytes/1073741824; else if(bytes>=1048576) printf \"%.1f MB\", bytes/1048576; else printf \"%.0f KB\", bytes/1024 }"; }
selection_label() {
  if [ -n "$ONLY" ]; then
    printf '%s only' "$ONLY"
  elif [ -n "$EXCLUDE" ]; then
    printf 'everything except %s' "$EXCLUDE"
  else
    printf 'results and lab'
  fi
}
progress_subject() {
  local relative="$1"
  local remainder stage filename
  filename="${relative##*/}"
  case "$relative" in
    AGENTS.md|CLAUDE.md|README.md|TOC.md) printf 'bundle guide · %s' "$filename" ;;
    */results/papers/index.json) printf 'papers index' ;;
    */results/*/*)
      remainder="${relative#*/results/}"
      stage="${remainder%%/*}"
      printf 'stage: %s · %s' "$stage" "$filename"
      ;;
    */results/*) printf 'results manifest · %s' "$filename" ;;
    */lab/*) printf 'lab · %s' "$filename" ;;
    ensemble/*) printf 'ensemble · %s' "$filename" ;;
    *) printf '%s' "$relative" ;;
  esac
}
PROGRESS_FILLED="########################"
PROGRESS_EMPTY="------------------------"
PROGRESS_ACTIVE=0
render_progress() {
  local completed_bytes="$1"
  local total_bytes="$2"
  local completed_files="$3"
  local total_files="$4"
  local label="$5"
  local percent filled empty display
  [ -t 1 ] || return 0
  if [ "$total_bytes" -gt 0 ]; then
    percent=$((completed_bytes * 100 / total_bytes))
  else
    percent=$((completed_files * 100 / total_files))
  fi
  [ "$percent" -gt 100 ] && percent=100
  filled=$((percent * 24 / 100))
  empty=$((24 - filled))
  display="$label"
  [ "${#display}" -gt 42 ] && display="…${display: -41}"
  printf '\r  [%s%s] %3d%%  %d/%d  %-42s\033[K' \
    "${PROGRESS_FILLED:0:filled}" "${PROGRESS_EMPTY:0:empty}" \
    "$percent" "$completed_files" "$total_files" "$display"
  PROGRESS_ACTIVE=1
}
progress_newline() {
  if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
    printf '\n'
    PROGRESS_ACTIVE=0
  fi
}
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if [ -e /dev/tty ]; then
    printf "%b %s[Y/n]%s " "$1" "$D" "$X" > /dev/tty
    local answer
    read -r answer < /dev/tty || answer=""
    case "$answer" in [Nn]*) return 1 ;; *) return 0 ;; esac
  fi
  return 0
}

# All destination operations go through one no-follow dirfd guard. The root is
# lexical (never realpath-resolved through a symlink), and every existing path
# component must be a real directory or regular file as appropriate.
fs_guard() {
  local operation="$1"
  shift
  "${PY[@]}" - "$operation" "$DEST_ABS" "$@" <<'PYEOF'
import errno
import gzip
import hashlib
import os
import stat
import sys
import zlib
from pathlib import Path, PurePosixPath

operation, root_text, *arguments = sys.argv[1:]
root = Path(root_text)
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)

def fail(message):
    raise SystemExit(f"unsafe recipient path: {message}")

def validate_relative(value):
    if not value or "\\" in value or "\x00" in value or "\t" in value or "\n" in value:
        fail("relative path is not canonical")
    path = PurePosixPath(value)
    if path.is_absolute() or path.as_posix() != value or any(part in {"", ".", ".."} for part in path.parts):
        fail("relative path is not canonical")
    return path.parts

def open_root(create=False):
    if not root.is_absolute():
        fail("destination root is not absolute")
    current_fd = os.open(root.anchor, flags)
    try:
        for part in root.parts[1:]:
            if create:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=current_fd)
                except FileExistsError:
                    pass
            try:
                child_fd = os.open(part, flags, dir_fd=current_fd)
            except OSError as error:
                fail(f"destination ancestor is not a real directory: {part}: {error}")
            os.close(current_fd)
            current_fd = child_fd
        return current_fd
    except BaseException:
        os.close(current_fd)
        raise

def validate_root(create=False):
    root_fd = open_root(create=create)
    os.close(root_fd)

def open_parent(relative, create=False):
    parts = validate_relative(relative)
    parent_fd = open_root()
    try:
        for part in parts[:-1]:
            if create:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=parent_fd)
                except FileExistsError:
                    pass
            child_fd = os.open(part, flags, dir_fd=parent_fd)
            os.close(parent_fd)
            parent_fd = child_fd
        return parent_fd, parts[-1]
    except Exception:
        os.close(parent_fd)
        raise

def validate_tree(directory_fd, display):
    try:
        names = os.listdir(directory_fd)
    except OSError as error:
        fail(f"could not list destination directory {display}: {error}")
    for name in names:
        display_path = f"{display}/{name}"
        try:
            observed = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError as error:
            fail(f"destination changed during validation at {display_path}: {error}")
        if stat.S_ISLNK(observed.st_mode):
            fail(f"symlink found inside destination: {display_path}")
        if stat.S_ISDIR(observed.st_mode):
            try:
                child_fd = os.open(name, flags, dir_fd=directory_fd)
            except OSError as error:
                fail(f"destination directory changed during validation at {display_path}: {error}")
            try:
                validate_tree(child_fd, display_path)
            finally:
                os.close(child_fd)
        elif not stat.S_ISREG(observed.st_mode):
            fail(f"non-regular file found inside destination: {display_path}")

validate_root(create=operation == "create-root")

if operation in {"validate-root", "create-root"}:
    pass
elif operation == "validate-tree":
    root_fd = open_root()
    try:
        validate_tree(root_fd, str(root))
    finally:
        os.close(root_fd)
elif operation == "prepare":
    parent_fd, name = open_parent(arguments[0], create=True)
    try:
        try:
            observed = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            observed = None
        if observed is not None and not stat.S_ISREG(observed.st_mode):
            fail(f"target is not a regular file: {arguments[0]}")
    finally:
        os.close(parent_fd)
elif operation == "hash":
    parent_fd, name = open_parent(arguments[0])
    try:
        file_fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
        try:
            before = os.fstat(file_fd)
            if not stat.S_ISREG(before.st_mode):
                fail(f"hash target is not regular: {arguments[0]}")
            sha1 = hashlib.sha1(usedforsecurity=False)
            sha256 = hashlib.sha256()
            while True:
                chunk = os.read(file_fd, 8 * 1024 * 1024)
                if not chunk:
                    break
                sha1.update(chunk)
                sha256.update(chunk)
            after = os.fstat(file_fd)
            identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
            if identity(before) != identity(after):
                fail(f"file changed while hashing: {arguments[0]}")
            print(f"{after.st_size}\t{sha1.hexdigest()}\t{sha256.hexdigest()}")
        finally:
            os.close(file_fd)
    finally:
        os.close(parent_fd)
elif operation == "copy":
    relative, temporary_text = arguments
    temporary = Path(temporary_text)
    try:
        temporary.relative_to(root)
    except ValueError:
        fail("temporary reuse copy escaped destination root")
    temp_stat = temporary.lstat()
    if stat.S_ISLNK(temp_stat.st_mode) or not stat.S_ISREG(temp_stat.st_mode):
        fail("temporary reuse target is not a regular file")
    parent_fd, name = open_parent(relative)
    try:
        source_fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
        try:
            before = os.fstat(source_fd)
            if not stat.S_ISREG(before.st_mode):
                fail(f"reuse source is not regular: {relative}")
            temporary_fd = os.open(
                temporary,
                os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                sha1 = hashlib.sha1(usedforsecurity=False)
                sha256 = hashlib.sha256()
                copied = 0
                while True:
                    chunk = os.read(source_fd, 8 * 1024 * 1024)
                    if not chunk:
                        break
                    sha1.update(chunk)
                    sha256.update(chunk)
                    copied += len(chunk)
                    remaining = memoryview(chunk)
                    while remaining:
                        written = os.write(temporary_fd, remaining)
                        if written <= 0:
                            fail(f"could not copy reuse source: {relative}")
                        remaining = remaining[written:]
                os.fsync(temporary_fd)
            finally:
                os.close(temporary_fd)
            after = os.fstat(source_fd)
            identity = lambda value: (
                value.st_dev,
                value.st_ino,
                value.st_mode,
                value.st_size,
                value.st_mtime_ns,
                value.st_ctime_ns,
            )
            if identity(before) != identity(after) or copied != after.st_size:
                fail(f"reuse source changed while copying: {relative}")
            print(f"{copied}\t{sha1.hexdigest()}\t{sha256.hexdigest()}")
        finally:
            os.close(source_fd)
    finally:
        os.close(parent_fd)
elif operation == "gunzip":
    # Stream-decode one verified gzip transport object (a private temp under the
    # destination) into a second private temp and hash the decoded bytes. Output
    # is capped at the activated logical size: a stream that decodes to more is
    # rejected after at most that size plus one byte (decompression-bomb guard).
    source_relative, target_text, limit_text = arguments
    if not limit_text.isdigit():
        fail("decode limit is not a non-negative integer")
    limit = int(limit_text)
    target = Path(target_text)
    try:
        target.relative_to(root)
    except ValueError:
        fail("temporary decode target escaped destination root")
    target_stat = target.lstat()
    if stat.S_ISLNK(target_stat.st_mode) or not stat.S_ISREG(target_stat.st_mode):
        fail("temporary decode target is not a regular file")
    parent_fd, name = open_parent(source_relative)
    try:
        source_fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
    finally:
        os.close(parent_fd)
    with os.fdopen(source_fd, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            fail(f"decode source is not regular: {source_relative}")
        target_fd = os.open(target, os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0))
        try:
            sha1 = hashlib.sha1(usedforsecurity=False)
            sha256 = hashlib.sha256()
            decoded = 0
            with gzip.GzipFile(fileobj=source, mode="rb") as stream:
                while True:
                    try:
                        chunk = stream.read(min(8 * 1024 * 1024, limit - decoded + 1))
                    except (OSError, EOFError, zlib.error) as error:
                        raise SystemExit(
                            f"transport object is not a valid gzip stream: {source_relative}: {error}"
                        ) from None
                    if not chunk:
                        break
                    decoded += len(chunk)
                    if decoded > limit:
                        raise SystemExit(
                            f"transport decode exceeds the activated logical size of {limit} bytes: {source_relative}"
                        )
                    sha1.update(chunk)
                    sha256.update(chunk)
                    remaining = memoryview(chunk)
                    while remaining:
                        written = os.write(target_fd, remaining)
                        if written <= 0:
                            fail(f"could not write decoded transport object: {source_relative}")
                        remaining = remaining[written:]
            os.fsync(target_fd)
        finally:
            os.close(target_fd)
        after = os.fstat(source.fileno())
    identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    if identity(before) != identity(after):
        fail(f"transport object changed while decoding: {source_relative}")
    print(f"{decoded}\t{sha1.hexdigest()}\t{sha256.hexdigest()}")
elif operation == "install":
    relative, temporary_text = arguments
    temporary = Path(temporary_text)
    try:
        temporary.relative_to(root)
    except ValueError:
        fail("temporary download escaped destination root")
    temp_stat = temporary.lstat()
    if stat.S_ISLNK(temp_stat.st_mode) or not stat.S_ISREG(temp_stat.st_mode):
        fail("temporary download is not a regular file")
    parent_fd, name = open_parent(relative, create=True)
    try:
        try:
            target_stat = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            target_stat = None
        if target_stat is not None and not stat.S_ISREG(target_stat.st_mode):
            fail(f"replacement target is not regular: {relative}")
        os.replace(temporary, name, dst_dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)
elif operation == "remove":
    parent_fd, name = open_parent(arguments[0])
    try:
        observed = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(observed.st_mode):
            fail(f"prune target is not regular: {arguments[0]}")
        os.unlink(name, dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)
elif operation == "move":
    # Same-filesystem rename of one managed regular file to another managed
    # path (retention attic). Never copies: a move either fully lands or the
    # source is untouched, so retained bytes cannot be half-transferred.
    source_relative, target_relative = arguments
    source_parent_fd, source_name = open_parent(source_relative)
    try:
        observed = os.stat(source_name, dir_fd=source_parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(observed.st_mode):
            fail(f"move source is not regular: {source_relative}")
        target_parent_fd, target_name = open_parent(target_relative, create=True)
        try:
            try:
                target_stat = os.stat(target_name, dir_fd=target_parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                target_stat = None
            if target_stat is not None and not stat.S_ISREG(target_stat.st_mode):
                fail(f"move target is not regular: {target_relative}")
            os.rename(
                source_name,
                target_name,
                src_dir_fd=source_parent_fd,
                dst_dir_fd=target_parent_fd,
            )
            os.fsync(target_parent_fd)
            os.fsync(source_parent_fd)
        finally:
            os.close(target_parent_fd)
    finally:
        os.close(source_parent_fd)
elif operation == "prune-empty-parents":
    relative = PurePosixPath(*validate_relative(arguments[0]))
    parent_parts = relative.parts[:-1]
    for depth in range(len(parent_parts), 0, -1):
        candidate = PurePosixPath(*parent_parts[:depth]).as_posix()
        parent_fd, name = open_parent(candidate)
        try:
            try:
                observed = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if not stat.S_ISDIR(observed.st_mode):
                fail(f"prune parent is not a directory: {candidate}")
            try:
                os.rmdir(name, dir_fd=parent_fd)
            except OSError as error:
                if error.errno in {errno.ENOTEMPTY, errno.EEXIST}:
                    break
                raise
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
else:
    fail(f"unknown guard operation: {operation}")
PYEOF
}

manifest_donor() {
  [ -f "$1/$MANIFEST" ] || return 0
  "${PY[@]}" - "$1/$MANIFEST" <<'PYEOF'
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("donor", "")
except (OSError, ValueError, AttributeError):
    value = ""
print(value if isinstance(value, str) else "")
PYEOF
}

say "\n${B}${BL}  Your genome data — ${DONOR}${X}"
hr
if { [ "$COMMAND" = "sync" ] || [ "$COMMAND" = "one-off" ]; } && [ "$FILTER_EXPLICIT" -eq 0 ] \
  && [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
  # A one-off run has no saved configuration, so "results and lab" would be a
  # fallback presented as a decision. Ask, defaulting to the same both.
  if [ "$COMMAND" = "one-off" ]; then
    saved_selection="both"
  else
    saved_selection="$(selection_label)"
  fi
  while :; do
    printf "%b" "  What should be synced? results, lab, or both ${D}[${saved_selection}]${X} " > /dev/tty
    read -r selected_section < /dev/tty || selected_section=""
    case "$selected_section" in
      "") break ;;
      results|r) ONLY="results"; EXCLUDE=""; break ;;
      lab|l) ONLY="lab"; EXCLUDE=""; break ;;
      both|b) ONLY=""; EXCLUDE=""; break ;;
      *) say "  ${Y}Enter results, lab, or both.${X}" ;;
    esac
  done
fi
if [ "$COMMAND" = "setup" ] && [ "$FILTER_EXPLICIT" -eq 0 ]; then
  if [ "$SETUP_REPEATED" -eq 0 ]; then
    ONLY="results"
    EXCLUDE=""
    saved_selection="results"
  else
    saved_selection="$(selection_label)"
  fi
  if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
    while :; do
      printf "%b" "  Sync results, lab, or both? ${D}[${saved_selection}]${X} " > /dev/tty
      read -r selected_section < /dev/tty || selected_section=""
      case "$selected_section" in
        "") break ;;
        results|r) ONLY="results"; EXCLUDE=""; break ;;
        lab|l) ONLY="lab"; EXCLUDE=""; break ;;
        both|b) ONLY=""; EXCLUDE=""; break ;;
        *) say "  ${Y}Enter results, lab, or both.${X}" ;;
      esac
    done
  fi
fi
if [ "$DEST_EXPLICIT" -eq 0 ]; then
  if [ "$COMMAND" = "setup" ]; then
    if [ "$SETUP_REPEATED" -eq 1 ]; then
      suggested_destination="$configured_destination"
    else
      suggested_destination="${HOME}/Genome/${DONOR}"
    fi
    DEST="$suggested_destination"
    if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
      printf "%b" "  Save your genome data where? ${D}[${suggested_destination}]${X} " > /dev/tty
      read -r chosen_destination < /dev/tty || chosen_destination=""
      [ -n "$chosen_destination" ] && DEST="$chosen_destination"
    fi
  else
    DEST="./${DONOR}-genome"
  fi
fi
DEST_ABS="$("${PY[@]}" - "$DEST" <<'PYEOF'
import os, sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PYEOF
)"
if [ "$COMMAND" = "destination" ]; then
  if [ ! -d "$DEST_ABS" ]; then
    echo "error: destination must already exist: $DEST_ABS" >&2
    echo "genome-sync does not move files; move or create the folder first" >&2
    exit 1
  fi
  fs_guard validate-root || exit 1
  existing_donor="$(manifest_donor "$DEST_ABS")"
  if [ -n "$existing_donor" ] && [ "$existing_donor" != "$DONOR" ]; then
    echo "error: $DEST_ABS belongs to donor $existing_donor, not $DONOR" >&2
    exit 1
  fi
  if ! config_write "$DONOR" "$DEST_ABS" "$ONLY" "$EXCLUDE"; then
    echo "error: could not save the new genome-sync destination" >&2
    exit 1
  fi
  printf 'destination changed\nfrom=%s\nto=%s\n' "$configured_destination" "$DEST_ABS"
  printf 'No files were moved or synchronized. Run `genome-sync` to check the new folder.\n'
  exit 0
fi
say "  ${B}Selection:${X}   $(selection_label)"
say "  ${B}Destination:${X} ${DEST_ABS}"
say "  ${B}Source:${X}      b2://${BUCKET}/${DONOR}/"
say "  ${D}Safety: files must belong to a completed snapshot and match its manifest hashes.${X}"
fs_guard create-root || exit 1
fs_guard validate-tree || exit 1

existing_donor="$(manifest_donor "$DEST_ABS")"
if [ -n "$existing_donor" ] && [ "$existing_donor" != "$DONOR" ]; then
  say "\n${R}  Refusing to sync.${X} ${B}${DEST_ABS}${X} belongs to ${B}${existing_donor}${X}, not ${DONOR}."
  exit 1
fi
if [ -z "$existing_donor" ]; then
  if [ -n "$(find "$DEST_ABS" -type f ! -name '.*' -print -quit 2>/dev/null)" ]; then
    say "  ${Y}${DEST_ABS} has files but no valid genome manifest.${X}"
    confirm "  Sync into it anyway?" || exit 1
  elif [ "$DEST_EXPLICIT" -eq 0 ]; then
    confirm "  Download to ${B}${DEST_ABS}${X}?" || exit 1
  fi
fi

CONTROL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/genome-download.XXXXXX")" || exit 1
chmod 700 "$CONTROL_DIR"
TEMP_ROOT="$(mktemp -d "${DEST_ABS}/.genome-download-tmp.XXXXXX")" || exit 1
chmod 700 "$TEMP_ROOT"
RAWJSON="$CONTROL_DIR/remote.json"
VERIFIED="$CONTROL_DIR/verified.tsv"
FILTERED="$CONTROL_DIR/filtered.tsv"
# Nothing is selectable any more, so this partition file stays empty. It is still
# written and read: the manifest's `omitted_files` field and its partition
# invariant carried over from schema 5 into schema 6, which donors already hold.
OMITTED="$CONTROL_DIR/omitted.tsv"
TODO="$CONTROL_DIR/todo.tsv"
PRUNES="$CONTROL_DIR/prunes.txt"
RELS="$CONTROL_DIR/remote-rels.txt"
HASHES="$CONTROL_DIR/local-hashes.tsv"
ACTIVE_RESULTS="$CONTROL_DIR/active-results.json"
LOCAL_INDEX="$CONTROL_DIR/local-content-index.tsv"
SESSION_LOG="$CONTROL_DIR/sync.log"
touch "$VERIFIED" "$FILTERED" "$OMITTED" "$TODO" "$PRUNES" "$HASHES" "$LOCAL_INDEX"
printf '{}\n' > "$ACTIVE_RESULTS"
LOG_PERSISTED=0
download_process_id=""
PREFETCH_DIR=""
PREFETCH_PIDS=""
PREFETCH_PRODUCER_PID=""
PREFETCH_SLOTS_FIFO=""
log_event() {
  printf '%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$SESSION_LOG"
}
persist_log() {
  [ "$LOG_PERSISTED" -eq 1 ] && return 0
  LOG_PERSISTED=1
  [ -s "$SESSION_LOG" ] || return 0
  "${PY[@]}" - "$STATE_ROOT" "$LOG_FILE" "$SESSION_LOG" <<'PYEOF'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
path = Path(sys.argv[2])
session = Path(sys.argv[3])
if root.exists():
    observed = root.lstat()
    if stat.S_ISLNK(observed.st_mode) or not stat.S_ISDIR(observed.st_mode):
        raise SystemExit(f"unsafe genome-sync state directory: {root}")
else:
    root.mkdir(parents=True, mode=0o700)
os.chmod(root, 0o700)
flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags, 0o600)
try:
    observed = os.fstat(descriptor)
    if not stat.S_ISREG(observed.st_mode):
        raise SystemExit(f"unsafe genome-sync log path: {path}")
    os.fchmod(descriptor, 0o600)
    payload = session.read_bytes()
    while payload:
        written = os.write(descriptor, payload)
        if written <= 0:
            raise SystemExit("could not append genome-sync log")
        payload = payload[written:]
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PYEOF
}
stop_prefetch() {
  # Best-effort teardown of the background producer and any in-flight download
  # workers. Workers only ever write inside TEMP_ROOT, so a late worker cannot
  # corrupt the destination; this only avoids leaving orphaned b2 processes.
  [ -n "$PREFETCH_PRODUCER_PID" ] && kill -TERM "$PREFETCH_PRODUCER_PID" 2>/dev/null
  if [ -n "$PREFETCH_PIDS" ] && [ -f "$PREFETCH_PIDS" ]; then
    while IFS= read -r prefetch_worker_pid; do
      [ -n "$prefetch_worker_pid" ] && kill -TERM "$prefetch_worker_pid" 2>/dev/null
    done < "$PREFETCH_PIDS"
  fi
}
cleanup() {
  local exit_code=$?
  stop_prefetch
  if [ "$exit_code" -ne 0 ]; then
    log_event "finish status=failed exit_code=${exit_code}"
  fi
  persist_log >/dev/null 2>&1 || true
  rm -rf -- "$TEMP_ROOT" "$CONTROL_DIR"
  return "$exit_code"
}
terminate() {
  local exit_code="$1"
  trap - HUP INT TERM
  stop_prefetch
  if [ -n "$download_process_id" ] && kill -0 "$download_process_id" 2>/dev/null; then
    kill -TERM "$download_process_id" 2>/dev/null || true
    wait "$download_process_id" 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'terminate 129' HUP
trap 'terminate 130' INT
trap 'terminate 143' TERM
log_event "start donor=${DONOR} selection=$(selection_label) destination=${DEST_ABS} source=b2://${BUCKET}/${DONOR}/"

export PYTHONWARNINGS=ignore
export B2_ACCOUNT_INFO="$CONTROL_DIR/b2-account-info"
B2_APPLICATION_KEY_ID="$KEY_ID" B2_APPLICATION_KEY="$APP_KEY" \
  "${B2_RUN[@]}" account authorize >/dev/null \
  || { say "\n${R}  Authorization failed.${X}"; exit 1; }
say "  ${D}Connected with verified B2 client ${B2_VERSION}.${X}"
"${B2_RUN[@]}" ls --recursive --json "b2://${BUCKET}/${DONOR}/" > "$RAWJSON" \
  || { say "\n${R}  Could not list your files.${X}"; exit 1; }

"${PY[@]}" - "$RAWJSON" "$DONOR" "$ONLY" "$EXCLUDE" "$BUCKET" "$CONTROL_DIR" "$B2_VERSION" "$DEST_ABS" "$ACTIVE_RESULTS" <<'PYEOF' > "$VERIFIED" \
  || { say "\n${R}  The remote listing or activation evidence violated the donor contract.${X}"; exit 1; }
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path, PurePosixPath

(
    _,
    path,
    donor,
    only,
    exclude,
    bucket,
    control_dir_text,
    b2_version,
    destination_text,
    active_results_path_text,
) = sys.argv
payload = json.load(open(path, encoding="utf-8"))
if not isinstance(payload, list):
    raise SystemExit("B2 listing is not a list")

SHA1_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
LAB_RE = re.compile(r"^([^/]+)/lab/(.+)$")
RESULTS_RE = re.compile(r"^([^/]+)/results/(.+)$")
control_dir = Path(control_dir_text)
destination_root = Path(destination_text)
active_results_path = Path(active_results_path_text)
ROOT_AGENT_ASSETS = ("AGENTS.md", "CLAUDE.md", "README.md")

@dataclass(frozen=True)
class RemoteObject:
    key: str
    relative: str
    size: int
    remote_sha1: str
    section: str

@dataclass(frozen=True)
class ResultsActivation:
    assay: str
    sample_id: str
    plan_sha256: str
    authorized_at: datetime
    authorized_at_text: str
    marker_sha256: str
    expected_sha256: dict[str, str]
    # Stored key -> (logical local path, logical bytes, logical SHA-256) for each
    # gzip transport object; the donor's tree holds only the decoded form.
    encoded: dict[str, tuple[str, int, str]]
    group: tuple[RemoteObject, ...]

def canonical_relative(value):
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value or "\t" in value or "\n" in value:
        raise SystemExit(f"noncanonical B2 key suffix: {value!r}")
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or parsed.as_posix() != value or any(part in {"", ".", ".."} for part in parsed.parts):
        raise SystemExit(f"noncanonical B2 key suffix: {value!r}")
    if parsed.parts[0] == "_retained":
        # `_retained/` is the client-owned retention attic; a remote snapshot
        # must never be able to write into or shadow that namespace.
        raise SystemExit(f"remote path collides with the local retention attic: {value!r}")
    return value

def canonical_segment(value, *, field):
    if (
        not isinstance(value, str)
        or not value
        or value in {".", ".."}
        or re.fullmatch(r"[A-Za-z0-9._-]+", value) is None
    ):
        raise SystemExit(f"noncanonical {field}: {value!r}")
    return value

def section_of(relative):
    if relative.startswith("ensemble/"):
        return "ensemble"
    if "/lab/" in relative or relative.endswith("/lab"):
        return "lab"
    return "results"

def strict_json(content, *, label):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(content, object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise SystemExit(f"invalid {label}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must be a JSON object")
    return value

def read_regular(source, *, label):
    descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise SystemExit(f"{label} is not a regular file")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
        identity = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
        if identity(before) != identity(after):
            raise SystemExit(f"{label} changed while being read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)

def capture_control(remote, *, label):
    name = hashlib.sha256(remote.key.encode()).hexdigest()
    destination = control_dir / f"activation-{name}.json"
    command = [
        "uvx",
        "--from",
        f"b2=={b2_version}",
        "b2",
        "file",
        "download",
        f"b2://{bucket}/{remote.key}",
        str(destination),
    ]
    completed = subprocess.run(command, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        diagnostic = (completed.stderr or completed.stdout).strip()[-500:]
        raise SystemExit(f"could not capture {label}: {diagnostic}")
    content = read_regular(destination, label=label)
    if len(content) != remote.size:
        raise SystemExit(f"{label} size differs from the B2 listing")
    observed_sha1 = hashlib.sha1(content, usedforsecurity=False).hexdigest()
    if remote.remote_sha1 != "unverified" and observed_sha1 != remote.remote_sha1:
        raise SystemExit(f"{label} SHA-1 differs from the B2 listing")
    return content

def require_nonnegative_integer(value, *, field):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise SystemExit(f"{field} must be a non-negative integer")
    return value

def resolve_lab_activation(*, assay, group):
    """Validate and bind one exact stable lab activation."""

    prefix = f"{assay}/lab/"
    by_suffix = {remote.relative[len(prefix):]: remote for remote in group}
    marker = by_suffix.get("_COMPLETE.json")
    manifest = by_suffix.get("lab_manifest.json")
    if marker is None or manifest is None:
        raise SystemExit(f"incomplete lab plan prefix: {prefix}")

    marker_bytes = capture_control(marker, label=f"lab activation marker {prefix}")
    manifest_bytes = capture_control(manifest, label=f"lab manifest {prefix}")
    plan_sha256 = hashlib.sha256(manifest_bytes).hexdigest()

    marker_payload = strict_json(marker_bytes, label=f"lab activation marker {prefix}")
    required_marker_fields = {
        "schema_version",
        "sink",
        "sample_id",
        "plan_sha256",
        "object_count",
        "selected_bytes",
    }
    if set(marker_payload) != required_marker_fields:
        raise SystemExit(f"lab activation marker has an unexpected schema: {prefix}")
    if marker_payload["schema_version"] != "donor-lab-completion/v1" or marker_payload["sink"] != "b2":
        raise SystemExit(f"lab activation marker has the wrong contract or sink: {prefix}")
    canonical_segment(marker_payload["sample_id"], field="marker sample_id")
    if marker_payload["plan_sha256"] != plan_sha256:
        raise SystemExit(f"lab activation marker does not bind lab_manifest.json: {prefix}")
    marker_count = require_nonnegative_integer(marker_payload["object_count"], field="marker object_count")
    marker_selected_bytes = require_nonnegative_integer(marker_payload["selected_bytes"], field="marker selected_bytes")

    plan = strict_json(manifest_bytes, label=f"lab manifest {prefix}")
    if (
        plan.get("schema_version") != "donor-lab-plan/v1"
        or plan.get("mode") != "lab"
        or plan.get("disposition") != "publish"
    ):
        raise SystemExit(f"lab manifest is not one publishable DonorLabPlanV1: {prefix}")
    if plan.get("donor_id") != donor or plan.get("assay_id") != assay:
        raise SystemExit(f"lab manifest identity differs from its donor/assay path: {prefix}")
    if plan.get("sample_id") != marker_payload["sample_id"]:
        raise SystemExit(f"lab marker and manifest sample identity disagree: {prefix}")
    plan_count = require_nonnegative_integer(plan.get("selected_object_count"), field="plan selected_object_count")
    plan_selected_bytes = require_nonnegative_integer(plan.get("selected_bytes"), field="plan selected_bytes")
    objects = plan.get("objects")
    if not isinstance(objects, list) or not objects:
        raise SystemExit(f"publishable lab manifest requires a non-empty objects list: {prefix}")

    expected = {}
    selected_bytes = 0
    for item in objects:
        if not isinstance(item, dict) or set(item) != {"relative_path", "role", "bytes", "sha256"}:
            raise SystemExit(f"lab manifest object has an unexpected schema: {prefix}")
        relative_path = canonical_relative(item["relative_path"])
        if relative_path in {"_COMPLETE.json", "lab_manifest.json"} or relative_path in expected:
            raise SystemExit(f"lab manifest object paths are duplicate or reserved: {prefix}")
        object_bytes = require_nonnegative_integer(item["bytes"], field=f"object bytes {relative_path}")
        object_sha256 = item["sha256"]
        if not isinstance(object_sha256, str) or SHA256_RE.fullmatch(object_sha256) is None:
            raise SystemExit(f"lab manifest object SHA-256 is invalid: {relative_path}")
        expected[relative_path] = (object_bytes, object_sha256)
        selected_bytes += object_bytes
    if list(expected) != sorted(expected):
        raise SystemExit(f"lab manifest object paths are not canonical sorted order: {prefix}")
    if plan_count != len(expected) or marker_count != len(expected):
        raise SystemExit(f"lab object count differs across marker, manifest, and objects: {prefix}")
    if plan_selected_bytes != selected_bytes or marker_selected_bytes != selected_bytes:
        raise SystemExit(f"lab selected bytes differ across marker, manifest, and objects: {prefix}")

    expected_suffixes = set(expected) | {"lab_manifest.json", "_COMPLETE.json"}
    if set(by_suffix) != expected_suffixes:
        missing = sorted(expected_suffixes - set(by_suffix))[:5]
        extra = sorted(set(by_suffix) - expected_suffixes)[:5]
        raise SystemExit(f"lab plan listing differs from its manifest: missing={missing} extra={extra}")
    for relative_path, (object_bytes, _sha256) in expected.items():
        if by_suffix[relative_path].size != object_bytes:
            raise SystemExit(f"lab object size differs from manifest: {prefix}{relative_path}")

    expected_sha256 = {
        prefix + relative_path: object_sha256
        for relative_path, (_object_bytes, object_sha256) in expected.items()
    }
    expected_sha256[prefix + "lab_manifest.json"] = plan_sha256
    expected_sha256[prefix + "_COMPLETE.json"] = hashlib.sha256(marker_bytes).hexdigest()
    return expected_sha256

def require_sha256(value, *, field):
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise SystemExit(f"{field} must be a lowercase SHA-256")
    return value

def currency_judgment_field(currency):
    """Name the one judgment field a currency record must carry.

    Snapshots published from 2026-08-14 (producer 072eb361c) carry
    semantic_judgment_id; older ones carry equivalence_record_id. A record
    carrying both fails the exact field-set check. Drop the older spelling
    once no active donor snapshot uses it.
    """
    if isinstance(currency, dict) and "semantic_judgment_id" in currency:
        return "semantic_judgment_id"
    return "equivalence_record_id"

def parse_authorized_at(value, *, prefix):
    if not isinstance(value, str):
        raise SystemExit(f"results authorized_at must be a timestamp: {prefix}")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise SystemExit(f"results authorized_at is invalid: {prefix}") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise SystemExit(f"results authorized_at must be timezone-aware: {prefix}")
    return parsed

def resolve_results_activation(*, assay, group):
    """Validate one completion marker, root inventory, and exact stable remote set."""

    prefix = f"{assay}/results/"
    by_suffix = {remote.relative[len(prefix):]: remote for remote in group}
    marker = by_suffix.get("_COMPLETE.json")
    manifest = by_suffix.get("manifest.json")
    if marker is None or manifest is None:
        raise SystemExit(f"incomplete results plan prefix: {prefix}")

    marker_bytes = capture_control(marker, label=f"results activation marker {prefix}")
    manifest_bytes = capture_control(manifest, label=f"results root manifest {prefix}")
    marker_payload = strict_json(marker_bytes, label=f"results activation marker {prefix}")
    marker_schema = marker_payload.get("schema_version")
    common_marker_fields = {
        "schema_version",
        "sample_id",
        "donor_id",
        "assay_id",
        "plan_sha256",
        "destination",
        "object_set_sha256",
        "object_count",
        "object_bytes",
    }
    if marker_schema != "donor-results-completion/v3":
        raise SystemExit(f"results activation marker has the wrong contract: {prefix}")
    required_marker_fields = common_marker_fields | {"published_at"}
    # `omissions` discloses which registered stages were not shipped and why. It is
    # declared optional rather than required so a marker that gains a disclosure
    # field is not rejected outright by a client that predates it — exact set
    # equality made the published contract un-evolvable.
    optional_marker_fields = {"omissions"}
    marker_fields = set(marker_payload)
    if not required_marker_fields <= marker_fields or not (
        marker_fields - required_marker_fields <= optional_marker_fields
    ):
        raise SystemExit(f"results activation marker has an unexpected schema: {prefix}")
    plan_sha256 = require_sha256(
        marker_payload["plan_sha256"], field="results marker plan_sha256"
    )
    if (
        marker_payload["donor_id"] != donor
        or marker_payload["assay_id"] != assay
    ):
        raise SystemExit(f"results marker identity differs from its donor/sample path: {prefix}")
    sample_id = canonical_segment(marker_payload["sample_id"], field="results marker sample_id")
    require_sha256(
        marker_payload["object_set_sha256"],
        field="results marker object_set_sha256",
    )
    marker_count = require_nonnegative_integer(
        marker_payload["object_count"], field="results marker object_count"
    )
    marker_bytes_count = require_nonnegative_integer(
        marker_payload["object_bytes"], field="results marker object_bytes"
    )
    destination = marker_payload["destination"]
    expected_destination = {
        "sink": "b2",
        "bucket": bucket,
        "prefix": f"{donor}/{assay}/results",
        "representation": "flat",
    }
    if destination != expected_destination:
        raise SystemExit(f"results marker destination differs from its B2 path: {prefix}")
    authorized_at_text = marker_payload["published_at"]
    authorized_at = parse_authorized_at(authorized_at_text, prefix=prefix)

    root = strict_json(manifest_bytes, label=f"results root manifest {prefix}")
    common_root_fields = {
        "schema_version",
        "sample_id",
        "donor_id",
        "assay_id",
        "selected_stages",
        "objects",
        "object_count",
        "object_bytes",
    }
    required_root_fields = common_root_fields | {
        "source_epoch_id",
        "revision_equivalence_evidence_sha256",
        "stage_dispositions",
    }
    root_schema = root.get("schema_version")
    supported_root_schemas = {
        "donor-root-export-manifest/v2",
        "donor-root-export-manifest/v3",
        "donor-root-export-manifest/v4",
    }
    # v4 is v3 plus transport encoding: objects may travel gzip-compressed and are
    # installed decoded at their logical path. Its dispositions are v3's.
    transport_encoded = root_schema == "donor-root-export-manifest/v4"
    v3_dispositions = root_schema in {
        "donor-root-export-manifest/v3",
        "donor-root-export-manifest/v4",
    }
    if transport_encoded:
        required_root_fields = required_root_fields | {"transport_codec"}
    if set(root) != required_root_fields or root_schema not in supported_root_schemas:
        raise SystemExit(f"results root manifest has an unexpected schema: {prefix}")
    if transport_encoded:
        transport_codec = root["transport_codec"]
        if not isinstance(transport_codec, dict) or transport_codec.get("codec") != "gzip":
            raise SystemExit(f"results root manifest transport codec is not gzip: {prefix}")
    if (
        root["sample_id"] != sample_id
        or root["donor_id"] != donor
        or root["assay_id"] != assay
    ):
        raise SystemExit(f"results root manifest identity differs from its activation: {prefix}")
    selected_stages = root["selected_stages"]
    if (
        not isinstance(selected_stages, list)
        or selected_stages != sorted(set(selected_stages))
        or any(canonical_segment(stage, field="selected stage") != stage for stage in selected_stages)
    ):
        raise SystemExit(f"results root manifest stages are not canonical: {prefix}")
    if root_schema in supported_root_schemas:
        require_sha256(root["source_epoch_id"], field="root source_epoch_id")
        require_sha256(
            root["revision_equivalence_evidence_sha256"],
            field="root revision_equivalence_evidence_sha256",
        )
        stage_dispositions = root["stage_dispositions"]
        if not isinstance(stage_dispositions, list):
            raise SystemExit(f"results root stage dispositions are not a list: {prefix}")
        disposition_stages = []
        selected_from_dispositions = []
        allowed_states = {
            "selected",
            "inapplicable",
            "excluded-invalid-science",
            "invalid-or-missing",
            "excluded-noncurrent",
            "excluded-stale-provenance",
            "excluded-dependency",
            "excluded-implausible",
            # Producer 91fa13c45 (2026-08-06): sound method, restricted coverage.
            "excluded-restricted-scope",
        }
        required_disposition_fields_v2 = {
            "stage",
            "state",
            "reason",
            "attempt_id",
            "ran_at",
            "current_pointer_sha256",
            "receipt_sha256",
            "currency",
            "blocked_by",
        }
        # The judgment field (equivalence_record_id or semantic_judgment_id) is
        # checked per record; see currency_judgment_field.
        required_currency_fields_v2 = {
            "decision_id",
            "disposition",
            "completion_eligible",
            "produced_identity_digest",
            "current_identity_digest",
            "unresolved_reason_codes",
        }
        if v3_dispositions:
            required_disposition_fields = required_disposition_fields_v2 | {
                "evidence_kind",
                "action_key",
                "semantic_artifact_digest",
            }
            required_currency_fields = required_currency_fields_v2 | {
                "currentness_attestation_id",
                "identity_scheme",
                "action_key",
                "semantic_artifact_digest",
            }
        else:
            required_disposition_fields = required_disposition_fields_v2
            required_currency_fields = required_currency_fields_v2
        eligible_currency_dispositions = {
            "CURRENT",
            "EQUIVALENT",
            "ATTESTED_CURRENT",
            "LEGACY_REVIEWED",
        }
        allowed_currency_dispositions = eligible_currency_dispositions | {
            "RECOMPUTE_REQUIRED",
            "RECOMPUTE_UNRESOLVED",
        }
        receipt_bound_states = {
            "selected",
            "excluded-noncurrent",
            "excluded-dependency",
            "excluded-implausible",
        }
        for disposition in stage_dispositions:
            if (
                not isinstance(disposition, dict)
                or set(disposition) != required_disposition_fields
                or disposition["state"] not in allowed_states
                or (
                    v3_dispositions
                    and (
                        not isinstance(disposition["evidence_kind"], str)
                        or disposition["evidence_kind"] not in {"cass_current", "action_key"}
                        or not isinstance(disposition["action_key"], str)
                        or not isinstance(disposition["semantic_artifact_digest"], str)
                    )
                )
            ):
                raise SystemExit(f"results root stage disposition is malformed: {prefix}")
            stage = canonical_segment(disposition["stage"], field="disposition stage")
            disposition_stages.append(stage)
            state = disposition["state"]
            currency = disposition["currency"]
            if state in receipt_bound_states:
                judgment_field = currency_judgment_field(currency)
                if (
                    not isinstance(currency, dict)
                    or set(currency) != required_currency_fields | {judgment_field}
                    or currency["disposition"] not in allowed_currency_dispositions
                    or type(currency["completion_eligible"]) is not bool
                    or currency["completion_eligible"]
                    is not (currency["disposition"] in eligible_currency_dispositions)
                    or not isinstance(currency["unresolved_reason_codes"], list)
                    or any(
                        not isinstance(reason, str)
                        for reason in currency["unresolved_reason_codes"]
                    )
                ):
                    raise SystemExit(
                        f"result has malformed exact currency: {prefix}{stage}"
                    )
                require_sha256(currency["decision_id"], field=f"{stage} currency decision_id")
                judgment_id = currency[judgment_field]
                if judgment_id:
                    if judgment_field == "semantic_judgment_id" and isinstance(judgment_id, str):
                        judgment_id = judgment_id.removeprefix("semantic-judgment:")
                    require_sha256(judgment_id, field=f"{stage} currency {judgment_field}")
                for digest_field in (
                    "produced_identity_digest",
                    "current_identity_digest",
                    *(
                        ("currentness_attestation_id",)
                        if v3_dispositions
                        else ()
                    ),
                ):
                    if currency[digest_field]:
                        require_sha256(
                            currency[digest_field],
                            field=f"{stage} currency {digest_field}",
                        )
                if v3_dispositions:
                    currentness_id = currency["currentness_attestation_id"]
                    if currency["disposition"] == "ATTESTED_CURRENT":
                        classifier_unresolved = bool(
                            {
                                "CLASSIFIER_FAILURE",
                                "CURRENT_IDENTITY_INCONCLUSIVE",
                            }
                            & set(currency["unresolved_reason_codes"])
                        )
                        if (
                            not currentness_id
                            or currency[judgment_field]
                            or (
                                not currency["current_identity_digest"]
                                and not classifier_unresolved
                            )
                            or (
                                not currency["produced_identity_digest"]
                                and not currency["unresolved_reason_codes"]
                            )
                        ):
                            raise SystemExit(
                                f"result has malformed scoped currentness evidence: {prefix}{stage}"
                            )
                    elif currentness_id:
                        raise SystemExit(
                            f"non-attested result carries currentness evidence: {prefix}{stage}"
                        )
                canonical_segment(
                    disposition["attempt_id"],
                    field=f"{stage} disposition attempt_id",
                )
                require_sha256(
                    disposition["receipt_sha256"],
                    field=f"{stage} current receipt",
                )
                if v3_dispositions:
                    if (
                        not isinstance(disposition["current_pointer_sha256"], str)
                        or not isinstance(currency["identity_scheme"], str)
                        or not isinstance(currency["action_key"], str)
                        or not isinstance(currency["semantic_artifact_digest"], str)
                    ):
                        raise SystemExit(
                            f"result has malformed receipt identity: {prefix}{stage}"
                        )
                    for action_field in ("action_key", "semantic_artifact_digest"):
                        if disposition[action_field]:
                            require_sha256(
                                disposition[action_field],
                                field=f"{stage} disposition {action_field}",
                            )
                        if currency[action_field]:
                            require_sha256(
                                currency[action_field],
                                field=f"{stage} currency {action_field}",
                            )
                    evidence_kind = disposition["evidence_kind"]
                    identity_scheme = currency["identity_scheme"]
                    if evidence_kind == "cass_current":
                        require_sha256(
                            disposition["current_pointer_sha256"],
                            field=f"{stage} current pointer",
                        )
                        if (
                            identity_scheme != "execution_identity.v1"
                            or disposition["action_key"] != ""
                            or disposition["semantic_artifact_digest"] != ""
                            or currency["action_key"] != ""
                            or currency["semantic_artifact_digest"] != ""
                        ):
                            raise SystemExit(
                                f"result has incoherent CASS identity: {prefix}{stage}"
                            )
                    elif (
                        disposition["current_pointer_sha256"] != ""
                        or identity_scheme != "action_key.v1"
                        or not disposition["action_key"]
                        or not disposition["semantic_artifact_digest"]
                        or currency["action_key"] != disposition["action_key"]
                        or currency["semantic_artifact_digest"]
                        != disposition["semantic_artifact_digest"]
                    ):
                        raise SystemExit(
                            f"result has incoherent ActionKey identity: {prefix}{stage}"
                        )
                else:
                    require_sha256(
                        disposition["current_pointer_sha256"],
                        field=f"{stage} current pointer",
                    )
            if state == "selected":
                # Selected means "in this shipped snapshot" (last SUCCESS receipt +
                # bytes). Stage-currency completion_eligible is a pipeline rerun
                # screen, not a donor download veto — RECOMPUTE_* last-SUCCESS
                # packages are intentionally downloadable (operator 2026-08-05).
                selected_from_dispositions.append(stage)
            if state == "excluded-noncurrent" and currency["completion_eligible"] is not False:
                raise SystemExit(
                    f"noncurrent exclusion has eligible currency: {prefix}{stage}"
                )
            blocked_by = disposition["blocked_by"]
            if state == "excluded-dependency":
                canonical_segment(blocked_by, field=f"{stage} blocked_by")
            elif blocked_by:
                raise SystemExit(
                    f"non-dependency disposition names blocked_by: {prefix}{stage}"
                )
        if disposition_stages != sorted(set(disposition_stages)):
            raise SystemExit(f"results root stage dispositions are not canonical: {prefix}")
        if selected_from_dispositions != selected_stages:
            raise SystemExit(f"results root selection disagrees with dispositions: {prefix}")
    root_count = require_nonnegative_integer(root["object_count"], field="root object_count")
    root_bytes_count = require_nonnegative_integer(root["object_bytes"], field="root object_bytes")
    objects = root["objects"]
    if not isinstance(objects, list) or not objects:
        raise SystemExit(f"results root manifest requires a non-empty object list: {prefix}")

    plain_object_fields = {"path", "bytes", "sha256"}
    encoded_object_fields = plain_object_fields | {
        "encoding",
        "logical_path",
        "logical_bytes",
        "logical_sha256",
    }
    reserved_paths = {"_COMPLETE.json", "manifest.json"}
    expected = {}
    encoded = {}
    root_object_bytes = 0
    object_set = []
    for item in objects:
        if not isinstance(item, dict) or not (
            set(item) == plain_object_fields
            or (transport_encoded and set(item) == encoded_object_fields)
        ):
            raise SystemExit(f"results root manifest object has an unexpected schema: {prefix}")
        relative_path = canonical_relative(item["path"])
        if relative_path in reserved_paths or relative_path in expected:
            raise SystemExit(f"results root manifest paths are duplicate or reserved: {prefix}")
        object_bytes = require_nonnegative_integer(
            item["bytes"], field=f"results object bytes {relative_path}"
        )
        object_sha256 = require_sha256(
            item["sha256"], field=f"results object SHA-256 {relative_path}"
        )
        if "encoding" in item:
            # bytes/sha256 above describe the STORED gzip object; the logical
            # triple describes the plain file the donor's tree must end up with.
            if item["encoding"] != "gzip":
                raise SystemExit(
                    f"results object has an unsupported transport encoding: {prefix}{relative_path}"
                )
            logical_path = canonical_relative(item["logical_path"])
            if logical_path in reserved_paths:
                raise SystemExit(f"results object encodes a reserved name: {prefix}{logical_path}")
            if relative_path != logical_path + ".gz":
                raise SystemExit(
                    f"results transport path is not its logical path plus .gz: {prefix}{relative_path}"
                )
            encoded[relative_path] = (
                logical_path,
                require_nonnegative_integer(
                    item["logical_bytes"], field=f"results object logical bytes {relative_path}"
                ),
                require_sha256(
                    item["logical_sha256"], field=f"results object logical SHA-256 {relative_path}"
                ),
            )
        expected[relative_path] = (object_bytes, object_sha256)
        root_object_bytes += object_bytes
        object_set.append({"path": relative_path, "bytes": object_bytes, "sha256": object_sha256})
    if list(expected) != sorted(expected):
        raise SystemExit(f"results root manifest paths are not canonical sorted order: {prefix}")
    if root_count != len(expected) or root_bytes_count != root_object_bytes:
        raise SystemExit(f"results root manifest totals differ from its objects: {prefix}")
    # A decoded object is installed at its logical path, so that path must name
    # nothing else. Logical paths are unique among themselves (each is a unique
    # stored path minus ".gz") and are never reserved (checked above); none may
    # equal any stored object's path.
    logical_collisions = sorted(
        {logical_path for logical_path, _bytes, _sha256 in encoded.values()} & set(expected)
    )
    if logical_collisions:
        raise SystemExit(
            f"results logical path collides with another object: {prefix}{logical_collisions[0]}"
        )

    manifest_sha256 = hashlib.sha256(manifest_bytes).hexdigest()
    expected["manifest.json"] = (len(manifest_bytes), manifest_sha256)
    object_set.append(
        {"path": "manifest.json", "bytes": len(manifest_bytes), "sha256": manifest_sha256}
    )
    object_set.sort(key=lambda item: item["path"])
    object_set_sha256 = hashlib.sha256(
        json.dumps(
            object_set,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    ).hexdigest()
    if marker_payload["object_set_sha256"] != object_set_sha256:
        raise SystemExit(f"results marker object set does not bind the root manifest: {prefix}")
    if marker_count != len(expected) or marker_bytes_count != sum(item[0] for item in expected.values()):
        raise SystemExit(f"results marker totals differ from the exact plan objects: {prefix}")

    expected_suffixes = set(expected) | {"_COMPLETE.json"}
    if set(by_suffix) != expected_suffixes:
        missing = sorted(expected_suffixes - set(by_suffix))[:5]
        extra = sorted(set(by_suffix) - expected_suffixes)[:5]
        raise SystemExit(
            f"results plan listing differs from its manifest: missing={missing} extra={extra}"
        )
    for relative_path, (object_bytes, _sha256) in expected.items():
        if by_suffix[relative_path].size != object_bytes:
            raise SystemExit(f"results object size differs from manifest: {prefix}{relative_path}")

    expected_sha256 = {
        prefix + relative_path: object_sha256
        for relative_path, (_object_bytes, object_sha256) in expected.items()
    }
    expected_sha256[prefix + "_COMPLETE.json"] = hashlib.sha256(marker_bytes).hexdigest()
    return ResultsActivation(
        assay=assay,
        sample_id=sample_id,
        plan_sha256=plan_sha256,
        authorized_at=authorized_at,
        authorized_at_text=authorized_at_text,
        marker_sha256=hashlib.sha256(marker_bytes).hexdigest(),
        expected_sha256=expected_sha256,
        encoded={
            prefix + relative_path: (prefix + logical_path, logical_bytes, logical_sha256)
            for relative_path, (logical_path, logical_bytes, logical_sha256) in encoded.items()
        },
        group=tuple(group),
    )

seen = set()
prefix = donor + "/"
records = []
for item in payload:
    if not isinstance(item, dict):
        raise SystemExit("B2 listing contains a non-object")
    key = item.get("fileName")
    if not isinstance(key, str) or not key.startswith(prefix):
        raise SystemExit(f"B2 key escaped exact donor prefix {prefix!r}: {key!r}")
    relative = canonical_relative(key[len(prefix):])
    if relative in seen:
        raise SystemExit(f"duplicate B2 key: {key!r}")
    seen.add(relative)
    size = item.get("size")
    if isinstance(size, bool) or not isinstance(size, int) or size < 0:
        raise SystemExit(f"invalid B2 object size: {key!r}")
    remote_sha1 = item.get("contentSha1")
    if remote_sha1 in {None, "", "none"}:
        file_info = item.get("fileInfo") or {}
        if not isinstance(file_info, dict):
            raise SystemExit(f"invalid B2 fileInfo: {key!r}")
        remote_sha1 = file_info.get("large_file_sha1") or "unverified"
    if remote_sha1 != "unverified" and (
        not isinstance(remote_sha1, str) or SHA1_RE.fullmatch(remote_sha1) is None
    ):
        raise SystemExit(f"invalid B2 contentSha1: {key!r}")
    records.append(RemoteObject(key, relative, size, remote_sha1, section_of(relative)))

requested_sections = {only} if only else {"lab", "results", "ensemble"}
if exclude:
    requested_sections.discard(exclude)
selected = [
    remote
    for remote in records
    if remote.section in requested_sections
]
lab_groups = {}
for remote in selected:
    if remote.section != "lab":
        continue
    match = LAB_RE.fullmatch(remote.relative)
    if match is None:
        continue
    assay = canonical_segment(match.group(1), field="assay path segment")
    lab_groups.setdefault(assay, []).append(remote)
if "lab" in requested_sections and not lab_groups:
    if only == "lab":
        raise SystemExit("no complete stable lab view is available")
    requested_sections.discard("lab")

result_groups = {}
for remote in selected:
    if remote.section != "results":
        continue
    match = RESULTS_RE.fullmatch(remote.relative)
    if match is None:
        continue
    assay = canonical_segment(match.group(1), field="assay path segment")
    result_groups.setdefault(assay, []).append(remote)
if "results" in requested_sections and not result_groups:
    raise SystemExit("no complete stable donor-results view is available")

expected_lab_sha256 = {}
for assay, group in sorted(lab_groups.items()):
    lab_projection = resolve_lab_activation(
        assay=assay,
        group=group,
    )
    overlap = set(expected_lab_sha256) & set(lab_projection)
    if overlap:
        raise SystemExit(f"duplicate activated lab path: {sorted(overlap)[0]}")
    expected_lab_sha256.update(lab_projection)

activations = [
    resolve_results_activation(
        assay=assay,
        group=group,
    )
    for assay, group in sorted(result_groups.items())
]
existing_active = {}
existing_manifest_path = destination_root / ".genome-manifest.json"
if existing_manifest_path.exists():
    existing_manifest = strict_json(
        read_regular(existing_manifest_path, label="existing local genome manifest"),
        label="existing local genome manifest",
    )
    if existing_manifest.get("donor") not in {None, donor}:
        raise SystemExit("existing local genome manifest belongs to another donor")
    raw_existing_active = existing_manifest.get("active_results", {})
    if not isinstance(raw_existing_active, dict):
        raise SystemExit("existing local active_results must be an object")
    existing_active = raw_existing_active

active_by_assay = {}
if "results" in requested_sections:
    current_by_assay = {activation.assay: activation for activation in activations}
    if len(current_by_assay) != len(activations):
        raise SystemExit("multiple stable result views collided for one sample")
    missing_assays = sorted(set(existing_active) - set(current_by_assay))
    if missing_assays:
        raise SystemExit(
            f"remote results listing would roll back active assays: {missing_assays}"
        )
    for assay, active in sorted(current_by_assay.items()):
        prior = existing_active.get(assay)
        if prior is not None:
            if not isinstance(prior, dict):
                raise SystemExit(f"existing active result record is malformed for assay {assay}")
            prior_time = parse_authorized_at(
                prior.get("authorized_at"), prefix=f"local active assay {assay}"
            )
            prior_plan = require_sha256(
                prior.get("plan_sha256"), field=f"local active plan_sha256 for {assay}"
            )
            prior_completion = require_sha256(
                prior.get("completion_sha256"),
                field=f"local active completion_sha256 for {assay}",
            )
            if (
                active.plan_sha256 == prior_plan
                and active.marker_sha256 != prior_completion
            ):
                raise SystemExit(
                    f"immutable results completion marker changed for assay {assay}"
                )
            if active.authorized_at < prior_time or (
                active.authorized_at == prior_time and active.plan_sha256 != prior_plan
            ):
                raise SystemExit(f"remote results activation would roll back assay {assay}")
        active_by_assay[assay] = active

active_payload = {
    assay: {
        "sample_id": activation.sample_id,
        "plan_sha256": activation.plan_sha256,
        "authorized_at": activation.authorized_at_text,
        "completion_sha256": activation.marker_sha256,
        "local_path": f"{assay}/results",
    }
    for assay, activation in sorted(active_by_assay.items())
}
active_results_path.write_text(
    json.dumps(active_payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)

# Each row: (remote object, stored SHA-256, local path, transport). transport is
# None for plain objects, else (logical local path, logical bytes, logical SHA-256)
# and the local path is the logical one: encoded names never reach the tree.
projected_rows = []
for remote in selected:
    if remote.section == "lab" and remote.relative in expected_lab_sha256:
        projected_rows.append((remote, expected_lab_sha256[remote.relative], remote.relative, None))
    elif remote.section == "ensemble":
        projected_rows.append((remote, "unbound", remote.relative, None))
for activation in active_by_assay.values():
    for remote in activation.group:
        transport = activation.encoded.get(remote.relative)
        projected_rows.append(
            (
                remote,
                activation.expected_sha256[remote.relative],
                remote.relative if transport is None else transport[0],
                transport,
            )
        )

if active_by_assay:
    root_source = max(
        active_by_assay.values(),
        key=lambda item: (item.authorized_at, item.assay, item.plan_sha256),
    )
    remote_by_suffix = {
        remote.relative.split(f"{root_source.assay}/results/", 1)[1]: remote
        for remote in root_source.group
    }
    for asset_path in ROOT_AGENT_ASSETS:
        remote = remote_by_suffix.get(asset_path)
        if remote is None:
            raise SystemExit(
                f"active results view lacks required root agent asset {asset_path}: "
                f"{root_source.assay}/results"
            )
        # Root assets are looked up by their plain name; an encoded object's
        # stored path always ends in .gz, so these are never transport-encoded.
        projected_rows.append(
            (remote, root_source.expected_sha256[remote.relative], asset_path, None)
        )

local_paths = [local_relative for _remote, _sha256, local_relative, _transport in projected_rows]
if len(local_paths) != len(set(local_paths)):
    raise SystemExit("activated objects collide after local bundle projection")
# Row columns (every plan TSV reader depends on this order): remote SHA-1,
# stored bytes, stored SHA-256, B2 key, local path, encoding, local bytes, local
# SHA-256. A plain row's encoding is "identity" and its local identity is its
# stored identity; a gzip row's local identity is the decoded logical file.
for remote, expected_sha256, local_relative, transport in sorted(
    projected_rows, key=lambda item: item[2]
):
    if transport is None:
        encoding, logical_size, logical_sha256 = "identity", remote.size, expected_sha256
    else:
        encoding = "gzip"
        _logical_path, logical_size, logical_sha256 = transport
    print(
        f"{remote.remote_sha1}\t{remote.size}\t{expected_sha256}\t"
        f"{remote.key}\t{local_relative}\t{encoding}\t{logical_size}\t{logical_sha256}"
    )
PYEOF

verified_file_count=$(wc -l < "$VERIFIED" | tr -d ' ')
verified_bytes=$(awk -F '\t' '{total += $2} END {printf "%.0f", total}' "$VERIFIED")
say "  ${G}Verified remote snapshot:${X} ${verified_file_count} files, $(human "$verified_bytes")"
if [ "$(tr -d '[:space:]' < "$ACTIVE_RESULTS")" != "{}" ]; then
  "${PY[@]}" - "$ACTIVE_RESULTS" <<'PYEOF'
import json
import sys

active = json.load(open(sys.argv[1], encoding="utf-8"))
for assay, record in sorted(active.items()):
    print(
        f"    results · {assay} · plan {record['plan_sha256'][:12]} "
        f"· activated {record['authorized_at']}"
    )
PYEOF
fi
awk -F '\t' '$5 ~ /\/lab\/lab_manifest\.json$/ {printf "    lab · %s · plan %s\n", $5, substr($3, 1, 12)}' "$VERIFIED"
log_event "verified remote_files=${verified_file_count} remote_bytes=${verified_bytes}"

# The selected sections are downloaded whole: every verified remote row is a
# download candidate, and the omitted partition stays empty.
cp "$VERIFIED" "$FILTERED" || { say "${R}could not plan the verified snapshot${X}"; exit 1; }

selected_file_count=$(wc -l < "$FILTERED" | tr -d ' ')
selected_bytes=$(awk -F '\t' '{total += $2} END {printf "%.0f", total}' "$FILTERED")
say "  ${G}Materialization:${X} all ${selected_file_count} verified files selected"
log_event "selection selected_files=${selected_file_count} selected_bytes=${selected_bytes}"

if [ "$COMMAND" != "setup" ]; then
  unset KEY_ID APP_KEY B2_APPLICATION_KEY_ID B2_APPLICATION_KEY
fi

if [ -n "$(find "$DEST_ABS" -type f ! -path "$DEST_ABS/.genome-download-tmp.*/*" -print -quit 2>/dev/null)" ]; then
  say "  ${D}indexing existing verified content for differential sync${X}"
  "${PY[@]}" - "$DEST_ABS" "$MANIFEST" "$existing_donor" <<'PYEOF' > "$LOCAL_INDEX" \
    || { say "${R}could not build the local content index${X}"; exit 1; }
import hashlib
import json
import os
import stat
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1])
manifest_name = sys.argv[2]
manifest_donor = sys.argv[3]

# Quoted: the engine runs on the donor's first python3, which can be macOS's 3.9,
# where an unquoted `str | None` annotation raises TypeError at definition time.
def canonical_relative(path: Path) -> "str | None":
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError:
        return None
    pure = PurePosixPath(relative)
    if (
        not relative
        or "\\" in relative
        or "\x00" in relative
        or "\t" in relative
        or "\n" in relative
        or pure.is_absolute()
        or pure.as_posix() != relative
        or any(part in {"", ".", ".."} for part in pure.parts)
    ):
        return None
    if relative == manifest_name or pure.parts[0].startswith(".genome-download-tmp."):
        return None
    return relative

def emit(size: int, sha1: str, sha256: str, relative: str) -> None:
    if size < 0 or len(sha256) != 64 or any(char not in "0123456789abcdef" for char in sha256):
        return
    if sha1 != "unverified" and (
        len(sha1) != 40 or any(char not in "0123456789abcdef" for char in sha1)
    ):
        return
    print(size, sha1, sha256, relative, sep="\t")

manifest_path = root / manifest_name
if manifest_donor and manifest_path.is_file() and not manifest_path.is_symlink():
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    files = manifest.get("files")
    retained = manifest.get("retained_files", {})
    if (
        manifest.get("donor") != manifest_donor
        or not isinstance(files, dict)
        or not isinstance(retained, dict)
    ):
        raise SystemExit("existing local genome manifest is malformed")
    # Retained files are still managed bytes: they stay reusable, and an explicit
    # --prune on a later run must still be able to see and remove them.
    managed = {**files, **retained}
    for relative, record in sorted(managed.items()):
        if not isinstance(relative, str) or not isinstance(record, dict):
            continue
        path = root / relative
        canonical = canonical_relative(path)
        try:
            observed = path.lstat()
        except FileNotFoundError:
            continue
        if canonical != relative or not stat.S_ISREG(observed.st_mode):
            continue
        size = record.get("size")
        sha256 = record.get("sha256")
        sha1 = record.get("remote_sha1") or "unverified"
        if isinstance(size, int) and isinstance(sha1, str) and isinstance(sha256, str):
            emit(size, sha1, sha256, relative)
else:
    indexed = 0
    for path in sorted(root.rglob("*")):
        canonical = canonical_relative(path)
        if canonical is None:
            continue
        try:
            before = path.lstat()
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(before.st_mode):
            continue
        sha1 = hashlib.sha1(usedforsecurity=False)
        sha256 = hashlib.sha256()
        with path.open("rb") as source:
            while chunk := source.read(8 * 1024 * 1024):
                sha1.update(chunk)
                sha256.update(chunk)
        after = path.lstat()
        identity = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
        if identity(before) != identity(after):
            raise SystemExit(f"local reuse candidate changed while hashing: {canonical}")
        emit(after.st_size, sha1.hexdigest(), sha256.hexdigest(), canonical)
        indexed += 1
    print(f"indexed {indexed} existing files for local reuse", file=sys.stderr)
PYEOF
fi

new=0; changed=0; unchanged=0; reused=0; total_xfer=0; local_reuse_bytes=0
# Disk need: bytes that end up installed, plus the stored gzip temps that can sit
# beside their decoded output (at most JOBS of them in flight at once).
install_bytes=0; encoded_downloads=0; max_encoded_stored=0
scan_index=0; scan_count=$(wc -l < "$FILTERED" | tr -d ' ')
# TODO columns: state, remote SHA-1, stored bytes, stored SHA-256, B2 key, local
# path, encoding, local bytes, local SHA-256, reuse source. The reuse source stays
# LAST: it may be empty, and `read` collapses consecutive tabs mid-line.
while IFS=$'\t' read -r remote_sha1 size expected_sha256 key relative encoding logical_size logical_sha256; do
  [ -n "$relative" ] || continue
  case "$encoding" in identity|gzip) ;; *) say "${R}malformed verified plan row: ${relative}${X}"; exit 1 ;; esac
  scan_index=$((scan_index + 1))
  local_path="${DEST_ABS}/${relative}"
  # A gzip row is installed decoded, so the local file is judged by its logical
  # identity, never by the stored transport object's bytes.
  if [ "$encoding" = "gzip" ]; then
    local_size="$logical_size"; local_sha256="$logical_sha256"
  else
    local_size="$size"; local_sha256="$expected_sha256"
  fi
  if [ ! -e "$local_path" ]; then
    new=$((new + 1))
    reuse_source=""
    if [ "$local_sha256" != "unbound" ]; then
      reuse_source="$(awk -F '\t' -v wanted_size="$local_size" -v wanted_sha256="$local_sha256" '$1 == wanted_size && $3 == wanted_sha256 {print $4; exit}' "$LOCAL_INDEX")"
    fi
    if [ -n "$reuse_source" ]; then
      reused=$((reused + 1)); local_reuse_bytes=$((local_reuse_bytes + local_size))
      printf 'reused-local\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$remote_sha1" "$size" "$expected_sha256" "$key" "$relative" "$encoding" "$logical_size" "$logical_sha256" "$reuse_source" >> "$TODO"
    else
      total_xfer=$((total_xfer + size)); install_bytes=$((install_bytes + local_size))
      if [ "$encoding" = "gzip" ]; then
        encoded_downloads=$((encoded_downloads + 1))
        [ "$size" -gt "$max_encoded_stored" ] && max_encoded_stored="$size"
      fi
      printf 'new\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\n' "$remote_sha1" "$size" "$expected_sha256" "$key" "$relative" "$encoding" "$logical_size" "$logical_sha256" >> "$TODO"
    fi
  elif [ ! -f "$local_path" ] || [ -L "$local_path" ]; then
    say "${R}unsafe local target: ${relative}${X}"; exit 1
  else
    observed="$(fs_guard hash "$relative")" || exit 1
    IFS=$'\t' read -r observed_size observed_sha1 observed_sha256 <<EOF
$observed
EOF
    local_matches=0
    if [ "$local_sha256" != "unbound" ]; then
      [ "$observed_size" = "$local_size" ] && [ "$observed_sha256" = "$local_sha256" ] && local_matches=1
    elif [ "$remote_sha1" != "unverified" ]; then
      [ "$observed_size" = "$size" ] && [ "$observed_sha1" = "$remote_sha1" ] && local_matches=1
    fi
    if [ "$local_matches" -eq 1 ]; then
      unchanged=$((unchanged + 1))
      if [ "$encoding" = "gzip" ]; then
        # The local file is the decoded form: no B2 object ever held these exact
        # bytes, so there is no remote SHA-1 to record for them.
        printf '%s\t%s\t%s\t%s\t%s\n' "$relative" "$local_size" "unverified" "$observed_sha256" "activated_plan_logical_sha256_verified" >> "$HASHES"
      else
        if [ "$expected_sha256" = "unbound" ]; then proof="remote_sha1_verified"; else proof="activated_plan_sha256_verified"; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$relative" "$size" "$remote_sha1" "$observed_sha256" "$proof" >> "$HASHES"
      fi
    else
      changed=$((changed + 1)); total_xfer=$((total_xfer + size)); install_bytes=$((install_bytes + local_size))
      if [ "$encoding" = "gzip" ]; then
        encoded_downloads=$((encoded_downloads + 1))
        [ "$size" -gt "$max_encoded_stored" ] && max_encoded_stored="$size"
      fi
      if [ "$remote_sha1" = "unverified" ]; then state="updated-unverified"; else state="updated"; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\n' "$state" "$remote_sha1" "$size" "$expected_sha256" "$key" "$relative" "$encoding" "$logical_size" "$logical_sha256" >> "$TODO"
    fi
  fi
  render_progress 0 0 "$scan_index" "$scan_count" "checking · $(progress_subject "$relative")"
done < "$FILTERED"
progress_newline

cut -f5 "$VERIFIED" > "$RELS"
_section_of() {
  case "$1" in
    ensemble/*) printf ensemble ;;
    */lab/*|*/lab) printf lab ;;
    *) printf results ;;
  esac
}
if [ -n "$existing_donor" ]; then
  while IFS=$'\t' read -r _size _sha1 _sha256 relative; do
    [ -n "$relative" ] || continue
    section="$(_section_of "$relative")"
    [ -n "$ONLY" ] && [ "$section" != "$ONLY" ] && continue
    [ -n "$EXCLUDE" ] && [ "$section" = "$EXCLUDE" ] && continue
    grep -qxF "$relative" "$RELS" || printf '%s\n' "$relative" >> "$PRUNES"
  done < "$LOCAL_INDEX"
fi
prune_n=$(wc -l < "$PRUNES" | tr -d ' ')
# Entries not yet under the retention attic get MOVED there on a keep run; entries
# already under `_retained/` only need reporting (or deletion under --prune).
move_n=$(grep -cv '^_retained/' "$PRUNES" || true)
attic_n=$((prune_n - move_n))
absent_summary=""
if [ "$prune_n" -gt 0 ]; then
  if [ "$PRUNE" -eq 1 ]; then
    absent_summary=" · ${R}${prune_n} to remove${X}"
  else
    [ "$move_n" -gt 0 ] && absent_summary=" · ${Y}${move_n} to retire to _retained/${X}"
    [ "$attic_n" -gt 0 ] && absent_summary="${absent_summary} · ${D}${attic_n} in _retained/${X}"
  fi
fi

say "  ${B}Changes:${X} ${G}${new} new${X} · ${BL}${changed} updated${X} · ${D}${unchanged} unchanged${X}$( [ "$reused" -gt 0 ] && printf " · ${G}%s reused locally%s" "$reused" "$X" )${absent_summary}"
say "  ${B}Transfer:${X} $(human "$total_xfer") ${B}→${X} ${DEST_ABS}"
log_event "preview new=${new} updated=${changed} unchanged=${unchanged} reused=${reused} absent_remotely=${prune_n} prune=${PRUNE} transfer_bytes=${total_xfer} gzip_transport_files=${encoded_downloads}"
if [ "$DRYRUN" -eq 1 ]; then
  [ "$reused" -gt 0 ] && {
    say "\n  ${D}would reuse ${reused} local file(s):${X}"
    awk -F '\t' -v limit=25 '
      $1 == "reused-local" { count++; if (count <= limit) print "    " $6 " <- " $10 }
      END { if (count > limit) printf "    … %d more files\n", count - limit }
    ' "$TODO"
  }
  download_count=$((new + changed - reused))
  [ "$download_count" -gt 0 ] && {
    say "\n  ${D}would download ${download_count} file(s):${X}"
    awk -F '\t' -v limit=25 '
      $1 != "reused-local" { count++; if (count <= limit) print "    " $1 "\t" $6 }
      END { if (count > limit) printf "    … %d more files\n", count - limit }
    ' "$TODO"
  }
  [ "$prune_n" -gt 0 ] && {
    if [ "$PRUNE" -eq 1 ]; then
      say "\n  ${D}would remove ${prune_n} previously managed file(s):${X}"
    else
      say "\n  ${D}would retire ${move_n} file(s) no longer in the active snapshot to _retained/ (${attic_n} already there):${X}"
    fi
    awk -v limit=25 '
      { if (NR <= limit) print "    " $0 }
      END { if (NR > limit) printf "    … %d more files\n", NR - limit }
    ' "$PRUNES"
    [ "$PRUNE" -eq 1 ] || say "    ${D}(pass --prune to delete them instead)${X}"
  }
  if [ "$(tr -d '[:space:]' < "$ACTIVE_RESULTS")" != "{}" ]; then
    say "\n  ${D}would refresh the donor-root and assay Markdown guides${X}"
  fi
  say "\n  ${D}(dry run — no donor files changed)${X}\n"
  log_event "finish status=dry-run"
  exit 0
fi

confirmation_required=0
if [ -s "$TODO" ] || [ "$move_n" -gt 0 ] || { [ "$PRUNE" -eq 1 ] && [ "$prune_n" -gt 0 ]; }; then
  confirmation_required=1
elif { [ "$COMMAND" = "setup" ] || [ "$COMMAND" = "sync" ]; } \
  && [ "$ASSUME_YES" -eq 0 ] && [ "$FILTER_EXPLICIT" -eq 0 ] \
  && [ -t 0 ] && [ -t 1 ]; then
  confirmation_required=1
fi
if [ "$confirmation_required" -eq 1 ] && ! confirm "  Apply this verified update?"; then
  say "\n  No files changed."
  log_event "finish status=cancelled"
  exit 0
fi

# Installed bytes are what the tree keeps (decoded size for gzip rows); each
# in-flight gzip transport temp coexists with its decoded output until install.
transport_peak_bytes=$((max_encoded_stored * JOBS))
NEED_KB=$(awk "BEGIN{printf \"%d\", (${install_bytes}+${local_reuse_bytes}+${transport_peak_bytes})/1024*1.1}")
FREE_KB=$(df -Pk "$DEST_ABS" | awk 'NR==2{print $4}')
if [ "${FREE_KB:-0}" -lt "${NEED_KB:-0}" ]; then
  say "\n${R}  Not enough free disk space.${X}"
  exit 1
fi

# One download worker: capture a single object into its own private temp under
# $TEMP_ROOT and publish an atomic status file in $PREFETCH_DIR. Runs inside a
# worker subshell. A worker NEVER calls fs_guard install, never writes $HASHES,
# and never touches the destination tree — it writes only inside $TEMP_ROOT (the
# object bytes) and $PREFETCH_DIR under CONTROL_DIR (status/log bookkeeping).
prefetch_fetch_one() {
  local prefetch_index="$1" prefetch_key="$2"
  local prefetch_temp prefetch_log prefetch_status_partial prefetch_status_final
  prefetch_status_final="${PREFETCH_DIR}/${prefetch_index}.status"
  prefetch_status_partial="${PREFETCH_DIR}/${prefetch_index}.status.partial"
  prefetch_log="${PREFETCH_DIR}/${prefetch_index}.log"
  # Object bytes must land under TEMP_ROOT (same filesystem as the destination)
  # so the serial consumer's fs_guard hash/install path is unchanged; only the
  # FIFO, status, log, and pid bookkeeping live in CONTROL_DIR (off the dest
  # tree, so validate-tree never sees the non-regular FIFO).
  if ! prefetch_temp="$(mktemp "${TEMP_ROOT}/object.XXXXXX")"; then
    printf 'FAIL\t\n' > "$prefetch_status_partial"
    mv -f "$prefetch_status_partial" "$prefetch_status_final"
    return
  fi
  chmod 600 "$prefetch_temp"
  # The download runs as a background child so this worker can kill it on TERM.
  # Killing the worker subshell alone is not enough: b2 is reparented and keeps
  # running, which leaks a download process past genome-sync's own termination.
  local prefetch_download_pid=""
  trap 'if [ -n "$prefetch_download_pid" ]; then kill -TERM "$prefetch_download_pid" 2>/dev/null; fi; exit 143' HUP INT TERM
  "${B2_RUN[@]}" file download --no-progress \
    --max-download-streams-per-file "$MAX_STREAMS_PER_FILE" \
    "b2://${BUCKET}/${prefetch_key}" "$prefetch_temp" > "$prefetch_log" 2>&1 &
  prefetch_download_pid=$!
  # Recorded too, so the parent's teardown can reach the child directly even if
  # this worker never gets to run its trap.
  printf '%s\n' "$prefetch_download_pid" >> "$PREFETCH_PIDS"
  if wait "$prefetch_download_pid"; then
    printf 'OK\t%s\n' "$prefetch_temp" > "$prefetch_status_partial"
  else
    printf 'FAIL\t%s\n' "$prefetch_temp" > "$prefetch_status_partial"
  fi
  trap - HUP INT TERM
  # The rename is the ready signal: the consumer only ever sees a complete status.
  mv -f "$prefetch_status_partial" "$prefetch_status_final"
}

# Launch the bounded-concurrency producer. It walks $TODO in the same order the
# consumer does and, for every download item (state != reused-local), acquires
# one of $JOBS slots from the token FIFO (fd 9) before spawning a worker. The
# consumer returns a token only AFTER it installs the item, so at most $JOBS
# objects are ever outstanding on disk — prefetch depth is coupled to
# consumption and cannot materialize the whole snapshot in $TEMP_ROOT.
start_prefetch() {
  PREFETCH_DIR="${CONTROL_DIR}/prefetch"
  mkdir -p "$PREFETCH_DIR"
  chmod 700 "$PREFETCH_DIR"
  PREFETCH_PIDS="${PREFETCH_DIR}/worker.pids"
  : > "$PREFETCH_PIDS"
  PREFETCH_SLOTS_FIFO="${PREFETCH_DIR}/prefetch.slots"
  mkfifo "$PREFETCH_SLOTS_FIFO"
  exec 9<>"$PREFETCH_SLOTS_FIFO"
  local slot_token=0
  while [ "$slot_token" -lt "$JOBS" ]; do
    printf '\n' >&9
    slot_token=$((slot_token + 1))
  done
  (
    trap - EXIT HUP INT TERM
    producer_index=0
    while IFS=$'\t' read -r state remote_sha1 size expected_sha256 key relative encoding logical_size logical_sha256 reuse_source; do
      producer_index=$((producer_index + 1))
      if [ "$state" = "reused-local" ] && [ -n "$reuse_source" ]; then
        continue
      fi
      IFS= read -r producer_slot <&9 || break
      (
        trap - EXIT HUP INT TERM
        prefetch_fetch_one "$producer_index" "$key"
      ) &
      printf '%s\n' "$!" >> "$PREFETCH_PIDS"
    done < "$TODO"
    wait
  ) &
  PREFETCH_PRODUCER_PID=$!
}

# Consumer-side wait for one prefetched item; sets PREFETCH_RESULT/PREFETCH_TEMP.
# Fail-closed if the producer exits without ever publishing a status.
wait_for_prefetch() {
  local prefetch_index="$1"
  local prefetch_status="${PREFETCH_DIR}/${prefetch_index}.status"
  while [ ! -f "$prefetch_status" ]; do
    if [ -n "$PREFETCH_PRODUCER_PID" ] && ! kill -0 "$PREFETCH_PRODUCER_PID" 2>/dev/null; then
      [ -f "$prefetch_status" ] && break
      PREFETCH_RESULT="FAIL"; PREFETCH_TEMP=""
      return 0
    fi
    render_progress "$completed_work" "$total_work" "$item_index" "$item_count" "$(progress_subject "$relative")"
    sleep 0.2
  done
  IFS=$'\t' read -r PREFETCH_RESULT PREFETCH_TEMP < "$prefetch_status"
}

if [ -s "$TODO" ]; then
  hr; say "  ${B}${BL}Synchronizing…${X}"
  item_index=0; item_count=$(wc -l < "$TODO" | tr -d ' ')
  completed_work=0; total_work=$((total_xfer + local_reuse_bytes))
  PREFETCH_RESULT=""; PREFETCH_TEMP=""
  [ "$JOBS" -gt 1 ] && start_prefetch
  while IFS=$'\t' read -r state remote_sha1 size expected_sha256 key relative encoding logical_size logical_sha256 reuse_source; do
    item_index=$((item_index + 1))
    if [ ! -t 1 ]; then
      say "  ${B}▸${X} [${item_index}/${item_count}] ${relative} ${D}($(human "$size"), ${state})${X}"
    fi
    log_event "file start index=${item_index}/${item_count} state=${state} bytes=${size} path=${relative}"
    fs_guard prepare "$relative" || exit 1
    # A prefetched item mirrors the producer's skip rule exactly, so token
    # acquire (producer) and release (consumer) stay balanced.
    item_prefetched=0
    if [ "$JOBS" -gt 1 ]; then
      if [ "$state" = "reused-local" ] && [ -n "$reuse_source" ]; then
        item_prefetched=0
      else
        item_prefetched=1
      fi
    fi
    observed=""
    item_reused=0
    if [ "$item_prefetched" -eq 1 ]; then
      render_progress "$completed_work" "$total_work" "$item_index" "$item_count" "$(progress_subject "$relative")"
      wait_for_prefetch "$item_index"
      if [ "$PREFETCH_RESULT" != "OK" ]; then
        progress_newline
        say "\n${R}  Download failed on ${relative}; existing file was not replaced.${X}"
        tail -20 "${PREFETCH_DIR}/${item_index}.log" 2>/dev/null >&2
        exit 1
      fi
      temporary="$PREFETCH_TEMP"
      temp_relative="${temporary#"${DEST_ABS}"/}"
      observed="$(fs_guard hash "$temp_relative")" || exit 1
    else
      temporary="$(mktemp "${TEMP_ROOT}/object.XXXXXX")" || exit 1
      chmod 600 "$temporary"
      temp_relative="${temporary#"${DEST_ABS}"/}"
      if [ "$state" = "reused-local" ] && [ -n "$reuse_source" ]; then
        if observed="$(fs_guard copy "$reuse_source" "$temporary")"; then
          IFS=$'\t' read -r observed_size observed_sha1 observed_sha256 <<EOF
$observed
EOF
          # Reused bytes are what will sit on disk. A gzip row compares them with
          # its logical identity only; its stored transport object is never fetched.
          reuse_matches=1
          if [ "$encoding" = "gzip" ]; then
            if [ "$observed_size" != "$logical_size" ] || [ "$observed_sha256" != "$logical_sha256" ]; then
              reuse_matches=0
            fi
          elif [ "$observed_size" != "$size" ] \
            || { [ "$remote_sha1" != "unverified" ] && [ "$observed_sha1" != "$remote_sha1" ]; } \
            || { [ "$expected_sha256" != "unbound" ] && [ "$observed_sha256" != "$expected_sha256" ]; }; then
            reuse_matches=0
          fi
          if [ "$reuse_matches" -eq 0 ]; then
            progress_newline
            say "  ${Y}Local reuse candidate changed; downloading ${relative}.${X}"
            observed=""
          else
            item_reused=1
            [ ! -t 1 ] && say "    ${D}reused verified local content from ${reuse_source}${X}"
          fi
        else
          progress_newline
          say "  ${Y}Local reuse candidate became unavailable; downloading ${relative}.${X}"
          observed=""
        fi
      fi
      if [ -z "$observed" ]; then
        download_return_code=0
        download_log="${TEMP_ROOT}/b2-download.log"
        if [ -t 1 ]; then
          "${B2_RUN[@]}" file download --no-progress \
            --max-download-streams-per-file "$MAX_STREAMS_PER_FILE" \
            "b2://${BUCKET}/${key}" "$temporary" \
            > "$download_log" 2>&1 &
          download_process_id=$!
          while kill -0 "$download_process_id" 2>/dev/null; do
            partial_bytes=$(wc -c < "$temporary" | tr -d ' ')
            render_progress "$((completed_work + partial_bytes))" "$total_work" \
              "$item_index" "$item_count" "$(progress_subject "$relative")"
            sleep 1
          done
          wait "$download_process_id" || download_return_code=$?
          download_process_id=""
        else
          "${B2_RUN[@]}" file download --no-progress \
            --max-download-streams-per-file "$MAX_STREAMS_PER_FILE" \
            "b2://${BUCKET}/${key}" "$temporary" \
            > "$download_log" 2>&1 \
            || download_return_code=$?
        fi
        if [ "$download_return_code" -ne 0 ]; then
          progress_newline
          say "\n${R}  Download failed on ${relative}; existing file was not replaced.${X}"
          tail -20 "$download_log" >&2
          exit 1
        fi
        observed="$(fs_guard hash "$temp_relative")" || exit 1
      fi
    fi
    IFS=$'\t' read -r observed_size observed_sha1 observed_sha256 <<EOF
$observed
EOF
    install_temporary="$temporary"
    transport_temporary=""
    item_work="$size"
    if [ "$item_reused" -eq 1 ] && [ "$encoding" = "gzip" ]; then
      # Already verified above against the logical identity of the decoded file.
      proof="activated_plan_logical_sha256_verified"
      item_work="$logical_size"
    else
      if [ "$observed_size" != "$size" ]; then
        say "${R}download size mismatch for ${relative}${X}"; exit 1
      fi
      if [ "$remote_sha1" != "unverified" ] && [ "$observed_sha1" != "$remote_sha1" ]; then
        say "${R}download SHA-1 mismatch for ${relative}${X}"; exit 1
      fi
      if [ "$expected_sha256" != "unbound" ] && [ "$observed_sha256" != "$expected_sha256" ]; then
        say "${R}download SHA-256 violates activated plan for ${relative}${X}"; exit 1
      fi
      if [ "$encoding" = "gzip" ]; then
        # The verified stored object is a gzip transport encoding: decode it into
        # a second private temp (capped at the logical size), then hold the decoded
        # bytes to the activated logical size and SHA-256 before anything installs.
        decoded_temporary="$(mktemp "${TEMP_ROOT}/decoded.XXXXXX")" || exit 1
        chmod 600 "$decoded_temporary"
        if ! decoded="$(fs_guard gunzip "$temp_relative" "$decoded_temporary" "$logical_size")"; then
          progress_newline
          say "${R}gzip transport object failed to decode for ${relative}; existing file was not replaced.${X}"
          exit 1
        fi
        IFS=$'\t' read -r observed_size observed_sha1 observed_sha256 <<EOF
$decoded
EOF
        if [ "$observed_size" != "$logical_size" ]; then
          say "${R}decoded size mismatch for ${relative}${X}"; exit 1
        fi
        if [ "$observed_sha256" != "$logical_sha256" ]; then
          say "${R}decoded SHA-256 violates activated plan for ${relative}${X}"; exit 1
        fi
        install_temporary="$decoded_temporary"
        transport_temporary="$temporary"
        proof="activated_plan_gzip_decoded_sha256_verified"
        log_event "file decode encoding=gzip stored_bytes=${size} logical_bytes=${observed_size} path=${relative}"
      elif [ "$expected_sha256" != "unbound" ]; then
        proof="activated_plan_sha256_verified"
      elif [ "$remote_sha1" = "unverified" ]; then
        proof="downloaded_local_sha256_remote_sha1_unavailable"
      else
        proof="remote_sha1_verified"
      fi
    fi
    fs_guard validate-tree || exit 1
    fs_guard install "$relative" "$install_temporary" || exit 1
    [ -n "$transport_temporary" ] && { rm -f -- "$transport_temporary" || exit 1; }
    if [ "$encoding" = "gzip" ]; then
      # Recorded as what is on disk: the decoded size and digest, with no remote
      # SHA-1 (the manifest step attaches the stored transport identity).
      printf '%s\t%s\t%s\t%s\t%s\n' "$relative" "$observed_size" "unverified" "$observed_sha256" "$proof" >> "$HASHES"
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "$relative" "$size" "$remote_sha1" "$observed_sha256" "$proof" >> "$HASHES"
    fi
    completed_work=$((completed_work + item_work))
    render_progress "$completed_work" "$total_work" "$item_index" "$item_count" "$(progress_subject "$relative")"
    log_event "file finish index=${item_index}/${item_count} bytes=${size} path=${relative} proof=${proof}"
    # Return the pipeline slot only now, after the item is verified and installed,
    # so the producer never runs more than $JOBS objects ahead of consumption.
    [ "$item_prefetched" -eq 1 ] && printf '\n' >&9
  done < "$TODO"
  progress_newline
  if [ "$JOBS" -gt 1 ]; then
    wait "$PREFETCH_PRODUCER_PID" 2>/dev/null || true
    PREFETCH_PRODUCER_PID=""
    exec 9>&-
  fi
fi

render_bundle_guides() {
  local finalized_manifest="$1"
  local guide_root="$TEMP_ROOT/generated-guides"
  mkdir -p "$guide_root"
  "${PY[@]}" - "$finalized_manifest" "$guide_root" <<'PYEOF' \
    || { say "${R}could not build the active bundle guides${X}"; exit 1; }
import json
import sys
from pathlib import Path

manifest_path, guide_root = sys.argv[1:]
manifest = json.load(open(manifest_path, encoding="utf-8"))
if not isinstance(manifest, dict) or manifest.get("schema") != 6:
    raise SystemExit("finalized local manifest must use schema 6")
active = manifest.get("active_results")
files = manifest.get("files")
omitted = manifest.get("omitted_files")
unavailable = manifest.get("unavailable_files")
retained = manifest.get("retained_files")
if not all(
    isinstance(value, dict) for value in (active, files, omitted, unavailable, retained)
):
    raise SystemExit("finalized local manifest materialization maps are malformed")
guide_root_path = Path(guide_root)

# The attic README rides with any sync that leaves retained bytes behind — even
# a lab-only sync with no active results section, which skips the other guides.
retained_flagged_unavailable = {
    relative: record
    for relative, record in unavailable.items()
    if record.get("retained") is True
}
if retained or retained_flagged_unavailable:
    attic_lines = [
        "# Retention attic — NOT part of the active snapshot",
        "",
        "Files in this directory were part of an earlier verified snapshot and are",
        "no longer named by the active one. `genome-sync` keeps their bytes instead",
        "of deleting them (deletion is only ever the explicit `--prune` flag), but",
        "they are **outside the current activation**: never cite them as activated",
        "evidence, and never prefer them over a file of the same name in the live",
        "tree. The live tree (everything outside `_retained/`) is exactly the",
        "active snapshot.",
        "",
        "The authoritative inventory is `../.genome-manifest.json` → `retained_files`",
        "(each record carries `original_path`). Run `genome-sync --prune` to delete",
        "everything here; a later snapshot that re-adds a file restores it to the",
        "live tree automatically from these bytes.",
        "",
        "## Contents",
        "",
    ]
    for relative, record in sorted({**retained, **retained_flagged_unavailable}.items()):
        original = record.get("original_path", relative)
        attic_lines.append(f"- `{relative}` — dropped from `{original}`")
    attic_root = guide_root_path / "_retained"
    attic_root.mkdir(parents=True, exist_ok=False)
    (attic_root / "README.md").write_text("\n".join(attic_lines) + "\n", encoding="utf-8")

if not active:
    raise SystemExit(0)
root_lines = [
    "# Active genome bundles",
    "",
    "This index is generated from `.genome-manifest.json`. Its `active_results`",
    "map binds the verified remote activation for each assay. The manifest's",
    "`materialization`, `omitted_files`, and `unavailable_files` fields say which activated bytes are local.",
    "`retained_files` lists kept files that the active snapshot no longer names; they live under `_retained/` and are not activated bytes.",
    "",
    "| Assay | Sample | Updated | Local | Results plan | Results index |",
    "|---|---|---|---|---|---|",
]
known_paths = set(files) | set(omitted) | set(unavailable) | set(retained)
lab_assays = {
    relative.split("/", 1)[0]
    for relative in known_paths
    if "/lab/" in relative
}

for assay, record in sorted(active.items()):
    if not isinstance(record, dict):
        raise SystemExit(f"active result record is malformed for assay {assay}")
    local_path = record["local_path"]
    local_complete = record.get("local_materialization_complete")
    omitted_count = record.get("omitted_file_count")
    unavailable_count = record.get("unavailable_file_count")
    if (
        type(local_complete) is not bool
        or isinstance(omitted_count, bool)
        or not isinstance(omitted_count, int)
        or omitted_count < 0
        or isinstance(unavailable_count, bool)
        or not isinstance(unavailable_count, int)
        or unavailable_count < 0
    ):
        raise SystemExit(f"active result materialization is malformed for assay {assay}")
    local_label = "complete" if local_complete else "partial"
    root_lines.append(
        f"| {assay} | {record['sample_id']} | {record['authorized_at']} | "
        f"{local_label} | `{record['plan_sha256']}` | "
        f"[open {local_path}]({local_path}/TOC.md) |"
    )
    assay_root = guide_root_path / assay
    assay_root.mkdir(parents=True, exist_ok=False)
    has_lab = assay in lab_assays
    if local_complete:
        materialization_line = "- Local materialization includes every activated payload."
    else:
        partial_reasons = []
        if omitted_count:
            partial_reasons.append(f"{omitted_count} intentionally omitted")
        if unavailable_count:
            partial_reasons.append(f"{unavailable_count} missing or corrupt")
        if not partial_reasons:
            partial_reasons.append("remote activation is not locally validated")
        materialization_line = (
            "- Local materialization is partial: " + "; ".join(partial_reasons) + "."
        )
    lab_line = (
        "- [Lab and sequencing files](lab/) — read `lab_manifest.json` and "
        "`_COMPLETE.json` before using them."
        if has_lab
        else "- Lab files are not part of this synchronized selection."
    )
    assay_readme = [
        f"# Assay: {assay}",
        "",
        f"This directory keeps the lab inputs and current interpreted results for sample `{record['sample_id']}` together.",
        "",
        f"- [Current results](results/) — plan `{record['plan_sha256']}`, activated {record['authorized_at']}",
        materialization_line,
        lab_line,
        "- [Assay contents](TOC.md)",
        "",
        "Run `genome-sync` to refresh this index and the managed files. The exact local authority is `../.genome-manifest.json`.",
    ]
    assay_toc = [
        f"# {assay} contents",
        "",
        f"Sample: `{record['sample_id']}`  ",
        f"Active results plan: `{record['plan_sha256']}`  ",
        f"Activated: {record['authorized_at']}",
        f"Local materialization: {local_label}",
        "",
        "## Results",
        "",
        "Open [results/TOC.md](results/TOC.md) for the stage-by-stage index. "
        "`results/manifest.json` is the exact shipped-object inventory.",
        "",
        "## Lab",
        "",
        (
            "Open [lab/](lab/). Its `lab_manifest.json` and `_COMPLETE.json` bind the verified lab snapshot."
            if has_lab
            else "Lab files are not part of this synchronized selection."
        ),
    ]
    assay_agent = [
        f"# Agent guide: {assay}",
        "",
        f"This directory is the assay container for sample `{record['sample_id']}`. Work read-only unless the donor explicitly asks for a local change.",
        "",
        "Read `../.genome-manifest.json` first. Its `active_results` entry identifies the exact plan and local results path. Then read `results/AGENTS.md` for the evidence and interpretation contract and `results/TOC.md` to locate stages.",
        "The remote activation and the local materialization are separate facts. Check `materialization.complete`, `omitted_files`, and `unavailable_files` before claiming a payload is local.",
        "`results/manifest.json` may list a large text file under its stored `.gz` name with `encoding`, `logical_path`, `logical_bytes`, and `logical_sha256`: it travelled gzip-compressed and only the decoded file exists here, at its `logical_path`, matching `logical_sha256`. Its `.genome-manifest.json` record names the stored object under `transport`.",
        "Files under `_retained/` (manifest `retained_files`) are kept local bytes from an earlier snapshot; they are outside the current activation, so never cite them as activated evidence. Everything outside `_retained/` is exactly the active snapshot. `unavailable_files` entries flagged `retained` describe those leftovers too, and are excluded from every `materialization` count.",
        "",
        "Treat `lab/` as sequencing evidence, not interpretation. Validate `lab/lab_manifest.json` and `lab/_COMPLETE.json` before relying on it. Never upload donor-specific sequence, variants, genotypes, or findings to a network service without explicit informed permission.",
        "",
        f"Active results plan: `{record['plan_sha256']}` (activated {record['authorized_at']}).",
    ]
    (assay_root / "README.md").write_text("\n".join(assay_readme) + "\n", encoding="utf-8")
    (assay_root / "TOC.md").write_text("\n".join(assay_toc) + "\n", encoding="utf-8")
    agent_text = "\n".join(assay_agent) + "\n"
    (assay_root / "AGENTS.md").write_text(agent_text, encoding="utf-8")
    (assay_root / "CLAUDE.md").write_text(agent_text, encoding="utf-8")

(guide_root_path / "TOC.md").write_text("\n".join(root_lines) + "\n", encoding="utf-8")
PYEOF
  [ -f "$guide_root/TOC.md" ] || [ -f "$guide_root/_retained/README.md" ] || return 0
  chmod -R go-rwx "$guide_root"
  [ -f "$guide_root/TOC.md" ] && { fs_guard install "TOC.md" "$guide_root/TOC.md" || exit 1; }
  while IFS= read -r guide_path; do
    relative_guide="${guide_path#"$guide_root/"}"
    fs_guard install "$relative_guide" "$guide_path" || exit 1
  done < <(find "$guide_root" -mindepth 2 -maxdepth 2 -type f -name '*.md' | sort)
}

if [ "$prune_n" -gt 0 ] && [ "$PRUNE" -eq 1 ]; then
  say "\n  ${R}Removing ${prune_n} file(s) absent remotely:${X}"
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    say "    ${R}✗${X} ${relative}"
    fs_guard remove "$relative" || exit 1
    fs_guard prune-empty-parents "$relative" || exit 1
    log_event "file remove path=${relative}"
  done < "$PRUNES"
  # The attic README is client-owned, not managed; drop it once the attic empties
  # so an empty `_retained/` directory does not linger behind a full prune.
  if [ -f "$DEST_ABS/_retained/README.md" ]; then
    fs_guard remove "_retained/README.md" || exit 1
    fs_guard prune-empty-parents "_retained/README.md" || exit 1
  fi
elif [ "$prune_n" -gt 0 ]; then
  # Retention keeps the bytes but takes them out of the live tree: everything
  # under the destination outside `_retained/` is exactly the active snapshot,
  # so a later reader never mistakes a dropped file for activated evidence.
  if [ "$move_n" -gt 0 ]; then
    say "\n  ${Y}Retiring ${move_n} file(s) no longer in the active snapshot to _retained/:${X}"
  else
    say "\n  ${D}${attic_n} file(s) from earlier snapshots remain in _retained/:${X}"
  fi
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    case "$relative" in
      _retained/*)
        say "    ${D}·${X} ${relative}"
        log_event "file retain path=${relative}"
        ;;
      *)
        say "    ${Y}→${X} ${relative} ${D}→ _retained/${relative}${X}"
        fs_guard move "$relative" "_retained/${relative}" || exit 1
        fs_guard prune-empty-parents "$relative" || exit 1
        log_event "file retire path=${relative} attic=_retained/${relative}"
        ;;
    esac
  done < "$PRUNES"
  say "    ${D}(retained bytes are outside the active snapshot; pass --prune to delete them)${X}"
fi

fs_guard validate-tree || exit 1
manifest_temporary="$TEMP_ROOT/manifest.json"
"${PY[@]}" - "$manifest_temporary" "$DONOR" "$BUCKET" "$VERIFIED" "$FILTERED" "$OMITTED" "$HASHES" "$DEST_ABS/$MANIFEST" "$ONLY" "$EXCLUDE" "$ACTIVE_RESULTS" "$DEST_ABS" "$PRUNE" <<'PYEOF' \
  || { say "${R}could not build a complete local manifest${X}"; exit 1; }
import datetime
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path, PurePosixPath

(
    manifest_path,
    donor,
    bucket,
    verified_path,
    filtered_path,
    omitted_path,
    hashes_path,
    existing_manifest_path,
    only,
    exclude,
    active_results_path,
    location,
    prune_requested_text,
) = sys.argv[1:]
prune_requested = prune_requested_text == "1"

def section_of(relative):
    if relative.startswith("ensemble/"):
        return "ensemble"
    if "/lab/" in relative or relative.endswith("/lab"):
        return "lab"
    return "results"

SHA1_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
destination_root = Path(location)

def canonical_managed_relative(relative):
    if (
        not isinstance(relative, str)
        or not relative
        or "\\" in relative
        or any(character in relative for character in "\x00\n\r\t")
    ):
        raise SystemExit(f"existing manifest has a noncanonical managed path: {relative!r}")
    parsed = PurePosixPath(relative)
    if (
        parsed.is_absolute()
        or parsed.as_posix() != relative
        or any(part in {"", ".", ".."} for part in parsed.parts)
    ):
        raise SystemExit(f"existing manifest has a noncanonical managed path: {relative!r}")
    return parsed

def normalize_file_record(record, *, relative):
    if not isinstance(record, dict):
        raise SystemExit(f"existing file record is malformed: {relative}")
    size = record.get("size")
    remote_sha1 = record.get("remote_sha1")
    sha256 = record.get("sha256")
    proof = record.get("proof")
    if isinstance(size, bool) or not isinstance(size, int) or size < 0:
        raise SystemExit(f"existing file size is malformed: {relative}")
    if remote_sha1 is not None and (
        not isinstance(remote_sha1, str) or SHA1_RE.fullmatch(remote_sha1) is None
    ):
        raise SystemExit(f"existing file SHA-1 is malformed: {relative}")
    if not isinstance(sha256, str) or SHA256_RE.fullmatch(sha256) is None:
        raise SystemExit(f"existing file SHA-256 is malformed: {relative}")
    if not isinstance(proof, str) or not proof:
        raise SystemExit(f"existing file proof is malformed: {relative}")
    normalized = {
        "size": size,
        "remote_sha1": remote_sha1,
        "sha256": sha256,
        "proof": proof,
    }
    # Optional: the stored gzip object this decoded local file came from. It
    # rides with the record when carried or retired so provenance is never lost.
    transport = record.get("transport")
    if transport is not None:
        if (
            not isinstance(transport, dict)
            or set(transport) != {"encoding", "path", "bytes", "sha256", "remote_sha1"}
            or transport["encoding"] != "gzip"
            or isinstance(transport["bytes"], bool)
            or not isinstance(transport["bytes"], int)
            or transport["bytes"] < 0
            or not isinstance(transport["sha256"], str)
            or SHA256_RE.fullmatch(transport["sha256"]) is None
            or (
                transport["remote_sha1"] is not None
                and (
                    not isinstance(transport["remote_sha1"], str)
                    or SHA1_RE.fullmatch(transport["remote_sha1"]) is None
                )
            )
        ):
            raise SystemExit(f"existing file transport record is malformed: {relative}")
        canonical_managed_relative(transport["path"])
        normalized["transport"] = dict(transport)
    return normalized

def audit_carried_file(relative, record):
    parsed = canonical_managed_relative(relative)
    expected = normalize_file_record(record, relative=relative)
    path = destination_root.joinpath(*parsed.parts)
    try:
        before = path.lstat()
    except FileNotFoundError:
        return None, {**expected, "reason": "missing_local_file"}
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise SystemExit(f"carried manifest path is not a regular file: {relative}")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened_before = os.fstat(descriptor)
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 8 * 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        opened_after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    if identity(opened_before) != identity(opened_after) or identity(before) != identity(opened_after):
        raise SystemExit(f"carried local file changed while hashing: {relative}")
    observed_sha256 = digest.hexdigest()
    if opened_after.st_size != expected["size"]:
        return None, {
            **expected,
            "reason": "local_size_mismatch",
            "observed_size": opened_after.st_size,
            "observed_sha256": observed_sha256,
        }
    if observed_sha256 != expected["sha256"]:
        return None, {
            **expected,
            "reason": "local_sha256_mismatch",
            "observed_size": opened_after.st_size,
            "observed_sha256": observed_sha256,
        }
    return expected, None

requested_sections = {only} if only else {"lab", "results", "ensemble"}
if exclude:
    requested_sections.discard(exclude)

def read_plan_rows(path, *, duplicate_label):
    """Parse plan TSV rows keyed by local path (columns: see the plan writer)."""
    rows = {}
    for line in open(path, encoding="utf-8"):
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 8:
            raise SystemExit(f"malformed plan row: {fields[4] if len(fields) > 4 else line!r}")
        remote_sha1, size, expected_sha256, key, relative, encoding, logical_size, logical_sha256 = fields
        if relative in rows:
            raise SystemExit(f"{duplicate_label}: {relative}")
        if encoding not in {"identity", "gzip"} or not key.startswith(donor + "/"):
            raise SystemExit(f"malformed plan row: {relative}")
        rows[relative] = {
            "size": int(size),
            "remote_sha1": None if remote_sha1 == "unverified" else remote_sha1,
            "expected_sha256": expected_sha256,
            "stored_path": key[len(donor) + 1 :],
            "encoding": encoding,
            "logical_size": int(logical_size),
            "logical_sha256": logical_sha256,
        }
    return rows

def local_identity(row):
    """(size, remote SHA-1, SHA-256, transport) the local file at the row's path must
    carry. A gzip row is installed decoded: its bytes match the logical identity, no
    B2 object holds them (no remote SHA-1), and `transport` names the stored object."""
    if row["encoding"] == "gzip":
        return (
            row["logical_size"],
            None,
            row["logical_sha256"],
            {
                "encoding": "gzip",
                "path": row["stored_path"],
                "bytes": row["size"],
                "sha256": row["expected_sha256"],
                "remote_sha1": row["remote_sha1"],
            },
        )
    expected_sha256 = row["expected_sha256"]
    return (
        row["size"],
        row["remote_sha1"],
        None if expected_sha256 == "unbound" else expected_sha256,
        None,
    )

verified = read_plan_rows(verified_path, duplicate_label="duplicate verified remote path")
remote = read_plan_rows(filtered_path, duplicate_label="duplicate projected local path")
omitted = {}
for relative, row in read_plan_rows(
    omitted_path, duplicate_label="duplicate omitted remote path"
).items():
    size, remote_sha1, sha256, transport = local_identity(row)
    omitted[relative] = {
        "size": size,
        "remote_sha1": remote_sha1,
        "sha256": sha256,
        "reason": "user_deselected_large_payload",
        **({"transport": transport} if transport is not None else {}),
    }
if set(remote) & set(omitted) or set(verified) != set(remote) | set(omitted):
    raise SystemExit("selected and omitted rows do not partition the verified remote inventory")
observed = {}
for line in open(hashes_path, encoding="utf-8"):
    relative, size, remote_sha1, sha256, proof = line.rstrip("\n").split("\t")
    if relative in observed:
        raise SystemExit(f"duplicate local hash record: {relative}")
    observed[relative] = {
        "size": int(size),
        "remote_sha1": None if remote_sha1 == "unverified" else remote_sha1,
        "sha256": sha256,
        "proof": proof,
    }
if set(remote) != set(observed):
    raise SystemExit(f"manifest hash coverage differs from remote plan: missing={sorted(set(remote)-set(observed))[:5]}")
for relative, row in remote.items():
    record = observed[relative]
    size, remote_sha1, sha256, transport = local_identity(row)
    if (
        record["size"] != size
        or record["remote_sha1"] != remote_sha1
        or (sha256 is not None and record["sha256"] != sha256)
    ):
        raise SystemExit(f"manifest identity mismatch: {relative}")
    if transport is not None:
        record["transport"] = transport
existing = {}
existing_path = Path(existing_manifest_path)
if existing_path.exists():
    existing = json.load(open(existing_path, encoding="utf-8"))
    if not isinstance(existing, dict) or existing.get("donor") != donor:
        raise SystemExit("existing local manifest is malformed or belongs to another donor")
existing_files = existing.get("files", {})
if not isinstance(existing_files, dict) or any(not isinstance(item, dict) for item in existing_files.values()):
    raise SystemExit("existing local manifest files must be an object of records")
existing_unavailable = existing.get("unavailable_files", {})
if not isinstance(existing_unavailable, dict) or any(
    not isinstance(item, dict) for item in existing_unavailable.values()
):
    raise SystemExit("existing unavailable_files must be an object of records")
existing_retained = existing.get("retained_files", {})
if not isinstance(existing_retained, dict) or any(
    not isinstance(item, dict) for item in existing_retained.values()
):
    raise SystemExit("existing retained_files must be an object of records")
retained_and_materialized = sorted(set(existing_files) & set(existing_retained))
if retained_and_materialized:
    raise SystemExit(
        f"existing file is both materialized and retained: {retained_and_materialized[0]}"
    )
# A retained record that failed its byte audit is disclosed for that run only. It
# describes bytes outside the active snapshot, so reading it back as active state
# would pin `materialization` to a partial that the snapshot never had.
existing_active_unavailable = {
    relative: record
    for relative, record in existing_unavailable.items()
    if record.get("retained") is not True
}
carried_candidates = {
    relative: record
    for relative, record in existing_files.items()
    if section_of(relative) not in requested_sections
}
for relative, record in existing_active_unavailable.items():
    if section_of(relative) in requested_sections:
        continue
    if relative in carried_candidates:
        raise SystemExit(f"existing file is both materialized and unavailable: {relative}")
    carried_candidates[relative] = record
merged_files = {}
merged_unavailable = {}
for relative, record in sorted(carried_candidates.items()):
    carried, unavailable = audit_carried_file(relative, record)
    if carried is not None:
        merged_files[relative] = carried
    else:
        merged_unavailable[relative] = unavailable
merged_files.update(observed)

# Retention is the default. Previously managed bytes that the new active snapshot
# no longer names stay on disk unless --prune was given — but OUT of the live
# tree: the sync loop moved them under `_retained/`, so everything outside the
# attic is exactly the active snapshot. Records are keyed by their attic path
# (the on-disk location) and carry `original_path` for identity.
ATTIC_PREFIX = "_retained/"

def original_of(managed_key):
    if managed_key.startswith(ATTIC_PREFIX):
        return managed_key[len(ATTIC_PREFIX):]
    return managed_key

def audit_retained_file(original, record):
    """Audit dropped bytes where they actually live and key the record there.
    Normally that is the attic; a pre-attic manifest whose section was not part
    of this sync still holds the bytes in place, and the record must keep saying
    so until a sync of that section performs the move."""
    attic_key = ATTIC_PREFIX + original
    attic_disk = destination_root.joinpath(*canonical_managed_relative(attic_key).parts)
    if attic_disk.exists():
        return attic_key, *audit_carried_file(attic_key, record)
    original_disk = destination_root.joinpath(*canonical_managed_relative(original).parts)
    if original_disk.exists():
        return original, *audit_carried_file(original, record)
    return attic_key, *audit_carried_file(attic_key, record)

# Keyed by ORIGINAL path so a legacy in-place record and an attic record of the
# same dropped file collapse to one candidate. existing_files iterates last: on
# a re-drop its record describes the bytes the move just placed in the attic.
retained_candidates = {}
for managed_key, record in existing_retained.items():
    original = original_of(managed_key)
    if section_of(original) not in requested_sections:
        retained_candidates[original] = record
if not prune_requested:
    for managed_key, record in existing_retained.items():
        original = original_of(managed_key)
        if section_of(original) not in requested_sections:
            continue
        if managed_key == original and original in verified:
            # Legacy in-place retained bytes that the snapshot re-adds serve as
            # the active local file again; they never reach the attic.
            continue
        retained_candidates[original] = record
    for relative, record in existing_files.items():
        if section_of(relative) not in requested_sections or relative in verified:
            continue
        retained_candidates[relative] = record
merged_retained = {}
retained_unavailable = {}
for original, record in sorted(retained_candidates.items()):
    managed_key, carried, unavailable = audit_retained_file(original, record)
    if managed_key in merged_files:
        raise SystemExit(f"retained path is also an active manifest path: {managed_key}")
    if carried is not None:
        merged_retained[managed_key] = {
            **carried,
            "reason": "absent_from_active_snapshot",
            "original_path": original,
        }
    else:
        retained_unavailable[managed_key] = {
            **unavailable,
            "retained": True,
            "original_path": original,
        }

existing_omitted = existing.get("omitted_files", {})
if not isinstance(existing_omitted, dict) or any(
    not isinstance(item, dict) for item in existing_omitted.values()
):
    raise SystemExit("existing omitted_files must be an object of records")
merged_omitted = {
    relative: record
    for relative, record in existing_omitted.items()
    if section_of(relative) not in requested_sections
}
merged_omitted.update(omitted)
all_unavailable = {**merged_unavailable, **retained_unavailable}
manifest_partitions = (
    ("materialized", set(merged_files)),
    ("omitted", set(merged_omitted)),
    ("unavailable", set(all_unavailable)),
    ("retained", set(merged_retained)),
)
if len(merged_unavailable) + len(retained_unavailable) != len(all_unavailable):
    raise SystemExit("active and retained unavailable manifest paths must be disjoint")
for index, (left_label, left_paths) in enumerate(manifest_partitions):
    for right_label, right_paths in manifest_partitions[index + 1 :]:
        overlap = sorted(left_paths & right_paths)
        if overlap:
            raise SystemExit(
                f"{left_label} and {right_label} manifest paths must be disjoint: {overlap[0]}"
            )
# The attic namespace belongs exclusively to retention: active snapshot paths
# must never appear under it, and a retained record may sit outside it only as
# a not-yet-migrated legacy in-place record (its key then equals its original).
for label, paths in manifest_partitions[:3]:
    atticked = sorted(path for path in paths if path.startswith(ATTIC_PREFIX))
    if atticked and label != "unavailable":
        raise SystemExit(f"{label} manifest path invades the retention attic: {atticked[0]}")
    if label == "unavailable":
        for path in atticked:
            if all_unavailable[path].get("retained") is not True:
                raise SystemExit(f"active unavailable path invades the retention attic: {path}")

if "results" in requested_sections:
    active_results = json.load(open(active_results_path, encoding="utf-8"))
    if not isinstance(active_results, dict) or not active_results:
        raise SystemExit("results sync produced no active_results mapping")
else:
    active_results = existing.get("active_results", {})
if not isinstance(active_results, dict):
    raise SystemExit("active_results must be an object")
normalized_active_results = {}
root_result_assets = {"AGENTS.md", "CLAUDE.md", "README.md"}
required_active_fields = {
    "sample_id",
    "plan_sha256",
    "authorized_at",
    "completion_sha256",
    "local_path",
}
for assay, raw_record in sorted(active_results.items()):
    if not isinstance(assay, str) or re.fullmatch(r"[A-Za-z0-9._-]+", assay) is None:
        raise SystemExit(f"active result assay is not canonical: {assay!r}")
    if not isinstance(raw_record, dict) or not required_active_fields <= set(raw_record):
        raise SystemExit(f"active result record is malformed for assay {assay}")
    record = dict(raw_record)
    if (
        not isinstance(record["sample_id"], str)
        or re.fullmatch(r"[A-Za-z0-9._-]+", record["sample_id"]) is None
        or record["local_path"] != f"{assay}/results"
    ):
        raise SystemExit(f"active result identity is malformed for assay {assay}")
    for field in ("plan_sha256", "completion_sha256"):
        if not isinstance(record[field], str) or SHA256_RE.fullmatch(record[field]) is None:
            raise SystemExit(f"active result {field} is malformed for assay {assay}")
    try:
        authorized_at = datetime.datetime.fromisoformat(
            record["authorized_at"].replace("Z", "+00:00")
        )
    except (AttributeError, ValueError) as error:
        raise SystemExit(f"active result authorized_at is malformed for assay {assay}") from error
    if authorized_at.tzinfo is None or authorized_at.utcoffset() is None:
        raise SystemExit(f"active result authorized_at lacks a timezone for assay {assay}")
    remote_activation_validated = record.get("remote_activation_validated", True)
    if type(remote_activation_validated) is not bool:
        raise SystemExit(f"active result validation state is malformed for assay {assay}")
    affects_assay = lambda relative: (
        relative.startswith(f"{assay}/results/") or relative in root_result_assets
    )
    assay_omitted = {
        relative: omitted_record
        for relative, omitted_record in merged_omitted.items()
        if affects_assay(relative)
    }
    assay_unavailable = {
        relative: unavailable_record
        for relative, unavailable_record in merged_unavailable.items()
        if affects_assay(relative)
    }
    record["remote_activation_validated"] = remote_activation_validated
    record["local_materialization_complete"] = (
        remote_activation_validated and not assay_omitted and not assay_unavailable
    )
    record["omitted_file_count"] = len(assay_omitted)
    record["omitted_bytes"] = sum(item["size"] for item in assay_omitted.values())
    record["unavailable_file_count"] = len(assay_unavailable)
    record["unavailable_bytes"] = sum(item["size"] for item in assay_unavailable.values())
    normalized_active_results[assay] = record
active_results = normalized_active_results

synced_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
section_sync = existing.get("section_sync", {})
if not isinstance(section_sync, dict):
    raise SystemExit("existing section_sync must be an object")
section_sync = dict(section_sync)
for section in requested_sections:
    section_sync[section] = synced_at
payload = {
    "tool": "download-genome.sh",
    "schema": 6,
    "donor": donor,
    "bucket": bucket,
    "location": location,
    "synced_at": synced_at,
    "section_sync": dict(sorted(section_sync.items())),
    "active_results": dict(sorted(active_results.items())),
    "protected_local_paths": [
        "TOC.md",
        *[
            f"{assay}/{filename}"
            for assay in sorted(active_results)
            for filename in ("AGENTS.md", "CLAUDE.md", "README.md", "TOC.md")
        ],
        *(["_retained/README.md"] if merged_retained or retained_unavailable else []),
    ],
    "file_count": len(merged_files),
    "materialization": {
        "complete": not merged_omitted and not merged_unavailable,
        "verified_remote_file_count": (
            len(merged_files) + len(merged_omitted) + len(merged_unavailable)
        ),
        "verified_remote_bytes": sum(record["size"] for record in merged_files.values())
        + sum(record["size"] for record in merged_omitted.values())
        + sum(record["size"] for record in merged_unavailable.values()),
        "materialized_file_count": len(merged_files),
        "materialized_bytes": sum(record["size"] for record in merged_files.values()),
        "omitted_file_count": len(merged_omitted),
        "omitted_bytes": sum(record["size"] for record in merged_omitted.values()),
        "unavailable_file_count": len(merged_unavailable),
        "unavailable_bytes": sum(record["size"] for record in merged_unavailable.values()),
        "retained_file_count": len(merged_retained),
        "retained_bytes": sum(record["size"] for record in merged_retained.values()),
        "retained_unavailable_file_count": len(retained_unavailable),
        "retained_unavailable_bytes": sum(
            record["size"] for record in retained_unavailable.values()
        ),
    },
    "omitted_files": dict(sorted(merged_omitted.items())),
    "unavailable_files": dict(sorted(all_unavailable.items())),
    "retained_files": dict(sorted(merged_retained.items())),
    "files": dict(sorted(merged_files.items())),
}
with open(manifest_path, "w", encoding="utf-8") as destination:
    json.dump(payload, destination, indent=2, sort_keys=True)
    destination.write("\n")
PYEOF
chmod 600 "$manifest_temporary"
render_bundle_guides "$manifest_temporary"
fs_guard validate-tree || exit 1
fs_guard install "$MANIFEST" "$manifest_temporary" || exit 1

if [ "$COMMAND" = "setup" ] || [ "$COMMAND" = "sync" ]; then
  preference_only="$ONLY"
  preference_exclude="$EXCLUDE"
  if [ "$COMMAND" = "sync" ]; then
    preference_only="$configured_only"
    preference_exclude="$configured_exclude"
  fi
  if [ "$COMMAND" = "setup" ]; then
    GENOME_SYNC_KEY_ID="$KEY_ID" GENOME_SYNC_APPLICATION_KEY="$APP_KEY" \
      credential_store set "$DONOR" \
      || { say "\n${R}  Could not store the credential securely.${X}"; exit 1; }
  fi
  if ! config_write "$DONOR" "$DEST_ABS" "$preference_only" "$preference_exclude"; then
    if [ "$COMMAND" = "setup" ] && [ "$SETUP_REPEATED" -eq 0 ]; then
      credential_store delete "$DONOR" >/dev/null 2>&1 || true
    fi
    say "${Y}  Data synchronized, but the saved configuration could not be updated.${X}"
    exit 1
  fi
  if [ "$COMMAND" = "setup" ]; then
    say "  ${G}securely configured future syncs for ${DEST_ABS}${X}"
  fi
fi
unset KEY_ID APP_KEY B2_APPLICATION_KEY_ID B2_APPLICATION_KEY

log_event "finish status=success manifest=${DEST_ABS}/${MANIFEST}"
persist_log || { say "${Y}  Sync succeeded, but the local log could not be saved.${X}"; }
say "\n${G}${B}  ✓ Sync complete.${X}"
say "  ${B}Data:${X}     ${DEST_ABS}"
say "  ${B}Manifest:${X} ${DEST_ABS}/${MANIFEST}"
say "  ${B}Log:${X}      ${LOG_FILE}"
say "  ${D}Source files were accepted only after their B2 activation records and manifest hashes matched.${X}\n"
