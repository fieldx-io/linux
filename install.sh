#!/usr/bin/env bash
# FieldX Linux agent — unified install, configure, upgrade (Debian/Ubuntu family).
#
# Recommended (portal can auto-fill org + access):
#   curl -fsSL .../install.sh | sudo bash -s -- --org ORG_CODE --access ACCESS_CODE
#
# Same enroll API as iOS Manager: POST /api/v1/app/enrol (MD5 username/password).
set -euo pipefail

INSTALLER_VERSION="1.0.0"
FIELDX_PKG="fieldx"
CONFIG_DIR="/var/lib/fieldx"
CONFIG_FILE="${CONFIG_DIR}/config.json"
LOG_DIR="/var/log/fieldx"
BUFFER_DIR="${LOG_DIR}/bufferedLogs"
SERVICE_NAME="fieldx.service"

DEFAULT_MANIFEST_URL="https://raw.githubusercontent.com/fieldx-io/linux/main/manifest.json"
DEFAULT_ENROLL_API_URL="https://portal.fieldx.io/api/v1/app/enrol"
MANIFEST_URL="${FIELDX_MANIFEST_URL:-$DEFAULT_MANIFEST_URL}"

ORG_CODE=""
ACCESS_CODE=""
TOKEN_FILE=""
RECONFIGURE=0
CHECK_ONLY=0
UNINSTALL=0
DRY_RUN=0
SKIP_SHA="${FIELDX_SKIP_SHA_VERIFY:-0}"
LOCAL_ARCHIVE=""
MANIFEST_FILE=""
ENROLL_API_URL=""

# Logs must go to stderr. Enrollment token is captured from stdout.
log() { printf '[fieldx] %s\n' "$*" >&2; }
die() { printf '[fieldx] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
FieldX Linux installer v${INSTALLER_VERSION}

Customer (portal copy-paste with org + access):
  curl -fsSL <install.sh url> | sudo bash -s -- --org ORG_CODE --access ACCESS_CODE

Options:
  --org CODE          Organization code (Enrollment Code page / portal)
  --access CODE       Access code (same page)
  --token-file PATH   Fallback: raw enrollment token from file (chmod 600)
  --reconfigure       Rewrite ${CONFIG_FILE} (re-enroll with --org/--access)
  --check             Print installed vs latest version
  --uninstall         Remove agent, service, and data
  --dry-run           Show actions without installing
  --local-archive PATH  Local .deb (or legacy .7z) for QA
  --manifest-file PATH  Local manifest.json
  --enroll-api URL    Override enrol endpoint (default from manifest)
  -h, --help

Environment:
  FIELDX_ORG / FIELDX_ACCESS   Same as --org / --access
  FIELDX_TOKEN_FILE            Default --token-file
  FIELDX_MANIFEST_URL / FIELDX_MANIFEST_FILE
  FIELDX_ENROLL_API_URL        Override enrol API
  FIELDX_SKIP_SHA_VERIFY=1     Skip package checksum (dev only)
EOF
}

load_manifest() {
  local path="${MANIFEST_FILE:-${FIELDX_MANIFEST_FILE:-}}"
  if [[ -n "$path" ]]; then
    [[ -f "$path" ]] || die "Manifest file not found: $path"
    MANIFEST_JSON="$(cat "$path")"
  else
    fetch_manifest
  fi
}

resolve_enroll_api_url() {
  if [[ -n "$ENROLL_API_URL" ]]; then
    return 0
  fi
  if [[ -n "${FIELDX_ENROLL_API_URL:-}" ]]; then
    ENROLL_API_URL="$FIELDX_ENROLL_API_URL"
    return 0
  fi
  local from_manifest=""
  from_manifest="$(manifest_get enroll_api_url 2>/dev/null || true)"
  if [[ -n "$from_manifest" && "$from_manifest" != "null" ]]; then
    ENROLL_API_URL="$from_manifest"
    return 0
  fi
  local base=""
  base="$(manifest_get config_defaults.BASE_URL 2>/dev/null || true)"
  if [[ -n "$base" && "$base" != "null" ]]; then
    ENROLL_API_URL="${base%/}/v1/app/enrol"
    return 0
  fi
  ENROLL_API_URL="$DEFAULT_ENROLL_API_URL"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --org) ORG_CODE="${2:-}"; shift 2 ;;
      --access) ACCESS_CODE="${2:-}"; shift 2 ;;
      --token-file) TOKEN_FILE="${2:-}"; shift 2 ;;
      --token|--token=*) die "Do not pass long tokens on the command line. Use --org/--access or --token-file." ;;
      --reconfigure) RECONFIGURE=1; shift ;;
      --check) CHECK_ONLY=1; shift ;;
      --uninstall) UNINSTALL=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --local-archive) LOCAL_ARCHIVE="${2:-}"; shift 2 ;;
      --manifest-file) MANIFEST_FILE="${2:-}"; shift 2 ;;
      --enroll-api) ENROLL_API_URL="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  if [[ -z "$ORG_CODE" && -n "${FIELDX_ORG:-}" ]]; then
    ORG_CODE="$FIELDX_ORG"
  fi
  if [[ -z "$ACCESS_CODE" && -n "${FIELDX_ACCESS:-}" ]]; then
    ACCESS_CODE="$FIELDX_ACCESS"
  fi
  if [[ -z "$TOKEN_FILE" && -n "${FIELDX_TOKEN_FILE:-}" ]]; then
    TOKEN_FILE="$FIELDX_TOKEN_FILE"
  fi
}

read_token_from_file() {
  local path="$1"
  [[ -f "$path" ]] || die "Token file not found: $path"
  local mode
  mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%OLp' "$path")"
  if [[ "$mode" != "600" && "$mode" != "400" ]]; then
    log "WARNING: token file should be chmod 600 (found ${mode})"
  fi
  local token
  token="$(tr -d '\r\n' <"$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$token" ]] || die "Token file is empty: $path"
  printf '%s' "$token"
}

prompt_for_token() {
  local token
  if [[ ! -e /dev/tty ]]; then
    die "No enrollment credentials. Pass --org CODE --access CODE (recommended), or --token-file PATH."
  fi
  printf 'Enrollment token (input hidden; prefer --org/--access): ' >/dev/tty
  read -rs token </dev/tty
  printf '\n' >/dev/tty
  [[ -n "$token" ]] || die "Empty token"
  printf '%s' "$token"
}

# Same contract as iOS DeviceEnrollmentAPI: POST /api/v1/app/enrol
# username=md5(org), password=md5(access); token from x-auth-token or JSON body.
enroll_via_api() {
  local org="$1" access="$2" api_url="$3"
  [[ -n "$org" && -n "$access" ]] || die "Both --org and --access are required"
  [[ -n "$api_url" ]] || die "Enrol API URL missing"

  log "Requesting enrollment token from enrol API..."
  FIELDX_ENROLL_ORG="$org" FIELDX_ENROLL_ACCESS="$access" FIELDX_ENROLL_URL="$api_url" python3 - <<'PY'
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

org = os.environ["FIELDX_ENROLL_ORG"].strip()
access = os.environ["FIELDX_ENROLL_ACCESS"].strip()
url = os.environ["FIELDX_ENROLL_URL"].strip()

def is_prehashed(value: str) -> bool:
    return len(value) == 32 and all(c in "0123456789abcdefABCDEF" for c in value)

def credential(value: str) -> str:
    trimmed = value.strip()
    if is_prehashed(trimmed):
        return trimmed.lower()
    return hashlib.md5(trimmed.encode("utf-8")).hexdigest()

# Match iOS: plain org uppercased before hash; prehashed left as-is (lower).
if is_prehashed(org):
    org_norm = org
else:
    org_norm = org.upper()
access_norm = access

username = credential(org_norm)
password = credential(access_norm)

payload = json.dumps({"request": {"username": username, "password": password}}).encode("utf-8")
req = urllib.request.Request(
    url,
    data=payload,
    method="POST",
    headers={"Content-Type": "application/json", "Accept": "application/json"},
)

try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        status = resp.getcode()
        header_token = (resp.headers.get("x-auth-token") or "").strip()
        body = resp.read().decode("utf-8", errors="replace")
except urllib.error.HTTPError as e:
    err_body = e.read().decode("utf-8", errors="replace")
    msg = err_body
    try:
        obj = json.loads(err_body)
        msg = obj.get("message") or (obj.get("response") or {}).get("message") or err_body
    except Exception:
        pass
    print(f"Enrollment failed HTTP {e.code}: {msg}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Enrollment request failed: {e}", file=sys.stderr)
    sys.exit(1)

def find_token(value):
    if value is None:
        return None
    if isinstance(value, str) and value.strip():
        return value.strip()
    if isinstance(value, dict):
        for key in ("token", "authToken", "bearerToken", "accessToken"):
            if key in value and isinstance(value[key], str) and value[key].strip():
                return value[key].strip()
        for nested in value.values():
            found = find_token(nested)
            if found:
                return found
    return None

def looks_like_error(value: str) -> bool:
    lowered = value.lower()
    if lowered.startswith("eyj"):
        return False
    return any(x in lowered for x in ("invalid", "denied", "error", "failed"))

token = header_token
if token and looks_like_error(token):
    print(f"Enrollment rejected: {token}", file=sys.stderr)
    sys.exit(1)

if not token:
    try:
        token = find_token(json.loads(body)) if body.strip() else None
    except json.JSONDecodeError:
        token = body.strip() or None

if not token:
    print("Enrollment succeeded but no token in x-auth-token or body.", file=sys.stderr)
    sys.exit(1)

# Prefer JWT; keep base32 envelope if that is what the server returned (agent resolves it).
print(token)
PY
}

resolve_enrollment_token() {
  if [[ -n "$ORG_CODE" || -n "$ACCESS_CODE" ]]; then
    [[ -n "$ORG_CODE" && -n "$ACCESS_CODE" ]] || die "Pass both --org and --access"
    resolve_enroll_api_url
    enroll_via_api "$ORG_CODE" "$ACCESS_CODE" "$ENROLL_API_URL"
    return 0
  fi
  if [[ -n "$TOKEN_FILE" ]]; then
    read_token_from_file "$TOKEN_FILE"
    return 0
  fi
  prompt_for_token
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo bash install.sh ..."
  fi
}

detect_platform_key() {
  if [[ ! -f /etc/os-release ]]; then
    die "Unsupported OS: missing /etc/os-release"
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  local id_like="${ID_LIKE:-}"
  local id="${ID:-}"
  case "$id" in
    debian|ubuntu|raspbian|linuxmint|pop) ;;
    *)
      if [[ "$id_like" != *debian* && "$id_like" != *ubuntu* ]]; then
        die "Unsupported distribution: ${PRETTY_NAME:-unknown} (Debian/Ubuntu family only)"
      fi
      ;;
  esac

  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) ARCH_KEY="debian-amd64" ;;
    aarch64|arm64) ARCH_KEY="debian-arm64" ;;
    *) die "Unsupported CPU architecture: $machine" ;;
  esac
}

installed_version() {
  if dpkg-query -W -f='${Status}' "$FIELDX_PKG" 2>/dev/null | grep -q "install ok installed"; then
    dpkg-query -W -f='${Version}' "$FIELDX_PKG" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

version_lt() {
  local a="$1" b="$2"
  if dpkg --compare-versions "$a" lt "$b" 2>/dev/null; then
    return 0
  fi
  return 1
}

fetch_manifest() {
  local tmp
  tmp="$(mktemp)"
  curl -fsSL --retry 3 --connect-timeout 30 --max-time 120 \
    "$MANIFEST_URL" -o "$tmp"
  MANIFEST_JSON="$(cat "$tmp")"
  rm -f "$tmp"
}

manifest_get() {
  local key="$1"
  FIELDX_MANIFEST_JSON="$MANIFEST_JSON" python3 -c '
import json, os, sys
key = sys.argv[1]
doc = json.loads(os.environ["FIELDX_MANIFEST_JSON"])
cur = doc
for part in key.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(2)
if isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print(cur)
' "$key"
}

ensure_deps() {
  # package_kind: deb (default) | 7z | tar.gz
  local package_kind="${1:-deb}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  local pkgs=(curl ca-certificates python3)
  if [[ "$package_kind" == "7z" ]]; then
    if ! command -v 7z >/dev/null 2>&1 && ! command -v 7za >/dev/null 2>&1; then
      pkgs+=(p7zip-full)
    fi
  fi
  apt-get install -y -qq "${pkgs[@]}"
}

verify_sha256() {
  local file="$1" expected="$2"
  if [[ -z "$expected" ]]; then
    if [[ "$SKIP_SHA" == "1" ]]; then
      log "WARNING: No SHA256 in manifest; skipping verify (FIELDX_SKIP_SHA_VERIFY=1)"
      return 0
    fi
    die "Manifest missing sha256 for package. Publish checksum or set FIELDX_SKIP_SHA_VERIFY=1 for dev only."
  fi
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    die "Checksum mismatch for downloaded package."
  fi
  log "Package checksum OK"
}

archive_kind() {
  # Prefer filename suffix; fall back to file(1) magic for renamed temp downloads.
  local archive="$1"
  case "$archive" in
    *.7z) echo "7z"; return 0 ;;
    *.tar.gz|*.tgz) echo "tar.gz"; return 0 ;;
    *.deb) echo "deb"; return 0 ;;
  esac
  local magic
  magic="$(file -b --mime-type "$archive" 2>/dev/null || file -b "$archive" 2>/dev/null || true)"
  case "$magic" in
    application/x-7z-compressed|*7-zip*|*"7-zip archive"*) echo "7z"; return 0 ;;
    application/gzip|application/x-gzip|application/x-tar) echo "tar.gz"; return 0 ;;
    application/vnd.debian.binary-package|application/x-debian-package) echo "deb"; return 0 ;;
  esac
  if file -b "$archive" 2>/dev/null | grep -qi '7-zip'; then
    echo "7z"
    return 0
  fi
  if file -b "$archive" 2>/dev/null | grep -qi 'debian.*package\|Debian binary package'; then
    echo "deb"
    return 0
  fi
  echo "unknown"
}

extract_archive() {
  local archive="$1" dest="$2"
  local kind
  kind="$(archive_kind "$archive")"
  mkdir -p "$dest"
  case "$kind" in
    7z)
      if command -v 7z >/dev/null 2>&1; then
        7z x -y "-o${dest}" "$archive" >/dev/null
      else
        7za x -y "-o${dest}" "$archive" >/dev/null
      fi
      ;;
    tar.gz)
      tar -xzf "$archive" -C "$dest"
      ;;
    deb)
      cp "$archive" "$dest/"
      ;;
    *)
      die "Unsupported archive type: $archive (kind=${kind})"
      ;;
  esac
}

find_inner_deb() {
  local root="$1" name="$2"
  local found
  found="$(find "$root" -type f -name "$name" 2>/dev/null | head -n 1)"
  [[ -n "$found" ]] || die "Package $name not found inside archive"
  printf '%s' "$found"
}

write_config() {
  local defaults_json="$1"
  mkdir -p "$CONFIG_DIR"
  chmod 755 "$CONFIG_DIR"

  if [[ -f "$CONFIG_FILE" && "$RECONFIGURE" -eq 0 && -n "$(installed_version)" ]]; then
    # Still allow re-enroll when org/access explicitly provided on upgrade path.
    if [[ -z "$ORG_CODE" && -z "$ACCESS_CODE" && -z "$TOKEN_FILE" ]]; then
      log "Keeping existing ${CONFIG_FILE}"
      return 0
    fi
  fi

  if [[ -f "$CONFIG_FILE" && "$RECONFIGURE" -eq 0 && -z "$ORG_CODE" && -z "$ACCESS_CODE" && -z "$TOKEN_FILE" ]]; then
    log "Keeping existing ${CONFIG_FILE}"
    return 0
  fi

  local token
  token="$(resolve_enrollment_token)"
  [[ -n "$token" ]] || die "Failed to obtain enrollment token"

  FIELDX_DEFAULTS_JSON="$defaults_json" python3 -c '
import json, os, sys
path = sys.argv[1]
token = sys.argv[2]
cfg = json.loads(os.environ["FIELDX_DEFAULTS_JSON"])
cfg["TOKEN"] = token
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
' "$CONFIG_FILE" "$token"
  chown root:root "$CONFIG_FILE"
  log "Wrote ${CONFIG_FILE}"
}

ensure_log_dirs() {
  mkdir -p "$BUFFER_DIR"
  chown -R root:root "$LOG_DIR"
  chmod -R 755 "$LOG_DIR"
}

install_deb() {
  local deb="$1"
  log "Installing package..."
  if ! dpkg -i "$deb"; then
    apt-get install -y -f -qq
  fi
}

start_service() {
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Service active: ${SERVICE_NAME}"
  else
    die "Service failed to start. Check: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
  fi
}

do_uninstall() {
  log "Uninstalling FieldX..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  apt-get remove --purge -y "$FIELDX_PKG" 2>/dev/null || true
  apt-get autoremove -y -qq 2>/dev/null || true
  rm -rf "$CONFIG_DIR" "$LOG_DIR"
  systemctl daemon-reload
  log "Uninstall complete"
}

do_install_or_upgrade() {
  load_manifest
  local remote_ver
  remote_ver="$(manifest_get agent_version)" || die "Invalid manifest: agent_version"
  local local_ver
  local_ver="$(installed_version)"

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    log "Installed: ${local_ver:-none}  Latest: ${remote_ver}"
    if [[ -z "$local_ver" ]]; then
      exit 1
    fi
    if version_lt "$local_ver" "$remote_ver"; then
      exit 1
    fi
    exit 0
  fi

  if [[ -z "$local_ver" ]]; then
    log "Fresh install (target ${remote_ver})"
  elif version_lt "$local_ver" "$remote_ver"; then
    log "Upgrade ${local_ver} -> ${remote_ver}"
  else
    log "Already at ${local_ver} (latest ${remote_ver})"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "Dry run: would ensure config + service"
      return 0
    fi
    write_config "$(manifest_get config_defaults)"
    ensure_log_dirs
    start_service
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run: would install ${ARCH_KEY} agent ${remote_ver}"
    if [[ -n "$ORG_CODE" ]]; then
      log "Dry run: would enroll via API with --org/--access"
    fi
    return 0
  fi

  local archive_url sha inner_deb
  archive_url="$(manifest_get "packages.${ARCH_KEY}.archive_url")" || die "No package for ${ARCH_KEY}"
  sha="$(manifest_get "packages.${ARCH_KEY}.sha256" 2>/dev/null || echo "")"
  inner_deb="$(manifest_get "packages.${ARCH_KEY}.inner_deb")" || inner_deb="fieldx.deb"

  local work deb_path archive extract kind
  work="$(mktemp -d)"
  # Global path for EXIT trap (locals are gone when trap runs under set -u).
  FIELDX_TMP_WORK="$work"
  trap 'rm -rf "${FIELDX_TMP_WORK:-}"' EXIT

  # Keep a real extension so extractors can detect type (avoid bare .archive).
  if [[ -n "$LOCAL_ARCHIVE" ]]; then
    [[ -f "$LOCAL_ARCHIVE" ]] || die "Local archive not found: $LOCAL_ARCHIVE"
    case "$LOCAL_ARCHIVE" in
      *.7z) archive="${work}/package.7z" ;;
      *.tar.gz|*.tgz) archive="${work}/package.tar.gz" ;;
      *.deb) archive="${work}/package.deb" ;;
      *) archive="${work}/package.bin" ;;
    esac
    cp "$LOCAL_ARCHIVE" "$archive"
    log "Using local package: $LOCAL_ARCHIVE"
    if [[ -z "$sha" && "$SKIP_SHA" != "1" ]]; then
      log "WARNING: No SHA256; set FIELDX_SKIP_SHA_VERIFY=1 for local package"
      SKIP_SHA=1
    fi
  else
    case "$archive_url" in
      *.7z) archive="${work}/package.7z" ;;
      *.tar.gz|*.tgz) archive="${work}/package.tar.gz" ;;
      *.deb) archive="${work}/package.deb" ;;
      *) archive="${work}/package.bin" ;;
    esac
    log "Downloading agent package..."
    curl -fsSL --retry 3 --connect-timeout 30 --max-time 600 "$archive_url" -o "$archive"
  fi

  kind="$(archive_kind "$archive")"
  ensure_deps "$kind"
  verify_sha256 "$archive" "$sha"

  if [[ "$kind" == "deb" ]]; then
    deb_path="$archive"
  else
    extract="${work}/extract"
    extract_archive "$archive" "$extract"
    deb_path="$(find_inner_deb "$extract" "$inner_deb")"
  fi

  install_deb "$deb_path"
  write_config "$(manifest_get config_defaults)"
  ensure_log_dirs
  start_service
  log "FieldX ${remote_ver} ready."
  trap - EXIT
  rm -rf "$work"
}

main() {
  parse_args "$@"
  require_root
  detect_platform_key

  if [[ "$UNINSTALL" -eq 1 ]]; then
    do_uninstall
    exit 0
  fi

  do_install_or_upgrade
}

main "$@"
