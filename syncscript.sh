#!/usr/bin/env bash
# =============================================================================
# sync-pictures.sh — Atomic, queue-based CIFS sync with full recovery
# =============================================================================
# Architecture:
#   SOURCE_DIR/          — incoming files land here
#   QUEUE_DIR/           — files are hard-linked here before any destructive op
#   QUEUE_DIR/.done/     — successfully processed files are moved here
#   QUEUE_DIR/.failed/   — files that failed conversion land here
#   LOCK_FILE            — prevents concurrent runs
#   LOG_FILE             — append-only structured log
#
# Atomicity guarantees:
#   1. A file is never deleted from SOURCE until it is confirmed written to MOUNT.
#   2. Conversion happens in a WORK_DIR; originals are untouched until success.
#   3. All writes to MOUNT use a .<file>.tmp staging name, renamed only on success.
#   4. If the mount is lost mid-run, the queue survives for the next run.
#   5. Any failure leaves SOURCE intact and logs the item to .failed/.
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
MOUNT_POINT="/mnt/Pictures"
SOURCE_DIR="/home/vnaftp"
QUEUE_DIR="/var/spool/pictures-sync"        # persistent across reboots
WORK_DIR="/tmp/pictures-work-$$"            # per-run scratch space (cleaned up)
LOCK_FILE="/var/run/pictures-sync.lock"
LOG_FILE="/var/log/pictures-sync.log"
CREDS_FILE="/etc/cifs.creds"
CIFS_SHARE="//vnafs/Pictures"
MAX_MOUNT_RETRIES=3
MOUNT_RETRY_DELAY=5   # seconds between mount attempts
# ──────────────────────────────────────────────────────────────────────────────

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    printf '%s [%s] [PID:%s] %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$$" "$*" \
        | tee -a "$LOG_FILE"
}
info()  { log INFO  "$@"; }
warn()  { log WARN  "$@"; }
error() { log ERROR "$@"; }
die()   { error "$@"; exit 1; }
# ──────────────────────────────────────────────────────────────────────────────

# ── Cleanup / Trap ─────────────────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    rm -rf "$WORK_DIR"
    rm -rf  "$LOCK_FILE"
    [[ $exit_code -eq 0 ]] && info "Run complete (exit 0)" \
                           || warn "Run finished with exit code $exit_code"
}
trap cleanup EXIT
trap 'die "Caught signal — aborting"' INT TERM
# ──────────────────────────────────────────────────────────────────────────────

# ── Exclusive lock ─────────────────────────────────────────────────────────────
acquire_lock() {
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        local owner
        owner=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "unknown")
        die "Another instance is running (PID $owner). Exiting."
    fi
    echo "$$" > "$LOCK_FILE/pid"
    info "Lock acquired"
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Credentials ───────────────────────────────────────────────────────────────
write_credentials() {
    local secrets_dir="/run/secrets"
    [[ -r "$secrets_dir/domain"         ]] || die "Missing secret: domain"
    [[ -r "$secrets_dir/domainusername" ]] || die "Missing secret: domainusername"
    [[ -r "$secrets_dir/domainpassword" ]] || die "Missing secret: domainpassword"

    install -m 0600 /dev/null "$CREDS_FILE"
    {
        printf 'domain=%s\n'   "$(cat "$secrets_dir/domain")"
        printf 'username=%s\n' "$(cat "$secrets_dir/domainusername")"
        printf 'password=%s\n' "$(cat "$secrets_dir/domainpassword")"
    } > "$CREDS_FILE"
    info "Credentials written to $CREDS_FILE"
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Mount management ──────────────────────────────────────────────────────────
is_mounted() {
    findmnt -t cifs "$MOUNT_POINT" >/dev/null 2>&1
}

attempt_mount() {
    mount -t cifs \
          -o credentials="$CREDS_FILE",file_mode=0664,dir_mode=0775 \
          "$CIFS_SHARE" "$MOUNT_POINT"
}

ensure_mount() {
    if is_mounted; then
        info "CIFS already mounted at $MOUNT_POINT"
        return 0
    fi

    warn "CIFS not mounted — attempting recovery"
    mkdir -p "$MOUNT_POINT"

    local attempt
    for attempt in $(seq 1 "$MAX_MOUNT_RETRIES"); do
        info "Mount attempt $attempt / $MAX_MOUNT_RETRIES"
        if attempt_mount; then
            info "Mount succeeded on attempt $attempt"
            return 0
        fi
        warn "Mount attempt $attempt failed"
        sleep "$MOUNT_RETRY_DELAY"
    done

    die "All $MAX_MOUNT_RETRIES mount attempts failed — aborting to prevent data loss"
}

verify_mount_writable() {
    local probe="$MOUNT_POINT/.probe-$$"
    if touch "$probe" 2>/dev/null; then
        rm -f "$probe"
        info "Mount is writable"
    else
        die "Mount at $MOUNT_POINT is not writable"
    fi
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Queue management ──────────────────────────────────────────────────────────
init_queue() {
    mkdir -p \
        "$QUEUE_DIR" \
        "$QUEUE_DIR/.done" \
        "$QUEUE_DIR/.failed"
    info "Queue directories ready at $QUEUE_DIR"
}

# Atomically enqueue a file: hard-link into QUEUE_DIR (same filesystem).
# Falls back to copy if hard-link fails (cross-device).
enqueue_file() {
    local src="$1"
    local name
    name=$(basename "$src")
    local dest="$QUEUE_DIR/$name"

    # Guard against name collision from a previous partial run
    if [[ -e "$dest" ]]; then
        warn "Queue already contains '$name' — skipping re-enqueue (left from prior run?)"
        return 0
    fi

    if ln "$src" "$dest" 2>/dev/null; then
        info "Enqueued (hard-link): $name"
    else
        cp -p "$src" "$dest"
        info "Enqueued (copy): $name"
    fi
}

mark_done() {
    local queued="$1"
    local name
    name=$(basename "$queued")
    mv -f "$queued" "$QUEUE_DIR/.done/$name"
    info "Marked done: $name"
}

mark_failed() {
    local queued="$1"
    local name
    name=$(basename "$queued")
    mv -f "$queued" "$QUEUE_DIR/.failed/$name"
    error "Marked failed: $name"
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Conversion ────────────────────────────────────────────────────────────────
# Convert a JPG to PDF inside WORK_DIR; return the path of the produced file.
convert_jpg_to_pdf() {
    local src="$1"          # absolute path to the queued JPG
    local name
    name=$(basename "$src")
    local stem="${name%.*}"
    local out="$WORK_DIR/${stem}.pdf"

    if ! mogrify -format pdf -write "$out" "$src" 2>>"$LOG_FILE"; then
        error "mogrify failed for $name"
        return 1
    fi

    echo "$out"  # caller captures this
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Atomic write to mount ─────────────────────────────────────────────────────
# Write a file to the mount using a .tmp staging name, then rename.
# If the mount disappears mid-write the rename will fail and we abort.
atomic_copy_to_mount() {
    local src="$1"
    local dest_name
    dest_name=$(basename "$src")
    local staging="$MOUNT_POINT/.$dest_name.tmp"
    local final="$MOUNT_POINT/$dest_name"

    cp -p "$src" "$staging" \
        || { error "cp to staging failed for $dest_name"; return 1; }

    mv -f "$staging" "$final" \
        || { rm -f "$staging"; error "mv staging→final failed for $dest_name"; return 1; }

    info "Atomically written to mount: $dest_name"
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Process one queued item ───────────────────────────────────────────────────
process_item() {
    local queued="$1"
    local name
    name=$(basename "$queued")
    info "Processing: $name"

    local to_upload

    # Check if this is a JPG that needs conversion
    if [[ "${name,,}" =~ \.(jpg|jpeg)$ ]]; then
        local pdf_path
        if ! pdf_path=$(convert_jpg_to_pdf "$queued"); then
            mark_failed "$queued"
            return 1
        fi
        to_upload="$pdf_path"
    else
        # Non-JPG: copy to work dir so the upload path is always in WORK_DIR
        cp -p "$queued" "$WORK_DIR/$name"
        to_upload="$WORK_DIR/$name"
    fi

    # Verify the mount is still alive before writing
    if ! is_mounted; then
        warn "Mount lost before writing $name — re-mounting"
        ensure_mount
        verify_mount_writable
    fi

    if ! atomic_copy_to_mount "$to_upload"; then
        mark_failed "$queued"
        return 1
    fi

    # Only delete the source AFTER confirmed write to mount
    mark_done "$queued"

    # Remove the original from SOURCE (safe: queued copy still exists in .done/)
    local original="$SOURCE_DIR/$name"
    if [[ -e "$original" ]]; then
        rm -f "$original"
        info "Removed source: $original"
    fi
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Stale .tmp cleanup ────────────────────────────────────────────────────────
# Remove any staging temps left by a previous crashed run (older than 1 hour)
cleanup_stale_temps() {
    find "$MOUNT_POINT" -maxdepth 1 -name '.*.tmp' -mmin +60 -print \
        | while IFS= read -r stale; do
            warn "Removing stale temp: $stale"
            rm -f "$stale"
        done
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    info "===== sync-pictures starting ====="

    acquire_lock
    write_credentials
    init_queue
    mkdir -p "$WORK_DIR"

    ensure_mount
    verify_mount_writable
    cleanup_stale_temps

    # ── Phase 1: Enqueue everything from SOURCE ──────────────────────────────
    info "Phase 1: enqueueing source files"
    local enqueued=0
    while IFS= read -r -d '' src_file; do
        enqueue_file "$src_file"
        (( enqueued++ )) || true
    done < <(find "$SOURCE_DIR" -maxdepth 1 -mindepth 1 \
                  -not -type d -print0)

    info "Enqueued $enqueued file(s)"

    # ── Phase 2: Process the queue ───────────────────────────────────────────
    info "Phase 2: processing queue"
    local ok=0 fail=0
    while IFS= read -r -d '' queued_file; do
        if process_item "$queued_file"; then
            (( ok++   )) || true
        else
            (( fail++ )) || true
        fi
    done < <(find "$QUEUE_DIR" -maxdepth 1 -mindepth 1 \
                  -not -type d -print0)

    info "Queue run complete — ok=$ok failed=$fail"

    if (( fail > 0 )); then
        warn "$fail file(s) failed — inspect $QUEUE_DIR/.failed/"
        exit 2
    fi
}

main "$@"
