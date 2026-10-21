#!/bin/bash
# CI Local backup: encrypted, versioned restic snapshots in a synced folder
# (Google Drive, iCloud, Dropbox, OneDrive, a disk…) or directly on cloud storage.
#
#   backup.sh                 full backup (GitHub mirrors, database dump, folders)
#   backup.sh --paths DIR...  back up just these paths (e.g. CI release artifacts), tag "ci"
#
# Settings come from backup.env, which the CI Local "Backups" window writes.
# Exit status is non-zero on failure; a Telegram alert is sent when configured.
set -uo pipefail

SUPPORT="$HOME/Library/Application Support/CI Local"
SETTINGS="$SUPPORT/backup.env"
STATUS="$SUPPORT/backup-status.json"
LOG="$HOME/Library/Logs/CI Local/backup.log"
STAGING="$HOME/Library/Caches/CI Local/backup-staging"
export PATH="/opt/homebrew/bin:/opt/homebrew/opt/libpq/bin:/usr/local/bin:/usr/bin:/bin"

mkdir -p "$(dirname "$LOG")" "$STAGING"
exec >>"$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') backup $*"

# Defaults, overridden by the settings file.
DRIVE_DIR=""
REPO_URL=""          # restic repository on cloud storage (s3:, b2:, azure:, gs:, sftp:, rest:, rclone:)
CLOUD_ENV_FILE="$HOME/.secrets/backup-cloud.env"
GITHUB_ENABLED=0
GITHUB_OWNER=""
DB_ENV_FILE="$HOME/.secrets/database-backup.env"
EXTRA_PATHS=""
GIT_REMOTES=""
SCAN_DIR=""
PASSWORD_FILE="$HOME/.secrets/restic-backup.pass"
KEEP="--keep-daily 7 --keep-weekly 4 --keep-monthly 6"
# shellcheck source=/dev/null
[ -f "$SETTINGS" ] && . "$SETTINGS"

STEP="start"
WARNINGS=()

write_status() { # ok message snapshot
  local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local msg=${2//\\/\\\\}; msg=${msg//\"/\\\"}
  printf '{"finishedAt":"%s","ok":%s,"message":"%s","snapshot":"%s"}\n' "$now" "$1" "$msg" "${3:-}" >"$STATUS"
}

alert() {
  local env="$HOME/.secrets/telegram.env"
  [ -f "$env" ] || return 0
  # shellcheck source=/dev/null
  ( . "$env"
    [ -n "${TELEGRAM_BOT:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || exit 0
    curl -s -m 15 "https://api.telegram.org/bot${TELEGRAM_BOT}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=⚠️ CI Local backup failed on $(hostname -s): $1" >/dev/null )
}

fail() {
  echo "FAILED at $STEP: $1"
  write_status false "Failed at $STEP: $1"
  alert "$STEP: $1"
  exit 1
}

[ -s "$PASSWORD_FILE" ] || fail "encryption password file missing: $PASSWORD_FILE"
command -v restic >/dev/null || fail "restic is not installed (brew install restic)"
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

STEP="open repository"
if [ -n "$REPO_URL" ]; then
  # Direct cloud storage: credentials (AWS_*, B2_*, AZURE_*, GOOGLE_*, RCLONE_*) come from a secrets file.
  # shellcheck source=/dev/null
  [ -f "$CLOUD_ENV_FILE" ] && { set -a; . "$CLOUD_ENV_FILE"; set +a; }
  export RESTIC_REPOSITORY="$REPO_URL"
  restic cat config >/dev/null 2>&1 || restic init || fail "cannot open or create $REPO_URL (check $CLOUD_ENV_FILE)"
else
  [ -n "$DRIVE_DIR" ] || fail "no backup destination chosen in CI Local → Backups"
  [ -d "$(dirname "$DRIVE_DIR")" ] || fail "backup folder is not available ($(dirname "$DRIVE_DIR")). Open your sync app or connect the disk."
  export RESTIC_REPOSITORY="$DRIVE_DIR/restic"
  if [ ! -f "$RESTIC_REPOSITORY/config" ]; then
    mkdir -p "$DRIVE_DIR" || fail "cannot create $DRIVE_DIR"
    restic init || fail "restic init failed"
  fi
fi

if [ "${1:-}" = "--paths" ]; then
  shift
  [ $# -gt 0 ] || fail "--paths needs at least one path"
  STEP="back up CI paths"
  out=$(restic backup --tag ci --json "$@" | tail -1) || fail "restic backup failed"
  snap=$(echo "$out" | sed -n 's/.*"snapshot_id":"\([^"]*\)".*/\1/p' | cut -c1-8)
  write_status true "CI paths backed up: $*" "$snap"
  echo "OK $snap"
  exit 0
fi

# 1. GitHub: keep a mirror of every repo the owner has, updated in place.
if [ "$GITHUB_ENABLED" = "1" ]; then
  STEP="mirror GitHub"
  command -v gh >/dev/null || fail "gh is not installed"
  owner=${GITHUB_OWNER:-$(gh api user --jq .login)} || fail "GitHub is not connected (gh auth login)"
  mkdir -p "$STAGING/github/$owner"
  repos=$(gh repo list "$owner" --limit 500 --json nameWithOwner --jq '.[].nameWithOwner') \
    || fail "could not list GitHub repos for $owner"
  for r in $repos; do
    dest="$STAGING/github/$r.git"
    if [ -d "$dest" ]; then
      git -c credential.helper= -c 'credential.helper=!gh auth git-credential' -C "$dest" remote update --prune >/dev/null 2>&1 \
        || WARNINGS+=("mirror update failed: $r")
    else
      gh repo clone "$r" "$dest" -- --mirror >/dev/null 2>&1 || WARNINGS+=("mirror clone failed: $r")
    fi
  done
fi

# 1b. Any other Git host: mirror each clone URL with this Mac's own Git credentials.
if [ -n "$GIT_REMOTES" ]; then
  STEP="mirror Git remotes"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    case "$url" in -*) WARNINGS+=("skipped suspicious URL: $url"); continue ;; esac
    # https://host/a/b.git, ssh://git@host/a/b.git, git@host:a/b.git -> host/a/b.git
    rel=$(printf '%s' "$url" | sed -E 's#^[a-z]+://##; s#^[^@/]+@##; s#:#/#; s#\.git$##').git
    dest="$STAGING/git/$rel"
    if [ -d "$dest" ]; then
      GIT_TERMINAL_PROMPT=0 git -C "$dest" remote update --prune >/dev/null 2>&1 || WARNINGS+=("mirror update failed: $url")
    else
      mkdir -p "$(dirname "$dest")"
      GIT_TERMINAL_PROMPT=0 git clone --mirror -- "$url" "$dest" >/dev/null 2>&1 || WARNINGS+=("mirror clone failed: $url")
    fi
  done <<<"$GIT_REMOTES"
fi

# 2. Database: custom-format pg_dump (needs pg_dump >= the server's major version).
rm -rf "$STAGING/db"; mkdir -p "$STAGING/db"
if [ -f "$DB_ENV_FILE" ]; then
  STEP="dump database"
  # shellcheck source=/dev/null
  ( . "$DB_ENV_FILE"
    [ -n "${SUPABASE_DB_URL:-}" ] || exit 3
    pg_dump --format=custom --no-owner --no-privileges --file "$STAGING/db/database.dump" "$SUPABASE_DB_URL" )
  case $? in
    0) ;;
    3) WARNINGS+=("SUPABASE_DB_URL missing in $DB_ENV_FILE") ;;
    *) fail "pg_dump failed (see $LOG)" ;;
  esac
else
  WARNINGS+=("no database file at $DB_ENV_FILE, database skipped")
fi

# 3. Secret files that live only on this Mac: .env files and signing keys under SCAN_DIR.
LIST="$STAGING/files.txt"
: >"$LIST"
if [ -n "$SCAN_DIR" ] && [ -d "$SCAN_DIR" ]; then
  STEP="find secret files"
  find "$SCAN_DIR" -maxdepth 6 \( -name node_modules -o -name worktrees -o -name .git -o -name .next -o -name Pods -o -name build \) -prune -o \
    -type f \( \( -name '.env*' ! -name '*.example' \) -o -name '*.jks' -o -name '*.keystore' ! -name 'debug.keystore' \
    -o -name '*.p8' -o -name '*.p12' -o -name '*.mobileprovision' \) -print >>"$LIST"
fi
[ -d "$HOME/.secrets" ] && echo "$HOME/.secrets" >>"$LIST"
while IFS= read -r p; do
  [ -n "$p" ] && { [ -e "$p" ] && echo "$p" >>"$LIST" || WARNINGS+=("folder not found: $p"); }
done <<<"$EXTRA_PATHS"
echo "$STAGING/github" >>"$LIST"
echo "$STAGING/git" >>"$LIST"
echo "$STAGING/db" >>"$LIST"

STEP="upload snapshot"
out=$(restic backup --tag nightly --files-from "$LIST" --json | tail -1) || fail "restic backup failed"
snap=$(echo "$out" | sed -n 's/.*"snapshot_id":"\([^"]*\)".*/\1/p' | cut -c1-8)

STEP="apply retention"
# shellcheck disable=SC2086
restic forget --tag nightly $KEEP --prune >/dev/null || WARNINGS+=("retention/prune failed")

msg="Snapshot $snap saved"
[ ${#WARNINGS[@]} -gt 0 ] && msg="$msg, with ${#WARNINGS[@]} warning(s): $(IFS='; '; echo "${WARNINGS[*]}")"
write_status true "$msg" "$snap"
echo "OK $msg"
