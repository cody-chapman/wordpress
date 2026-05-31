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

# Atomically enqueue a file, mirroring the relative path under QUEUE_DIR so
# directory structure is preserved all the way to the mount.
# e.g. /home/vnaftp/client/2024/photo.jpg → $QUEUE_DIR/client/2024/photo.jpg
enqueue_file() {
    local src="$1"
    local rel="${src#"$SOURCE_DIR"/}"   # relative path from SOURCE_DIR
    local dest="$QUEUE_DIR/$rel"
    local dest_dir
    dest_dir=$(dirname "$dest")

    if [[ -e "$dest" ]]; then
        warn "Queue already contains '$rel' — skipping re-enqueue (left from prior run?)"
        return 0
    fi

    mkdir -p "$dest_dir"

    if ln "$src" "$dest" 2>/dev/null; then
        info "Enqueued (hard-link): $rel"
    else
        cp -p "$src" "$dest"
        info "Enqueued (copy): $rel"
    fi
}

mark_done() {
    local queued="$1"
    local rel="${queued#"$QUEUE_DIR"/}"
    local dest="$QUEUE_DIR/.done/$rel"
    mkdir -p "$(dirname "$dest")"
    mv -f "$queued" "$dest"
    info "Marked done: $rel"
}

mark_failed() {
    local queued="$1"
    local rel="${queued#"$QUEUE_DIR"/}"
    local dest="$QUEUE_DIR/.failed/$rel"
    mkdir -p "$(dirname "$dest")"
    mv -f "$queued" "$dest"
    error "Marked failed: $rel"
}
# ──────────────────────────────────────────────────────────────────────────────


# ── Atomic write to mount ─────────────────────────────────────────────────────
# Write src to $MOUNT_POINT/<dest_rel>, preserving subdirectory structure.
# Uses a .tmp staging name in the same directory, then renames atomically.
atomic_copy_to_mount() {
    local src="$1"
    local dest_rel="$2"          # e.g. "client/2024/photo.pdf"
    local dest_name
    dest_name=$(basename "$dest_rel")
    local dest_dir="$MOUNT_POINT/$(dirname "$dest_rel")"
    local staging="$dest_dir/.$dest_name.tmp"
    local final="$dest_dir/$dest_name"

    mkdir -p "$dest_dir"         || { error "mkdir failed for $dest_dir"; return 1; }

    cp -p "$src" "$staging"         || { error "cp to staging failed for $dest_rel"; return 1; }

    mv -f "$staging" "$final"         || { rm -f "$staging"; error "mv staging→final failed for $dest_rel"; return 1; }

    info "Atomically written to mount: $dest_rel"
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Process one queued item ───────────────────────────────────────────────────
process_item() {
    local queued="$1"
    # Relative path beneath QUEUE_DIR — mirrors SOURCE_DIR structure
    local rel="${queued#"$QUEUE_DIR"/}"
    local name
    name=$(basename "$rel")
    local rel_dir
    rel_dir=$(dirname "$rel")   # e.g. "client/2024" or "."
    info "Processing: $rel"

    local to_upload
    local dest_rel   # path relative to MOUNT_POINT

    if [[ "${name,,}" =~ \.(jpg|jpeg)$ ]]; then
        local stem="${name%.*}"
        local work_subdir="$WORK_DIR/$rel_dir"
        mkdir -p "$work_subdir"
        local pdf_path="$work_subdir/${stem}.pdf"

        if ! mogrify -format pdf -write "$pdf_path" "$queued" 2>>"$LOG_FILE"; then
            error "mogrify failed for $rel"
            mark_failed "$queued"
            return 1
        fi
        to_upload="$pdf_path"
        dest_rel="$rel_dir/${stem}.pdf"
    else
        local work_subdir="$WORK_DIR/$rel_dir"
        mkdir -p "$work_subdir"
        cp -p "$queued" "$work_subdir/$name"
        to_upload="$work_subdir/$name"
        dest_rel="$rel"
    fi

    # Verify the mount is still alive before writing
    if ! is_mounted; then
        warn "Mount lost before writing $rel — re-mounting"
        ensure_mount
        verify_mount_writable
    fi

    if ! atomic_copy_to_mount "$to_upload" "$dest_rel"; then
        mark_failed "$queued"
        return 1
    fi

    # Only delete the source AFTER confirmed write to mount
    mark_done "$queued"

    # Remove the original from SOURCE (safe: queued copy still exists in .done/)
    local original="$SOURCE_DIR/$rel"
    if [[ -e "$original" ]]; then
        rm -f "$original"
        info "Removed source: $original"
    fi
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Stale .tmp cleanup ────────────────────────────────────────────────────────
# Remove any staging temps left by a previous crashed run (older than 1 hour)
cleanup_stale_temps() {
    find "$MOUNT_POINT" -name '.*.tmp' -mmin +60 -print \
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
        enqueued=$(( enqueued + 1 ))
    done < <(find "$SOURCE_DIR" -mindepth 2 \
                  -not -type d \
                  -not -name '.*' \
                  -print0)

    info "Enqueued $enqueued file(s)"

    # ── Phase 2: Process the queue ───────────────────────────────────────────
    # Recurse into all subdirs of QUEUE_DIR; skip .done and .failed trees.
    info "Phase 2: processing queue"
    local ok=0 fail=0
    while IFS= read -r -d '' queued_file; do
        if process_item "$queued_file"; then
            ok=$(( ok + 1 ))
        else
            fail=$(( fail + 1 ))
        fi
    done < <(find "$QUEUE_DIR" \
                  -not \( -path "$QUEUE_DIR/.done"   -prune \) \
                  -not \( -path "$QUEUE_DIR/.failed" -prune \) \
                  -mindepth 1 \
                  -not -type d \
                  -not -name '.*' \
                  -print0)

    info "Queue run complete — ok=$ok failed=$fail"

    if (( fail > 0 )); then
        warn "$fail file(s) failed — inspect $QUEUE_DIR/.failed/"
        exit 2
    fi
}

main "$@"
