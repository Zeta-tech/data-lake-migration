#!/usr/bin/env bash
# Upload DATA_LAKE week folders to GCS using all_paths.csv mappings.
#
# Only rows with a non-empty expected_path are uploaded:
#   <DATA_LAKE>/<local_path>/  ->  gs://<bucket>/<prefix>/<expected_path>/
#
# Memory note:
#   Each `gcloud storage rsync` already parallelizes files internally.
#   Running many folder jobs × high gcloud process/thread counts will
#   exhaust RAM. Defaults keep total transfer workers modest.
#
# Examples:
#   ./upload_data_lake_to_gcs.sh --dry-run
#   ./upload_data_lake_to_gcs.sh --jobs 4
#   ./upload_data_lake_to_gcs.sh --background --jobs 4
#   ./upload_data_lake_to_gcs.sh --retry-failed data_lake_report/gcs_upload/failed_YYYYMMDD_HHMMSS.tsv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── defaults (conservative: upload-only, low RAM) ───────────────────────────
CSV="${SCRIPT_DIR}/data_lake_report/all_paths.csv"
BASE="/media/vindoo2/vindoo_disk/DATA_LAKE"
CREDENTIALS="${SCRIPT_DIR}/customer-media-writer-key.json"
BUCKET="vindoo-customer-media-prod"
PREFIX="data-lake"
JOBS=4                    # parallel folder uploads
GCLOUD_PROCESSES=1        # gcloud workers per folder
GCLOUD_THREADS=4          # threads per gcloud process
PROGRESS_EVERY=15         # seconds between progress snapshots in the main log (0=off)
DRY_RUN=0
BACKGROUND=0
LIMIT=0
LOG_DIR="${SCRIPT_DIR}/data_lake_report/gcs_upload"
SKIP_MISSING=1
RETRY_FAILED=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Upload DATA_LAKE folders to GCS, using expected_path from all_paths.csv.
Rows with blank expected_path are skipped.

Defaults are intentionally conservative to avoid RAM exhaustion:
  folder jobs × gcloud_processes × gcloud_threads  ≈  transfer workers
  (default 4 × 1 × 4 = 16)

Options:
  --csv PATH              Mapping CSV (default: ${CSV})
  --base PATH             Local DATA_LAKE root (default: ${BASE})
  --credentials PATH      Service-account JSON key (default: ${CREDENTIALS})
  --bucket NAME           GCS bucket without gs:// (default: ${BUCKET})
  --prefix PATH           Object prefix inside the bucket (default: ${PREFIX})
  --jobs N                Parallel folder uploads (default: ${JOBS})
  --gcloud-processes N    gcloud storage/process_count per folder (default: ${GCLOUD_PROCESSES})
  --gcloud-threads N      gcloud storage/thread_count per folder (default: ${GCLOUD_THREADS})
  --progress-every N      Progress snapshot every N seconds in main log (default: ${PROGRESS_EVERY}; 0=off)
  --limit N               Upload only the first N mapped folders (0 = all)
  --retry-failed FILE     Re-upload only rows from a previous failed_*.tsv
  --log-dir PATH          Directory for logs / pid / manifests (default: ${LOG_DIR})
  --dry-run               Print the upload plan only; do not touch GCS
  --background            Re-launch under nohup and return immediately
  --fail-missing          Fail (instead of skip) when a local folder is missing
  -h, --help              Show this help

Live progress (while a run is active):
  ./watch_gcs_upload_progress.sh
  watch -n 5 ./watch_gcs_upload_progress.sh --once

Recommended:
  ./$(basename "$0") --jobs 4
  ./$(basename "$0") --background --jobs 4
  ./$(basename "$0") --retry-failed data_lake_report/gcs_upload/failed_YYYYMMDD_HHMMSS.tsv
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# ── args ────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv) CSV="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --credentials) CREDENTIALS="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --gcloud-processes) GCLOUD_PROCESSES="$2"; shift 2 ;;
    --gcloud-threads) GCLOUD_THREADS="$2"; shift 2 ;;
    --progress-every) PROGRESS_EVERY="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --retry-failed) RETRY_FAILED="$2"; shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --background) BACKGROUND=1; shift ;;
    --fail-missing) SKIP_MISSING=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Strip / normalize
BASE="${BASE%/}"
PREFIX="${PREFIX#/}"
PREFIX="${PREFIX%/}"
BUCKET="${BUCKET#gs://}"
BUCKET="${BUCKET%/}"

[[ -f "$CSV" ]] || die "CSV not found: $CSV"
[[ -d "$BASE" ]] || die "DATA_LAKE base not found: $BASE"
[[ -f "$CREDENTIALS" ]] || die "credentials not found: $CREDENTIALS"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
[[ "$GCLOUD_PROCESSES" =~ ^[1-9][0-9]*$ ]] || die "--gcloud-processes must be a positive integer"
[[ "$GCLOUD_THREADS" =~ ^[1-9][0-9]*$ ]] || die "--gcloud-threads must be a positive integer"
[[ "$PROGRESS_EVERY" =~ ^[0-9]+$ ]] || die "--progress-every must be a non-negative integer"
[[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit must be a non-negative integer"
if [[ -n "$RETRY_FAILED" && ! -f "$RETRY_FAILED" ]]; then
  die "retry-failed file not found: $RETRY_FAILED"
fi

# Soft warning if the user asks for a RAM-heavy combo
TOTAL_WORKERS=$((JOBS * GCLOUD_PROCESSES * GCLOUD_THREADS))
if [[ "$TOTAL_WORKERS" -gt 32 && "$DRY_RUN" -eq 0 ]]; then
  printf 'WARNING: ~%s concurrent transfer workers (jobs=%s × processes=%s × threads=%s). This can exhaust RAM.\n' \
    "$TOTAL_WORKERS" "$JOBS" "$GCLOUD_PROCESSES" "$GCLOUD_THREADS" >&2
fi

mkdir -p "$LOG_DIR" "$LOG_DIR/jobs"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
MAIN_LOG="${LOG_DIR}/upload_${RUN_ID}.log"
PLAN_FILE="${LOG_DIR}/plan_${RUN_ID}.tsv"
READY_FILE="${LOG_DIR}/ready_${RUN_ID}.tsv"
PID_FILE="${LOG_DIR}/upload.pid"
LATEST_LOG="${LOG_DIR}/latest.log"
RESULTS_OK="${LOG_DIR}/success_${RUN_ID}.tsv"
RESULTS_FAIL="${LOG_DIR}/failed_${RUN_ID}.tsv"
RESULTS_LOCK="${LOG_DIR}/results_${RUN_ID}.lock"

log() {
  local ts
  ts="$(date -Is)"
  # When launched via --background, stdout is already redirected to MAIN_LOG.
  if [[ "${UPLOAD_LOG_TO_STDOUT_ONLY:-0}" -eq 1 ]]; then
    printf '[%s] %s\n' "$ts" "$*"
  else
    printf '[%s] %s\n' "$ts" "$*" | tee -a "$MAIN_LOG" >&2
  fi
}

# ── background wrapper ──────────────────────────────────────────────────────
if [[ "$BACKGROUND" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    die "--background cannot be combined with --dry-run"
  fi
  reexec=(
    "$0"
    --csv "$CSV"
    --base "$BASE"
    --credentials "$CREDENTIALS"
    --bucket "$BUCKET"
    --prefix "$PREFIX"
    --jobs "$JOBS"
    --gcloud-processes "$GCLOUD_PROCESSES"
    --gcloud-threads "$GCLOUD_THREADS"
    --progress-every "$PROGRESS_EVERY"
    --limit "$LIMIT"
    --log-dir "$LOG_DIR"
  )
  [[ "$SKIP_MISSING" -eq 0 ]] && reexec+=(--fail-missing)
  [[ -n "$RETRY_FAILED" ]] && reexec+=(--retry-failed "$RETRY_FAILED")

  : >"$MAIN_LOG"
  ln -sfn "$(basename "$MAIN_LOG")" "$LATEST_LOG"
  # Child logs via tee; do NOT also redirect to MAIN_LOG (avoids duplicate lines).
  UPLOAD_LOG_TO_STDOUT_ONLY=0 nohup env UPLOAD_LOG_TO_STDOUT_ONLY=1 \
    "${reexec[@]}" >>"$MAIN_LOG" 2>&1 &
  bg_pid=$!
  echo "$bg_pid" >"$PID_FILE"
  echo "Started background upload pid=${bg_pid}"
  echo "  log:    $MAIN_LOG"
  echo "  follow: tail -f $MAIN_LOG"
  echo "  pid:    $PID_FILE"
  exit 0
fi

: >"$MAIN_LOG"
ln -sfn "$(basename "$MAIN_LOG")" "$LATEST_LOG"
: >"$RESULTS_OK"
: >"$RESULTS_FAIL"
: >"$RESULTS_LOCK"

log "=== DATA_LAKE → GCS upload ==="
log "csv=$CSV"
log "base=$BASE"
log "bucket=gs://${BUCKET}/${PREFIX}/"
log "credentials=$CREDENTIALS"
log "jobs=$JOBS gcloud_processes=$GCLOUD_PROCESSES gcloud_threads=$GCLOUD_THREADS (~${TOTAL_WORKERS} workers)"
log "dry_run=$DRY_RUN limit=$LIMIT"
log "log=$MAIN_LOG"

# Auth for this process tree only (does not mutate user gcloud config)
export GOOGLE_APPLICATION_CREDENTIALS="$CREDENTIALS"
export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$CREDENTIALS"
export CLOUDSDK_CORE_DISABLE_PROMPTS=1
CLOUDSDK_CORE_PROJECT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["project_id"])' "$CREDENTIALS")"
export CLOUDSDK_CORE_PROJECT
log "project=$CLOUDSDK_CORE_PROJECT"

# Cap gcloud internal parallelism (critical for RAM).
# Each folder job inherits these; keep them low when --jobs > 1.
export CLOUDSDK_STORAGE_PROCESS_COUNT="$GCLOUD_PROCESSES"
export CLOUDSDK_STORAGE_THREAD_COUNT="$GCLOUD_THREADS"
# Composite uploads spawn extra temp objects/processes — disable for stability.
export CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED=False

# ── build plan ──────────────────────────────────────────────────────────────
if [[ -n "$RETRY_FAILED" ]]; then
  log "retry mode from $RETRY_FAILED"
  PLAN_SUMMARY="$(
  python3 - "$RETRY_FAILED" "$BASE" "$PLAN_FILE" <<'PY'
import sys
from pathlib import Path

failed_file, base_s, plan_file = sys.argv[1:4]
base = Path(base_s)
rows = []
with open(failed_file, encoding="utf-8") as f:
    header = f.readline()
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 2:
            continue
        local, expected = parts[0].strip("/"), parts[1].strip("/")
        if not local or not expected:
            continue
        src = base / local
        status = "ok" if src.is_dir() else "missing_local"
        rows.append((local, expected, status, str(src)))

with open(plan_file, "w", encoding="utf-8") as out:
    out.write("local_path\texpected_path\tstatus\tlocal_abs\n")
    for r in rows:
        out.write("\t".join(r) + "\n")

missing = sum(1 for r in rows if r[2] == "missing_local")
ready = sum(1 for r in rows if r[2] == "ok")
print(f"kept={len(rows)} ready={ready} missing_local={missing} skipped_empty=0")
PY
  )"
else
  PLAN_SUMMARY="$(
  python3 - "$CSV" "$BASE" "$PLAN_FILE" "$LIMIT" <<'PY'
import csv
import sys
from pathlib import Path

csv_path, base_s, plan_file, limit_s = sys.argv[1:5]
limit = int(limit_s)
base = Path(base_s)

skipped_empty = 0
rows = []
with open(csv_path, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    fields = reader.fieldnames or []
    if "local_path" not in fields or "expected_path" not in fields:
        raise SystemExit(f"CSV must have local_path,expected_path columns; got {fields}")
    for row in reader:
        local = (row.get("local_path") or "").strip().strip("/")
        expected = (row.get("expected_path") or "").strip().strip("/")
        if not expected:
            skipped_empty += 1
            continue
        if not local:
            continue
        src = base / local
        status = "ok" if src.is_dir() else "missing_local"
        rows.append((local, expected, status, str(src)))
        if limit and len(rows) >= limit:
            break

with open(plan_file, "w", encoding="utf-8") as out:
    out.write("local_path\texpected_path\tstatus\tlocal_abs\n")
    for r in rows:
        out.write("\t".join(r) + "\n")

missing = sum(1 for r in rows if r[2] == "missing_local")
ready = sum(1 for r in rows if r[2] == "ok")
print(
    f"kept={len(rows)} ready={ready} missing_local={missing} "
    f"skipped_empty={skipped_empty}"
)
PY
  )"
fi
log "plan: $PLAN_SUMMARY"
log "plan_file=$PLAN_FILE"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN plan (local_path -> gs://${BUCKET}/${PREFIX}/expected_path/):"
  TOTAL_PLAN=$(($(wc -l <"$PLAN_FILE") - 1))
  set +o pipefail
  awk -F'\t' -v bucket="$BUCKET" -v prefix="$PREFIX" 'NR==1{next} {
    printf "  %s  ->  gs://%s/%s/%s/  [%s]\n", $1, bucket, prefix, $2, $3
  }' "$PLAN_FILE" | head -n 50 | tee -a "$MAIN_LOG" >&2
  set -o pipefail
  if [[ "$TOTAL_PLAN" -gt 50 ]]; then
    log "... ($((TOTAL_PLAN - 50)) more rows; full plan in $PLAN_FILE)"
  fi
  log "DRY-RUN complete. No uploads performed. total_mapped=$TOTAL_PLAN ~workers=$TOTAL_WORKERS"
  exit 0
fi

if [[ "$SKIP_MISSING" -eq 0 ]]; then
  if awk -F'\t' 'NR>1 && $3=="missing_local"{exit 0} END{exit 1}' "$PLAN_FILE"; then
    die "one or more local folders are missing (see $PLAN_FILE). Re-run without --fail-missing to skip them."
  fi
fi

awk -F'\t' 'NR==1{next} $3=="ok"{print $1"\t"$2"\t"$4}' "$PLAN_FILE" >"$READY_FILE"
READY_COUNT="$(wc -l <"$READY_FILE" | tr -d ' ')"
log "ready_to_upload=$READY_COUNT parallel_jobs=$JOBS"

if [[ "$READY_COUNT" -eq 0 ]]; then
  die "nothing to upload"
fi

# ── upload worker ───────────────────────────────────────────────────────────
upload_one() {
  local local_rel="$1"
  local expected="$2"
  local local_abs="$3"
  local dest="gs://${BUCKET}/${PREFIX}/${expected}"
  local job_log="${LOG_DIR}/jobs/${local_rel//\//__}.log"
  local start end rc elapsed

  mkdir -p "$(dirname "$job_log")"
  start="$(date +%s)"
  {
    echo "=== upload ==="
    echo "start=$(date -Is)"
    echo "src=${local_abs}/"
    echo "dst=${dest}/"
    echo "gcloud_processes=${CLOUDSDK_STORAGE_PROCESS_COUNT}"
    echo "gcloud_threads=${CLOUDSDK_STORAGE_THREAD_COUNT}"
  } >"$job_log"

  echo "START ${local_rel} -> ${dest}/"

  # Sync folder contents into the expected GCS prefix (no extra nesting).
  if gcloud storage rsync --recursive --continue-on-error \
      "${local_abs}" "${dest}" >>"$job_log" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  end="$(date +%s)"
  elapsed=$((end - start))
  # Capture gcloud's own average throughput line if present.
  local avg_tp
  avg_tp="$(grep -E 'Average throughput:' "$job_log" | tail -1 | sed 's/^.*Average throughput: //' || true)"
  echo "end=$(date -Is) duration_s=${elapsed} exit=${rc}" >>"$job_log"

  # Serialize result writes across parallel jobs.
  if [[ "$rc" -eq 0 ]]; then
    flock "$RESULTS_LOCK" bash -c \
      "printf '%s\t%s\t%s\t%d\n' \"\$1\" \"\$2\" \"\$3\" \"\$4\" >>\"\$5\"" \
      _ "$local_rel" "$expected" "$dest" "$elapsed" "$RESULTS_OK"
    if [[ -n "$avg_tp" ]]; then
      echo "OK   ${local_rel} -> ${dest}/  (${elapsed}s, ${avg_tp})"
    else
      echo "OK   ${local_rel} -> ${dest}/  (${elapsed}s)"
    fi
  else
    flock "$RESULTS_LOCK" bash -c \
      "printf '%s\t%s\t%s\t%d\t%s\n' \"\$1\" \"\$2\" \"\$3\" \"\$4\" \"\$5\" >>\"\$6\"" \
      _ "$local_rel" "$expected" "$dest" "$elapsed" "$job_log" "$RESULTS_FAIL"
    echo "FAIL ${local_rel} -> ${dest}/  (rc=${rc}, log=${job_log})"
  fi
  return "$rc"
}
export -f upload_one
export BUCKET PREFIX LOG_DIR RESULTS_OK RESULTS_FAIL RESULTS_LOCK
export CLOUDSDK_STORAGE_PROCESS_COUNT CLOUDSDK_STORAGE_THREAD_COUNT
export CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED
export GOOGLE_APPLICATION_CREDENTIALS CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE
export CLOUDSDK_CORE_DISABLE_PROMPTS CLOUDSDK_CORE_PROJECT

# Periodic progress snapshots into the main log (and stdout).
progress_loop() {
  local ready_count="$1"
  local every="$2"
  local watch_script="${SCRIPT_DIR}/watch_gcs_upload_progress.sh"
  [[ "$every" -gt 0 ]] || return 0
  [[ -x "$watch_script" ]] || chmod +x "$watch_script" 2>/dev/null || true
  while true; do
    sleep "$every"
    {
      echo
      echo "[progress $(date -Is)] folders done so far: $(wc -l <"$RESULTS_OK" | tr -d ' ')/${ready_count} ok, $(wc -l <"$RESULTS_FAIL" | tr -d ' ') fail"
      if [[ -x "$watch_script" ]]; then
        "$watch_script" --log-dir "$LOG_DIR" --once 2>/dev/null || true
      fi
      echo
    } | tee -a "$MAIN_LOG" >&2
  done
}

log "upload starting..."
log "tip: live view -> ${SCRIPT_DIR}/watch_gcs_upload_progress.sh"
START_ALL="$(date +%s)"

PROGRESS_PID=""
if [[ "$PROGRESS_EVERY" -gt 0 ]]; then
  # Run outside job-control accounting used for upload slots.
  progress_loop "$READY_COUNT" "$PROGRESS_EVERY" &
  PROGRESS_PID=$!
  disown "$PROGRESS_PID" 2>/dev/null || true
fi

set +e
upload_pids=()
while IFS=$'\t' read -r local_rel expected local_abs; do
  # Reap finished upload workers and enforce --jobs limit.
  while true; do
    alive=()
    for pid in "${upload_pids[@]:-}"; do
      if kill -0 "$pid" 2>/dev/null; then
        alive+=("$pid")
      else
        wait "$pid" 2>/dev/null || true
      fi
    done
    upload_pids=("${alive[@]:-}")
    if [[ "${#upload_pids[@]}" -lt "$JOBS" ]]; then
      break
    fi
    sleep 0.5
  done
  upload_one "$local_rel" "$expected" "$local_abs" &
  upload_pids+=($!)
done <"$READY_FILE"

for pid in "${upload_pids[@]:-}"; do
  wait "$pid" 2>/dev/null || true
done
set -e

if [[ -n "$PROGRESS_PID" ]]; then
  kill "$PROGRESS_PID" 2>/dev/null || true
  wait "$PROGRESS_PID" 2>/dev/null || true
fi

END_ALL="$(date +%s)"
OK_COUNT="$(wc -l <"$RESULTS_OK" | tr -d ' ')"
FAIL_COUNT="$(wc -l <"$RESULTS_FAIL" | tr -d ' ')"

log "=== finished in $((END_ALL - START_ALL))s ==="
log "success=$OK_COUNT failed=$FAIL_COUNT ready=$READY_COUNT"
log "success_list=$RESULTS_OK"
log "failed_list=$RESULTS_FAIL"
log "per-folder logs: $LOG_DIR/jobs/"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  log "Some uploads failed. Retry with:"
  log "  $0 --retry-failed $RESULTS_FAIL --jobs $JOBS"
  exit 1
fi

log "All uploads completed successfully."
exit 0
