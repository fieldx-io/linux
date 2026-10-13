#!/usr/bin/env bash
# FieldX Linux agent — unified install, configure, upgrade (Debian/Ubuntu family).
#
# Recommended (portal can auto-fill org + access):
#   curl -fsSL .../install.sh | sudo bash -s -- --org ORG_CODE --access ACCESS_CODE
#
set -euo pipefail

INSTALLER_VERSION="1.0.0"
FIELDX_PKG="fieldx"
CONFIG_DIR="/var/lib/fieldx"
CONFIG_FILE="${CONFIG_DIR}/config.json"
LOG_DIR="/var/log/fieldx"
BUFFER_DIR="${LOG_DIR}/bufferedLogs"
SERVICE_NAME="fieldx.service"

DEFAULT_MANIFEST_URL="https://raw.githubusercontent.com/fieldx-io/linux/main/manifest.json"
FIELDX_ENROLL_BIN="/usr/bin/fieldx-enroll"
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

enroll_via_api() {
  local org="$1" access="$2" api_url="${3:-}"
  [[ -n "$org" && -n "$access" ]] || die "Both --org and --access are required"
  [[ -x "$FIELDX_ENROLL_BIN" ]] || die "FieldX is not installed (${FIELDX_ENROLL_BIN} missing). Install or upgrade the agent package first."

  log "Requesting enrollment token..."
  local -a cmd=("$FIELDX_ENROLL_BIN" --org "$org" --access "$access")
  if [[ -n "$api_url" ]]; then
    cmd+=(--enroll-api "$api_url")
  fi
  local token=""
  if ! token="$("${cmd[@]}")"; then
    die "Enrollment failed (see messages above)"
  fi
  [[ -n "$token" ]] || die "Enrollment returned an empty token"
  printf '%s' "$token"
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

should_reenroll() {
  [[ "$RECONFIGURE" -eq 1 ]] && return 0
  [[ -n "$TOKEN_FILE" ]] && return 0
  [[ -n "$ORG_CODE" && -n "$ACCESS_CODE" ]] && return 0
  return 1
}

write_config() {
  local defaults_json="$1"
  mkdir -p "$CONFIG_DIR"
  chmod 755 "$CONFIG_DIR"

  if [[ -f "$CONFIG_FILE" && -n "$(installed_version)" ]] && ! should_reenroll; then
    log "Keeping existing ${CONFIG_FILE} (pass --org and --access, --reconfigure, or --token-file to re-enroll)"
    return 0
  fi

  if should_reenroll; then
    log "Re-enrolling and updating TOKEN in ${CONFIG_FILE}..."
  fi

  local token
  token="$(resolve_enrollment_token)"
  [[ -n "$token" ]] || die "Failed to obtain enrollment token"

  FIELDX_DEFAULTS_JSON="$defaults_json" python3 -c '
import json, os, sys
path = sys.argv[1]
token = sys.argv[2]
defaults = json.loads(os.environ["FIELDX_DEFAULTS_JSON"])
cfg = dict(defaults)
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        cfg.update(json.load(f))
for key, value in defaults.items():
    cfg[key] = value
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
    if should_reenroll; then
      log "Package unchanged; applying new enrollment credentials"
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
