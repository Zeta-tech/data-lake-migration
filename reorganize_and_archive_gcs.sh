#!/usr/bin/env bash
# Reorganize GCS week folders into media/ + analysis/, verify vs local (MD5),
# then move from STANDARD bucket to ARCHIVE bucket.
#
# Recommended order (this script's default pipeline):
#   1) reorganize in STANDARD   (cheap renames within bucket)
#   2) verify MD5 vs local      (metadata on STANDARD — fast, no Archive retrieval)
#   3) archive with guarantee:
#        rsync copy STANDARD → ARCHIVE
#        compare LOCAL ↔ ARCHIVE (name+size+MD5; local paths mapped to media/|analysis/)
#        delete STANDARD only if local↔archive PASSes
#
# Why not Archive-first?
#   - Reading md5Hash from object *metadata* on Archive does NOT incur data-retrieval
#     fees (it's a Class B metadata op). So verify-on-Archive is possible.
#   - But rewriting/renaming objects inside Archive (reorganize) is wasteful:
#     more Class A ops + temporary copies. Better to shape the tree on STANDARD,
#     prove it matches local, then move once to Archive.
#
# Classification under each expected_path (week folder):
#   media/     → top-level image/video files (extension match, no subdirectory)
#   analysis/  → everything else (nested dirs like detections/summary, CSVs, etc.)
#                relative paths preserved under analysis/
#
# Examples:
#   ./reorganize_and_archive_gcs.sh --dry-run --limit 2
#   ./reorganize_and_archive_gcs.sh --jobs 2 --phases reorganize,verify
#   ./reorganize_and_archive_gcs.sh --background --jobs 2
#   ./reorganize_and_archive_gcs.sh --phases archive --jobs 2   # only move already done
#   ./reorganize_and_archive_gcs.sh --phases reorganize --start-row 25 --jobs 2
#   ./reorganize_and_archive_gcs.sh --gcs-only --phases reorganize,archive --start-row 55 --background --jobs 6
#   ./reorganize_and_archive_gcs.sh --gcs-only --skip-success --start-row 55 --reorg-backend auto --jobs 2
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CSV="${SCRIPT_DIR}/data_lake_report/all_paths.csv"
BASE="/media/vindoo2/vindoo_disk/DATA_LAKE"
CREDENTIALS="${SCRIPT_DIR}/customer-media-writer-key.json"
SRC_BUCKET="vindoo-customer-media-prod"
DST_BUCKET="vindoo-customer-media-archive-prod"
PREFIX="data-lake"
JOBS=4
GCLOUD_PROCESSES=1
GCLOUD_THREADS=8
REORG_PARALLEL=16
REORG_BACKEND=auto   # auto | gcloud | api — auto: prefix folder mv + JSON API for root files
REORG_API_THREADS=16 # parallel HTTP moves per chunk (api/auto file moves)
DRY_RUN=0
BACKGROUND=0
LIMIT=0
SKIP=0
LOG_DIR="${SCRIPT_DIR}/data_lake_report/gcs_finalize"
PHASES="reorganize,verify,archive"   # comma-separated
SKIP_MISSING=1
GCS_ONLY=0
SKIP_SUCCESS=0

# Top-level media extensions (lowercase, with dot)
MEDIA_EXT_REGEX='\.(jpg|jpeg|png|tif|tiff|bmp|webp|heic|mp4|mov|avi|mkv|m4v|wmv|mpg|mpeg)$'

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

For each all_paths.csv row with a non-empty expected_path:
  1) Reorganize gs://SRC/PREFIX/expected_path/ into media/ + analysis/
  2) Verify local_path contents match GCS (count + size + MD5)
  3) Move the reorganized tree to gs://DST/PREFIX/expected_path/

Options:
  --csv PATH           Mapping CSV (default: ${CSV})
  --base PATH          Local DATA_LAKE root (default: ${BASE})
  --credentials PATH   SA JSON key (default: ${CREDENTIALS})
  --src-bucket NAME    STANDARD source bucket (default: ${SRC_BUCKET})
  --dst-bucket NAME    ARCHIVE destination bucket (default: ${DST_BUCKET})
  --prefix PATH        Object prefix (default: ${PREFIX})
  --jobs N             Parallel week folders (default: ${JOBS})
  --gcloud-processes N gcloud storage process_count per rsync/mv batch (default: ${GCLOUD_PROCESSES})
  --gcloud-threads N   gcloud storage thread_count per process (default: ${GCLOUD_THREADS})
  --reorg-parallel N   Parallel workers for in-folder reorganize mv (default: ${REORG_PARALLEL})
  --reorg-backend MODE reorganize moves: auto (default), gcloud (legacy per-file), api
  --reorg-api-threads N  Concurrent JSON API moves per chunk (default: ${REORG_API_THREADS})
  --phases LIST        Subset of: reorganize,verify,archive (default: ${PHASES})
  --skip-success       Skip expected_path already listed OK in ${LOG_DIR}/success_*.tsv
  --limit N            Process only first N mapped rows after --skip (0=all)
  --skip N             Skip first N mapped rows (same order as plan/CSV); row N+1 is first processed
  --start-row N        Same as --skip N-1 (1-based plan row; e.g. --start-row 25 skips 24 rows)
  --log-dir PATH       Logs / manifests (default: ${LOG_DIR})
  --dry-run            Plan only; no GCS mutations / no verify writes beyond logs
  --background         nohup re-launch
  --fail-missing       Fail if local folder missing (default: skip)
  --gcs-only           No local disk: plan by expected_path only; archive compares
                       STANDARD ↔ ARCHIVE (MD5 metadata). verify phase is not allowed.
  -h, --help           Help

Throughput (same idea as upload_data_lake_to_gcs.sh):
  week_jobs × gcloud_processes × gcloud_threads  ≈  concurrent GCS transfers
  default 4 × 1 × 8 = 32   (raise --jobs first; watch RAM)

Cost tip: keep default phase order (reorganize → verify → archive).

GCS-only (no DATA_LAKE on this machine):
  ./$(basename "$0") --gcs-only --phases reorganize,archive --start-row 55 --background --jobs 6
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv) CSV="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --credentials) CREDENTIALS="$2"; shift 2 ;;
    --src-bucket) SRC_BUCKET="$2"; shift 2 ;;
    --dst-bucket) DST_BUCKET="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --gcloud-processes) GCLOUD_PROCESSES="$2"; shift 2 ;;
    --gcloud-threads) GCLOUD_THREADS="$2"; shift 2 ;;
    --reorg-parallel) REORG_PARALLEL="$2"; shift 2 ;;
    --reorg-backend) REORG_BACKEND="$2"; shift 2 ;;
    --reorg-api-threads) REORG_API_THREADS="$2"; shift 2 ;;
    --phases) PHASES="$2"; shift 2 ;;
    --skip-success) SKIP_SUCCESS=1; shift ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --skip) SKIP="$2"; shift 2 ;;
    --start-row)
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--start-row must be >= 1"
      SKIP=$(( $2 - 1 ))
      shift 2
      ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --background) BACKGROUND=1; shift ;;
    --fail-missing) SKIP_MISSING=0; shift ;;
    --gcs-only) GCS_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

BASE="${BASE%/}"
PREFIX="${PREFIX#/}"; PREFIX="${PREFIX%/}"
SRC_BUCKET="${SRC_BUCKET#gs://}"; SRC_BUCKET="${SRC_BUCKET%/}"
DST_BUCKET="${DST_BUCKET#gs://}"; DST_BUCKET="${DST_BUCKET%/}"

[[ -f "$CSV" ]] || die "CSV not found: $CSV"
[[ -f "$CREDENTIALS" ]] || die "credentials not found: $CREDENTIALS"
if [[ "$GCS_ONLY" -eq 0 ]]; then
  [[ -d "$BASE" ]] || die "BASE not found: $BASE"
fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be positive"
[[ "$GCLOUD_PROCESSES" =~ ^[1-9][0-9]*$ ]] || die "--gcloud-processes must be positive"
[[ "$GCLOUD_THREADS" =~ ^[1-9][0-9]*$ ]] || die "--gcloud-threads must be positive"
[[ "$REORG_PARALLEL" =~ ^[1-9][0-9]*$ ]] || die "--reorg-parallel must be positive"
[[ "$REORG_API_THREADS" =~ ^[1-9][0-9]*$ ]] || die "--reorg-api-threads must be positive"
case "$REORG_BACKEND" in auto|gcloud|api) ;; *) die "--reorg-backend must be auto, gcloud, or api" ;; esac
[[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit must be non-negative"
[[ "$SKIP" =~ ^[0-9]+$ ]] || die "--skip must be non-negative"

want_reorganize=0; want_verify=0; want_archive=0
IFS=',' read -ra _phases <<< "$PHASES"
for p in "${_phases[@]}"; do
  p="$(echo "$p" | tr -d '[:space:]')"
  case "$p" in
    reorganize) want_reorganize=1 ;;
    verify) want_verify=1 ;;
    archive) want_archive=1 ;;
    "") ;;
    *) die "unknown phase: $p (use reorganize,verify,archive)" ;;
  esac
done
[[ $((want_reorganize + want_verify + want_archive)) -gt 0 ]] || die "no phases selected"

if [[ "$GCS_ONLY" -eq 1 ]]; then
  [[ "$want_verify" -eq 0 ]] || die "--gcs-only cannot use verify (needs local disk); use --phases reorganize,archive"
fi

mkdir -p "$LOG_DIR" "$LOG_DIR/jobs" "$LOG_DIR/manifests"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
MAIN_LOG="${LOG_DIR}/finalize_${RUN_ID}.log"
PLAN_FILE="${LOG_DIR}/plan_${RUN_ID}.tsv"
READY_FILE="${LOG_DIR}/ready_${RUN_ID}.tsv"
RESULTS_OK="${LOG_DIR}/success_${RUN_ID}.tsv"
RESULTS_FAIL="${LOG_DIR}/failed_${RUN_ID}.tsv"
RESULTS_LOCK="${LOG_DIR}/results_${RUN_ID}.lock"
PID_FILE="${LOG_DIR}/finalize.pid"
LATEST_LOG="${LOG_DIR}/latest.log"

log() {
  local ts; ts="$(date -Is)"
  if [[ "${FINALIZE_LOG_STDOUT_ONLY:-0}" -eq 1 ]]; then
    printf '[%s] %s\n' "$ts" "$*"
  else
    printf '[%s] %s\n' "$ts" "$*" | tee -a "$MAIN_LOG" >&2
  fi
}

if [[ "$BACKGROUND" -eq 1 ]]; then
  [[ "$DRY_RUN" -eq 0 ]] || die "--background cannot combine with --dry-run"
  reexec=(
    "$0" --csv "$CSV" --base "$BASE" --credentials "$CREDENTIALS"
    --src-bucket "$SRC_BUCKET" --dst-bucket "$DST_BUCKET" --prefix "$PREFIX"
    --jobs "$JOBS" --gcloud-processes "$GCLOUD_PROCESSES" --gcloud-threads "$GCLOUD_THREADS"
    --reorg-parallel "$REORG_PARALLEL" --phases "$PHASES" --limit "$LIMIT" --skip "$SKIP"
    --log-dir "$LOG_DIR"
  )
  [[ "$SKIP_MISSING" -eq 0 ]] && reexec+=(--fail-missing)
  [[ "$GCS_ONLY" -eq 1 ]] && reexec+=(--gcs-only)
  [[ "$SKIP_SUCCESS" -eq 1 ]] && reexec+=(--skip-success)
  reexec+=(--reorg-backend "$REORG_BACKEND" --reorg-api-threads "$REORG_API_THREADS")
  : >"$MAIN_LOG"
  ln -sfn "$(basename "$MAIN_LOG")" "$LATEST_LOG"
  nohup env FINALIZE_LOG_STDOUT_ONLY=1 "${reexec[@]}" >>"$MAIN_LOG" 2>&1 &
  echo $! >"$PID_FILE"
  echo "Started background finalize pid=$(cat "$PID_FILE")"
  echo "  log:    $MAIN_LOG"
  echo "  follow: tail -f $MAIN_LOG"
  exit 0
fi

: >"$MAIN_LOG"
ln -sfn "$(basename "$MAIN_LOG")" "$LATEST_LOG"
: >"$RESULTS_OK"
: >"$RESULTS_FAIL"
: >"$RESULTS_LOCK"

export GOOGLE_APPLICATION_CREDENTIALS="$CREDENTIALS"
export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$CREDENTIALS"
export CLOUDSDK_CORE_DISABLE_PROMPTS=1
CLOUDSDK_CORE_PROJECT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["project_id"])' "$CREDENTIALS")"
export CLOUDSDK_CORE_PROJECT
export CLOUDSDK_STORAGE_PROCESS_COUNT="$GCLOUD_PROCESSES"
export CLOUDSDK_STORAGE_THREAD_COUNT="$GCLOUD_THREADS"
export CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED=False

log "=== reorganize / verify / archive ==="
log "csv=$CSV base=$BASE"
log "src=gs://${SRC_BUCKET}/${PREFIX}/  dst=gs://${DST_BUCKET}/${PREFIX}/"
log "phases=$PHASES gcs_only=$GCS_ONLY jobs=$JOBS gcloud=${GCLOUD_PROCESSES}x${GCLOUD_THREADS} reorg=${REORG_BACKEND} parallel=$REORG_PARALLEL api_threads=$REORG_API_THREADS skip_success=$SKIP_SUCCESS dry_run=$DRY_RUN skip=$SKIP start_row=$((SKIP + 1)) limit=$LIMIT"
log "approx_gcs_workers=$((JOBS * GCLOUD_PROCESSES * GCLOUD_THREADS)) (jobs×processes×threads; md5/local disk adds load)"
log "project=$CLOUDSDK_CORE_PROJECT log=$MAIN_LOG"

# ── build plan ──────────────────────────────────────────────────────────────
PLAN_SUMMARY="$(
python3 - "$CSV" "$BASE" "$PLAN_FILE" "$LIMIT" "$SKIP" "$GCS_ONLY" <<'PY'
import csv, sys
from pathlib import Path
csv_path, base_s, plan_file, limit_s, skip_s, gcs_only_s = sys.argv[1:7]
limit = int(limit_s)
skip = int(skip_s)
gcs_only = int(gcs_only_s) != 0
base = Path(base_s)
skipped_empty = 0
skipped_by_flag = 0
rows = []
with open(csv_path, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for row in reader:
        local = (row.get("local_path") or "").strip().strip("/")
        expected = (row.get("expected_path") or "").strip().strip("/")
        if not expected:
            skipped_empty += 1
            continue
        if not local and not gcs_only:
            continue
        if skip > 0:
            skip -= 1
            skipped_by_flag += 1
            continue
        if gcs_only:
            label = local or expected
            local_abs = "-" if not local else str(base / local)
            status = "ok"
            rows.append((label, expected, status, local_abs))
        else:
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
mode = "gcs_only" if gcs_only else "local"
print(
    f"mode={mode} kept={len(rows)} ready={ready} missing_local={missing} "
    f"skipped_empty={skipped_empty} skipped_rows={skipped_by_flag}"
)
PY
)"
log "plan: $PLAN_SUMMARY"
log "plan_file=$PLAN_FILE"

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$GCS_ONLY" -eq 1 ]]; then
    log "DRY-RUN (gcs-only) sample mappings (expected_path on GCS -> archive):"
  else
    log "DRY-RUN sample mappings (local -> gs://${SRC_BUCKET}/${PREFIX}/expected -> archive):"
  fi
  TOTAL=$(($(wc -l <"$PLAN_FILE") - 1))
  set +o pipefail
  awk -F'\t' -v sb="$SRC_BUCKET" -v db="$DST_BUCKET" -v p="$PREFIX" -v skip="$SKIP" 'NR==1{next} {
    row=NR-1+skip
    printf "  [plan row %d] %s\n    reorg/verify: gs://%s/%s/%s/{media,analysis}/\n    archive:     gs://%s/%s/%s/\n", row, $1, sb, p, $2, db, p, $2
  }' "$PLAN_FILE" | head -n 40 | tee -a "$MAIN_LOG" >&2
  set -o pipefail
  [[ "$TOTAL" -gt 20 ]] && log "... ($TOTAL total rows; see $PLAN_FILE)"
  log "DRY-RUN complete. phases would run: $PHASES"
  exit 0
fi

if [[ "$SKIP_MISSING" -eq 0 ]]; then
  if awk -F'\t' 'NR>1 && $3=="missing_local"{exit 0} END{exit 1}' "$PLAN_FILE"; then
    die "missing local folders (see $PLAN_FILE)"
  fi
fi

awk -F'\t' 'NR==1{next} $3=="ok"{print $1"\t"$2"\t"$4}' "$PLAN_FILE" >"$READY_FILE"

if [[ "$SKIP_SUCCESS" -eq 1 ]]; then
  SKIP_SUCCESS_SET="${LOG_DIR}/skip_success_paths_${RUN_ID}.txt"
  : >"$SKIP_SUCCESS_SET"
  shopt -s nullglob
  for sf in "$LOG_DIR"/success_*.tsv; do
    awk -F'\t' 'NR>1 && $1=="OK"{print $3}' "$sf" >>"$SKIP_SUCCESS_SET"
  done
  shopt -u nullglob
  sort -u -o "$SKIP_SUCCESS_SET" "$SKIP_SUCCESS_SET"
  SKIP_SUCCESS_N="$(wc -l <"$SKIP_SUCCESS_SET" | tr -d ' ')"
  if [[ "$SKIP_SUCCESS_N" -gt 0 ]]; then
    READY_FILTERED="${READY_FILE}.filtered"
    awk -F'\t' 'NR==FNR{skip[$1]=1; next} !skip[$2]' "$SKIP_SUCCESS_SET" "$READY_FILE" >"$READY_FILTERED"
    mv "$READY_FILTERED" "$READY_FILE"
    log "skip_success_paths=$SKIP_SUCCESS_N (from success_*.tsv in $LOG_DIR)"
  else
    log "skip_success: no prior success_*.tsv entries found"
  fi
fi

READY_COUNT="$(wc -l <"$READY_FILE" | tr -d ' ')"
log "ready=$READY_COUNT"
[[ "$READY_COUNT" -gt 0 ]] || die "nothing to process"

# ── helpers (exported to workers) ───────────────────────────────────────────
is_top_level_media() {
  # $1 = object name relative to week prefix (no leading slash)
  local rel="$1"
  case "$rel" in
    */*) return 1 ;;  # nested → not top-level media
  esac
  local lower
  lower="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')"
  [[ "$lower" =~ $MEDIA_EXT_REGEX ]]
}

b64md5_to_hex() {
  python3 -c 'import base64,binascii,sys
s=sys.argv[1].strip()
if not s:
  raise SystemExit(1)
print(binascii.hexlify(base64.b64decode(s)).decode())' "$1" 2>/dev/null || true
}

append_result() {
  local status="$1" local_rel="$2" expected="$3" detail="$4"
  flock "$RESULTS_LOCK" bash -c \
    "printf '%s\t%s\t%s\t%s\n' \"\$1\" \"\$2\" \"\$3\" \"\$4\" >>\"\$5\"" \
    _ "$status" "$local_rel" "$expected" "$detail" \
    "$([[ "$status" == OK ]] && echo "$RESULTS_OK" || echo "$RESULTS_FAIL")"
}

# Legacy: one gcloud storage mv subprocess per object (slow; use --reorg-backend auto).
reorganize_mv_chunk_gcloud() {
  local chunk_file="$1"
  while IFS=$'\t' read -r src dst; do
    [[ -n "$src" && -n "$dst" ]] || continue
    gcloud storage mv "$src" "$dst" --quiet --continue-on-error || return 1
  done <"$chunk_file"
}

# One gcloud auth + parallel Storage JSON API objects.move (same bucket).
reorganize_mv_chunk_api() {
  local chunk_file="$1"
  python3 - "$chunk_file" "$SRC_BUCKET" "$REORG_API_THREADS" <<'PY'
import concurrent.futures
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

chunk_file, bucket, threads_s = sys.argv[1:4]
threads = max(1, int(threads_s))

def token():
    env = os.environ.copy()
    return subprocess.check_output(
        ["gcloud", "auth", "print-access-token"],
        env=env,
        stderr=subprocess.DEVNULL,
        text=True,
    ).strip()

def obj_from_gs(uri: str) -> str:
    assert uri.startswith("gs://"), uri
    rest = uri[5:]
    b, _, name = rest.partition("/")
    if b != bucket:
        raise ValueError(f"unexpected bucket in {uri}")
    return name

def object_exists(tok: str, obj_name: str) -> bool:
    enc = urllib.parse.quote(obj_name, safe="")
    url = f"https://storage.googleapis.com/storage/v1/b/{bucket}/o/{enc}"
    req = urllib.request.Request(
        url, method="GET", headers={"Authorization": f"Bearer {tok}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            resp.read()
        return True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        raise

def move_one(tok: str, src: str, dst: str):
    src_obj = obj_from_gs(src)
    dst_obj = obj_from_gs(dst)
    if not object_exists(tok, src_obj):
        if object_exists(tok, dst_obj):
            return None  # idempotent: already at destination (partial prior run)
        return f"missing source and destination: {src_obj}"
    enc_src = urllib.parse.quote(src_obj, safe="")
    enc_dst = urllib.parse.quote(dst_obj, safe="")
    url = (
        f"https://storage.googleapis.com/storage/v1/b/{bucket}/o/"
        f"{enc_src}/moveTo/o/{enc_dst}"
    )
    req = urllib.request.Request(
        url, method="POST", headers={"Authorization": f"Bearer {tok}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            resp.read()
        return None
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        if e.code == 404 and object_exists(tok, dst_obj):
            return None
        return f"HTTP {e.code}: {body[:240]}"

pairs = []
with open(chunk_file, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        src, dst = line.split("\t", 1)
        pairs.append((src, dst))
if not pairs:
    sys.exit(0)

tok = token()
fail = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=threads) as pool:
    futs = {pool.submit(move_one, tok, s, d): (s, d) for s, d in pairs}
    for fut in concurrent.futures.as_completed(futs):
        err = fut.result()
        if err:
            s, d = futs[fut]
            print(f"  FAIL  move {s} -> {d}: {err}", file=sys.stderr)
            fail += 1
sys.exit(1 if fail else 0)
PY
}

reorganize_mv_chunk() {
  local chunk_file="$1"
  case "$REORG_BACKEND" in
    gcloud) reorganize_mv_chunk_gcloud "$chunk_file" ;;
    api|auto) reorganize_mv_chunk_api "$chunk_file" ;;
    *) die "unknown REORG_BACKEND: $REORG_BACKEND" ;;
  esac
}

# Move an entire first-level folder to analysis/ in one gcloud invocation.
# Return 2 if analysis/${top_dir}/ already exists (partial prior run) — caller uses per-file mv.
reorganize_prefix_move() {
  local week_prefix="$1"
  local top_dir="$2"
  local src="gs://${SRC_BUCKET}/${week_prefix}/${top_dir}"
  local dst="gs://${SRC_BUCKET}/${week_prefix}/analysis/${top_dir}"
  local src_n dst_n
  src_n="$(gcloud storage objects list "${src}/**" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
  dst_n="$(gcloud storage objects list "${dst}/**" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$src_n" -eq 0 ]]; then
    echo "  INFO  prefix skip ${top_dir}/ (source empty; tree likely already under analysis/)"
    return 0
  fi
  if [[ "$dst_n" -gt 0 ]]; then
    echo "  WARN  prefix skip ${top_dir}/ (analysis/${top_dir}/ has ${dst_n} object(s); per-file mv avoids detections/detections nesting)"
    return 2
  fi
  echo "  INFO  reorganize prefix mv: ${top_dir}/ -> analysis/${top_dir}/ (bulk, ${src_n} object(s))"
  gcloud storage mv "$src" "$dst" --quiet --continue-on-error
}

reorganize_one() {
  local expected="$1"
  local week_prefix="${PREFIX}/${expected}"
  local src_uri="gs://${SRC_BUCKET}/${week_prefix}"
  local list_file="$2"
  local moved_media=0 moved_analysis=0 skipped=0
  local use_prefix_bulk=0
  [[ "$REORG_BACKEND" == auto || "$REORG_BACKEND" == gcloud ]] && use_prefix_bulk=1
  [[ "$REORG_BACKEND" == gcloud ]] && use_prefix_bulk=0  # legacy: per-file only

  gcloud storage objects list "${src_uri}/**" \
    --format='value(name)' >"$list_file" 2>/dev/null || true

  if [[ ! -s "$list_file" ]]; then
    echo "  WARN  no objects under ${src_uri}"
    return 0
  fi

  local mv_list="${list_file}.mv"
  local nested_list="${list_file}.nested"
  : >"$mv_list"
  : >"$nested_list"
  declare -A has_nested=()
  declare -A root_file=()
  local name rel dest top fail=0 fix_top fix_rest rc=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    case "$name" in
      "${week_prefix}/"*) rel="${name#${week_prefix}/}" ;;
      *) continue ;;
    esac
    [[ -n "$rel" ]] || continue
    # Fix double-nest from mistaken prefix mv when analysis/DIR/ already existed.
    if [[ "$rel" =~ ^analysis/([^/]+)/\1/(.+)$ ]]; then
      fix_top="${BASH_REMATCH[1]}"
      fix_rest="${BASH_REMATCH[2]}"
      printf '%s\t%s\n' \
        "gs://${SRC_BUCKET}/${name}" \
        "gs://${SRC_BUCKET}/${week_prefix}/analysis/${fix_top}/${fix_rest}" >>"$mv_list"
      moved_analysis=$((moved_analysis + 1))
      continue
    fi
    case "$rel" in
      media/*|analysis/*) skipped=$((skipped + 1)); continue ;;
    esac
    if [[ "$rel" == */* ]]; then
      top="${rel%%/*}"
      has_nested["$top"]=1
      printf '%s\n' "$rel" >>"$nested_list"
      moved_analysis=$((moved_analysis + 1))
      continue
    fi
    root_file["$rel"]=1
    if is_top_level_media "$rel"; then
      dest="gs://${SRC_BUCKET}/${week_prefix}/media/${rel}"
      moved_media=$((moved_media + 1))
    else
      dest="gs://${SRC_BUCKET}/${week_prefix}/analysis/${rel}"
      moved_analysis=$((moved_analysis + 1))
    fi
    printf '%s\t%s\n' "gs://${SRC_BUCKET}/${name}" "$dest" >>"$mv_list"
  done <"$list_file"

  if [[ "$use_prefix_bulk" -eq 1 ]]; then
    for top in "${!has_nested[@]}"; do
      if [[ -n "${root_file[$top]+x}" ]]; then
        echo "  WARN  prefix skip ${top}/ (also a root object name); using per-file mv for that tree"
        while IFS= read -r rel; do
          [[ "$rel" == "${top}/"* ]] || continue
          printf '%s\t%s\n' \
            "gs://${SRC_BUCKET}/${week_prefix}/${rel}" \
            "gs://${SRC_BUCKET}/${week_prefix}/analysis/${rel}" >>"$mv_list"
        done <"$nested_list"
        continue
      fi
      rc=0
      reorganize_prefix_move "$week_prefix" "$top" || rc=$?
      if [[ "$rc" -eq 2 ]]; then
        while IFS= read -r rel; do
          [[ "$rel" == "${top}/"* ]] || continue
          printf '%s\t%s\n' \
            "gs://${SRC_BUCKET}/${week_prefix}/${rel}" \
            "gs://${SRC_BUCKET}/${week_prefix}/analysis/${rel}" >>"$mv_list"
        done <"$nested_list"
      elif [[ "$rc" -ne 0 ]]; then
        fail=1
      fi
    done
  else
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      printf '%s\t%s\n' \
        "gs://${SRC_BUCKET}/${week_prefix}/${rel}" \
        "gs://${SRC_BUCKET}/${week_prefix}/analysis/${rel}" >>"$mv_list"
    done <"$nested_list"
  fi

  if [[ -s "$mv_list" ]]; then
    local nlines workers chunk_dir cf pid pids=()
    nlines="$(wc -l <"$mv_list" | tr -d ' ')"
    workers="$REORG_PARALLEL"
    [[ "$nlines" -lt "$workers" ]] && workers="$nlines"
    [[ "$workers" -lt 1 ]] && workers=1
    chunk_dir="${mv_list}.chunks"
    rm -rf "$chunk_dir"
    mkdir -p "$chunk_dir"
    split -n "l/$workers" "$mv_list" "$chunk_dir/chunk_"
    echo "  INFO  reorganize file mv: ${nlines} object(s), ${workers} chunk(s), backend=${REORG_BACKEND}"
    for cf in "$chunk_dir"/chunk_*; do
      [[ -f "$cf" ]] || continue
      reorganize_mv_chunk "$cf" &
      pids+=($!)
    done
    for pid in "${pids[@]}"; do
      wait "$pid" || fail=1
    done
    rm -rf "$chunk_dir"
  fi
  rm -f "$nested_list"

  if [[ "$fail" -ne 0 ]]; then
    echo "  FAIL  one or more reorganize move operations failed"
    return 1
  fi

  echo "  reorganize: media+=${moved_media} analysis+=${moved_analysis} skipped_already=${skipped}"
}

# Build local manifest with GCS-facing keys: media/... or analysis/...
# Output: rel|hexmd5|size  (sorted by rel)
build_local_mapped_manifest() {
  local local_abs="$1"
  local out_manifest="$2"
  : >"$out_manifest"
  echo "  INFO  computing local MD5 (batched) under ${local_abs}..."
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local lmd5 f rel gcs_rel sz
    lmd5="$(printf '%s' "$line" | awk '{print $1}')"
    f="$(printf '%s' "$line" | sed 's/^[0-9a-fA-F]\{32\}  //')"
    [[ -f "$f" ]] || continue
    rel="${f#${local_abs}/}"
    if is_top_level_media "$rel"; then
      gcs_rel="media/${rel}"
    else
      gcs_rel="analysis/${rel}"
    fi
    sz="$(wc -c <"$f" | tr -d ' ')"
    printf '%s|%s|%s\n' "$gcs_rel" "$lmd5" "$sz" >>"$out_manifest"
  done < <(find "$local_abs" -type f -print0 | sort -z | xargs -0 md5sum 2>/dev/null | LC_ALL=C sort)
  sort -t'|' -k1,1 -o "$out_manifest" "$out_manifest"
}

verify_one() {
  local local_abs="$1"
  local expected="$2"
  local job_dir="$3"
  local week_prefix="${PREFIX}/${expected}"
  local src_uri="gs://${SRC_BUCKET}/${week_prefix}"
  local dst_uri="gs://${DST_BUCKET}/${week_prefix}"
  local local_manifest="${job_dir}/local.manifest"
  local gcs_manifest="${job_dir}/gcs.manifest"
  local gcs_raw="${job_dir}/gcs.csv"
  local status_file="${job_dir}/verify_status.txt"

  mkdir -p "$job_dir"
  build_local_mapped_manifest "$local_abs" "$local_manifest"
  local local_count
  local_count="$(wc -l <"$local_manifest" | tr -d ' ')"
  if [[ "$local_count" -eq 0 ]]; then
    echo "  FAIL  no local files under ${local_abs}"
    return 1
  fi

  # Prefer STANDARD; if already archived (STANDARD empty), verify against ARCHIVE.
  local verify_bucket="$SRC_BUCKET"
  local verify_label="STANDARD"
  local verify_uri="$src_uri"

  echo "  INFO  listing STANDARD objects + md5 (${src_uri}/**)..."
  if ! build_gcs_prefix_manifest "$SRC_BUCKET" "$week_prefix" "$gcs_manifest" "$gcs_raw"; then
    echo "  FAIL  could not list STANDARD objects"
    return 1
  fi
  local std_n
  std_n="$(wc -l <"$gcs_manifest" | tr -d ' ')"

  if [[ "$std_n" -eq 0 ]]; then
    echo "  INFO  STANDARD empty (already archived?) — falling back to ARCHIVE ${dst_uri}/"
    verify_bucket="$DST_BUCKET"
    verify_label="ARCHIVE"
    verify_uri="$dst_uri"
    if ! build_gcs_prefix_manifest "$DST_BUCKET" "$week_prefix" "$gcs_manifest" "$gcs_raw"; then
      echo "  FAIL  could not list ARCHIVE objects either"
      return 1
    fi
    if [[ "$(wc -l <"$gcs_manifest" | tr -d ' ')" -eq 0 ]]; then
      echo "  FAIL  both STANDARD and ARCHIVE are empty for ${expected}"
      return 1
    fi
  fi

  echo "  INFO  verifying LOCAL ↔ ${verify_label} (MD5) at ${verify_uri}/..."
  if compare_manifests "$local_manifest" "$gcs_manifest" "LOCAL" "$verify_label"; then
    local checked gcs_n
    checked="$(wc -l <"$local_manifest" | tr -d ' ')"
    gcs_n="$(wc -l <"$gcs_manifest" | tr -d ' ')"
    printf 'MD5_VERIFIED files=%s local=%s gcs=%s bucket=%s missing=0 extra=0 md5_mismatch=0\n' \
      "$checked" "$local_count" "$gcs_n" "$verify_label" >"$status_file"
    echo "  OK    MD5 VERIFIED: LOCAL ↔ ${verify_label} (${checked} file(s), count+size+checksum)"
    return 0
  fi
  printf 'MD5_FAILED local=%s gcs=%s bucket=%s\n' \
    "$local_count" "$(wc -l <"$gcs_manifest" | tr -d ' ')" "$verify_label" >"$status_file"
  echo "  FAIL  MD5 verification FAILED (LOCAL ↔ ${verify_label})"
  return 1
}

# Write rel|hexmd5|size manifest for all objects under gs://bucket/week_prefix/
build_gcs_prefix_manifest() {
  local bucket="$1"
  local week_prefix="$2"
  local out_manifest="$3"
  local raw_csv="$4"
  local uri="gs://${bucket}/${week_prefix}"
  : >"$out_manifest"
  if ! gcloud storage objects list "${uri}/**" \
      --format='csv[no-heading](name,size,md5_hash)' >"$raw_csv" 2>/dev/null; then
    return 1
  fi
  python3 - "$raw_csv" "$out_manifest" "$week_prefix" <<'PY'
import base64, binascii, csv, sys
raw, out, week_prefix = sys.argv[1:4]
prefix = week_prefix.rstrip("/") + "/"
with open(raw, newline="", encoding="utf-8") as f, open(out, "w", encoding="utf-8") as o:
    for row in csv.reader(f):
        if len(row) < 3:
            continue
        name, size, md5_b64 = row[0], row[1], row[2]
        if not name.startswith(prefix):
            continue
        rel = name[len(prefix):]
        if not rel:
            continue
        try:
            md5_hex = binascii.hexlify(base64.b64decode(md5_b64.strip())).decode()
        except Exception:
            md5_hex = ""
        o.write(f"{rel}|{md5_hex}|{size}\n")
PY
  sort -t'|' -k1,1 -o "$out_manifest" "$out_manifest"
}

# Compare two rel|md5|size manifests. Returns 0 only on perfect match.
compare_manifests() {
  local left="$1"   # e.g. STANDARD
  local right="$2"  # e.g. ARCHIVE
  local left_label="${3:-left}"
  local right_label="${4:-right}"
  local fail=0
  local left_n right_n
  left_n="$(wc -l <"$left" | tr -d ' ')"
  right_n="$(wc -l <"$right" | tr -d ' ')"

  if [[ "$left_n" -eq 0 ]]; then
    echo "  FAIL  ${left_label} manifest is empty"
    return 1
  fi
  if [[ "$left_n" -ne "$right_n" ]]; then
    echo "  FAIL  count mismatch: ${left_label}=${left_n} ${right_label}=${right_n}"
    fail=1
  else
    echo "  OK    count matches: ${left_n}"
  fi

  local left_rels right_rels
  left_rels="$(mktemp)"; right_rels="$(mktemp)"
  cut -d'|' -f1 "$left" | sort >"$left_rels"
  cut -d'|' -f1 "$right" | sort >"$right_rels"

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    echo "  FAIL  missing in ${right_label}: ${rel}"
    fail=1
  done < <(comm -23 "$left_rels" "$right_rels")

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    echo "  FAIL  extra in ${right_label}: ${rel}"
    fail=1
  done < <(comm -13 "$left_rels" "$right_rels")

  local mismatch=0 checked=0 limit=25
  while IFS='|' read -r rel lmd5 lsz rmd5 rsz; do
    [[ -n "$rel" ]] || continue
    checked=$((checked + 1))
    if [[ -z "$rmd5" || -z "$lmd5" ]]; then
      echo "  FAIL  empty MD5 for ${rel} (${left_label}=${lmd5:-?} ${right_label}=${rmd5:-?})"
      fail=1
      continue
    fi
    if [[ -n "$lsz" && -n "$rsz" && "$lsz" != "$rsz" ]]; then
      echo "  FAIL  size mismatch ${rel}: ${left_label}=${lsz} ${right_label}=${rsz}"
      fail=1
    fi
    if [[ "$lmd5" != "$rmd5" ]]; then
      mismatch=$((mismatch + 1))
      fail=1
      if [[ "$mismatch" -le "$limit" ]]; then
        echo "  FAIL  MD5 mismatch ${rel}: ${left_label}=${lmd5} ${right_label}=${rmd5}"
      fi
    fi
  done < <(join -t'|' -a1 -a2 -e '' -o '0,1.2,1.3,2.2,2.3' "$left" "$right")

  [[ "$mismatch" -gt "$limit" ]] && echo "  FAIL  MD5 mismatch (+$((mismatch - limit)) more)"
  rm -f "$left_rels" "$right_rels"

  if [[ "$fail" -eq 0 ]]; then
    echo "  OK    MD5 VERIFIED ${left_label} ↔ ${right_label}: ${checked} object(s) match (name+size+checksum)"
    return 0
  fi
  echo "  FAIL  MD5 verification FAILED ${left_label} ↔ ${right_label}"
  return 1
}

# Archive without local disk: snapshot STANDARD (MD5 metadata) → rsync → STANDARD ↔ ARCHIVE → delete STANDARD.
archive_one_gcs() {
  local expected="$1"
  local job_dir="$2"
  local week_prefix="${PREFIX}/${expected}"
  local src_uri="gs://${SRC_BUCKET}/${week_prefix}"
  local dst_uri="gs://${DST_BUCKET}/${week_prefix}"
  local src_man="${job_dir}/archive_src.manifest"
  local src_csv="${job_dir}/archive_src.csv"
  local dst_man="${job_dir}/archive_dst.manifest"
  local dst_csv="${job_dir}/archive_dst.csv"

  mkdir -p "$job_dir"
  echo "  INFO  archive pipeline (gcs-only): snapshot STANDARD → rsync → MD5 STANDARD↔ARCHIVE → delete STANDARD"

  echo "  INFO  snapshot STANDARD manifest ${src_uri}/"
  if ! build_gcs_prefix_manifest "$SRC_BUCKET" "$week_prefix" "$src_man" "$src_csv"; then
    echo "  FAIL  could not list STANDARD objects"
    return 1
  fi
  local src_n
  src_n="$(wc -l <"$src_man" | tr -d ' ')"
  if [[ "$src_n" -eq 0 ]]; then
    echo "  INFO  STANDARD empty — checking ARCHIVE ${dst_uri}/"
    if ! build_gcs_prefix_manifest "$DST_BUCKET" "$week_prefix" "$dst_man" "$dst_csv"; then
      echo "  FAIL  could not list ARCHIVE objects"
      return 1
    fi
    local dst_n
    dst_n="$(wc -l <"$dst_man" | tr -d ' ')"
    if [[ "$dst_n" -eq 0 ]]; then
      echo "  FAIL  both STANDARD and ARCHIVE are empty for ${expected}"
      return 1
    fi
    printf 'ARCHIVE_GCS_ONLY files=%s standard=0 archive=%s dst=%s skipped=already_archived\n' \
      "$dst_n" "$dst_n" "$dst_uri" >"${job_dir}/archive_status.txt"
    echo "  OK    STANDARD empty; ARCHIVE has ${dst_n} object(s) — nothing to copy or delete"
    return 0
  fi

  echo "  INFO  STANDARD objects=${src_n}"
  echo "  INFO  rsync copy ${src_uri}/ -> ${dst_uri}/ (parallel gcloud transfer)"
  if ! gcloud storage rsync --recursive --continue-on-error "${src_uri}" "${dst_uri}"; then
    echo "  FAIL  archive rsync copy failed — STANDARD left untouched"
    return 1
  fi

  echo "  INFO  snapshot ARCHIVE manifest ${dst_uri}/"
  if ! build_gcs_prefix_manifest "$DST_BUCKET" "$week_prefix" "$dst_man" "$dst_csv"; then
    echo "  FAIL  could not list ARCHIVE objects — STANDARD left untouched"
    return 1
  fi

  echo "  INFO  verifying STANDARD ↔ ARCHIVE (MD5 metadata) before delete..."
  if ! compare_manifests "$src_man" "$dst_man" "STANDARD" "ARCHIVE"; then
    echo "  FAIL  STANDARD ↔ ARCHIVE verification failed — STANDARD NOT deleted (safe to retry)"
    return 1
  fi

  echo "  INFO  STANDARD↔ARCHIVE PASS — deleting STANDARD ${src_uri}/"
  if ! gcloud storage rm --recursive --continue-on-error "${src_uri}/**"; then
    echo "  FAIL  ARCHIVE matches STANDARD but STANDARD delete failed"
    echo "  INFO  data is safe in ARCHIVE; clean STANDARD manually or re-run --phases archive --gcs-only"
    return 1
  fi
  local left
  left="$(gcloud storage objects list "${src_uri}/**" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$left" != "0" ]]; then
    echo "  FAIL  STANDARD still has ${left} object(s) after delete"
    return 1
  fi

  printf 'ARCHIVE_GCS_ONLY files=%s standard=%s archive=%s dst=%s\n' \
    "$src_n" "$src_n" "$(wc -l <"$dst_man" | tr -d ' ')" "$dst_uri" \
    >"${job_dir}/archive_status.txt"
  echo "  OK    ARCHIVE MD5 VERIFIED: STANDARD ↔ ARCHIVE (${src_n} file(s)); STANDARD removed"
  return 0
}

archive_one() {
  local expected="$1"
  local job_dir="$2"
  local local_abs="$3"
  if [[ "${GCS_ONLY:-0}" -eq 1 ]]; then
    archive_one_gcs "$expected" "$job_dir"
    return $?
  fi
  local week_prefix="${PREFIX}/${expected}"
  local src_uri="gs://${SRC_BUCKET}/${week_prefix}"
  local dst_uri="gs://${DST_BUCKET}/${week_prefix}"
  local local_man="${job_dir}/archive_local.manifest"
  local dst_man="${job_dir}/archive_dst.manifest"
  local dst_csv="${job_dir}/archive_dst.csv"
  local src_names="${job_dir}/archive_src_names.txt"

  mkdir -p "$job_dir"
  echo "  INFO  archive pipeline: copy → MD5 compare LOCAL↔ARCHIVE → delete STANDARD"

  gcloud storage objects list "${src_uri}/**" --format='value(name)' >"$src_names" 2>/dev/null || true
  local src_n
  src_n="$(wc -l <"$src_names" | tr -d ' ')"
  if [[ "$src_n" -eq 0 ]]; then
    if [[ -s "${job_dir}/local.manifest" && -f "${job_dir}/verify_status.txt" ]] \
        && grep -q 'bucket=ARCHIVE' "${job_dir}/verify_status.txt" \
        && grep -q 'MD5_VERIFIED' "${job_dir}/verify_status.txt"; then
      local local_n
      local_n="$(wc -l <"${job_dir}/local.manifest" | tr -d ' ')"
      printf 'ARCHIVE_MD5_VERIFIED files=%s local=%s archive=%s dst=%s skipped=already_archived\n' \
        "$local_n" "$local_abs" "$local_n" "$dst_uri" >"${job_dir}/archive_status.txt"
      echo "  OK    STANDARD empty; verify already passed vs ARCHIVE — skipping archive re-check"
      return 0
    fi
    echo "  INFO  STANDARD empty — verifying existing ARCHIVE against LOCAL"
  else
    echo "  INFO  STANDARD objects=${src_n}"
    echo "  INFO  rsync copy ${src_uri}/ -> ${dst_uri}/ (parallel gcloud transfer)"
    if ! gcloud storage rsync --recursive --continue-on-error "${src_uri}" "${dst_uri}"; then
      echo "  FAIL  archive rsync copy failed — STANDARD left untouched"
      return 1
    fi
  fi

  if [[ -s "${job_dir}/local.manifest" ]]; then
    cp "${job_dir}/local.manifest" "$local_man"
    echo "  INFO  reusing local MD5 manifest from verify (no second disk pass)"
  else
    build_local_mapped_manifest "$local_abs" "$local_man"
  fi
  local local_n
  local_n="$(wc -l <"$local_man" | tr -d ' ')"
  if [[ "$local_n" -eq 0 ]]; then
    echo "  FAIL  no local files under ${local_abs}"
    return 1
  fi

  echo "  INFO  snapshot ARCHIVE manifest ${dst_uri}/"
  if ! build_gcs_prefix_manifest "$DST_BUCKET" "$week_prefix" "$dst_man" "$dst_csv"; then
    echo "  FAIL  could not list ARCHIVE objects — STANDARD left untouched"
    return 1
  fi

  echo "  INFO  verifying LOCAL ↔ ARCHIVE (MD5) before delete..."
  if ! compare_manifests "$local_man" "$dst_man" "LOCAL" "ARCHIVE"; then
    echo "  FAIL  LOCAL ↔ ARCHIVE verification failed — STANDARD NOT deleted (safe to retry)"
    return 1
  fi

  if [[ "$src_n" -gt 0 ]]; then
    echo "  INFO  LOCAL↔ARCHIVE PASS — deleting STANDARD ${src_uri}/"
    if ! gcloud storage rm --recursive --continue-on-error "${src_uri}/**"; then
      echo "  FAIL  ARCHIVE matches LOCAL but STANDARD delete failed"
      echo "  INFO  data is safe in ARCHIVE; clean STANDARD manually or re-run --phases archive"
      return 1
    fi
    local left
    left="$(gcloud storage objects list "${src_uri}/**" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$left" != "0" ]]; then
      echo "  FAIL  STANDARD still has ${left} object(s) after delete"
      return 1
    fi
  else
    echo "  INFO  STANDARD already empty — nothing to delete"
  fi

  printf 'ARCHIVE_MD5_VERIFIED files=%s local=%s archive=%s dst=%s\n' \
    "$local_n" "$local_abs" "$(wc -l <"$dst_man" | tr -d ' ')" "$dst_uri" \
    >"${job_dir}/archive_status.txt"
  echo "  OK    ARCHIVE MD5 VERIFIED: LOCAL ↔ ARCHIVE (${local_n} file(s)); STANDARD removed/empty"
  return 0
}

process_one() {
  # Ensure pipeline failures (verify_one | tee) are detected even if caller used set +e.
  set -o pipefail
  local local_rel="$1"
  local expected="$2"
  local local_abs="$3"
  local job_log="${LOG_DIR}/jobs/${expected//\//__}.log"
  local job_dir="${LOG_DIR}/manifests/${expected//\//__}"
  local list_file rc=0
  mkdir -p "$(dirname "$job_log")" "$job_dir"
  list_file="${job_dir}/object_names.txt"

  {
    echo "=== finalize ${expected} ==="
    echo "start=$(date -Is)"
    echo "local=${local_abs}"
    echo "expected=${expected}"
  } >"$job_log"

  echo "START ${local_rel} -> ${expected}"

  local detail_bits=()

  if [[ "$want_reorganize" -eq 1 ]]; then
    echo "[reorganize] gs://${SRC_BUCKET}/${PREFIX}/${expected}/" | tee -a "$job_log"
    if ! reorganize_one "$expected" "$list_file" 2>&1 | tee -a "$job_log"; then
      echo "FAIL ${expected} reorganize"
      append_result FAIL "$local_rel" "$expected" "reorganize"
      return 1
    fi
    detail_bits+=("reorganize=ok")
  fi

  if [[ "$want_verify" -eq 1 ]]; then
    echo "[verify] local ${local_abs} <-> gs://${SRC_BUCKET}/${PREFIX}/${expected}/ (MD5)" | tee -a "$job_log"
    if ! verify_one "$local_abs" "$expected" "$job_dir" 2>&1 | tee -a "$job_log"; then
      echo "FAIL ${expected} verify (MD5)"
      append_result FAIL "$local_rel" "$expected" "verify_md5"
      return 1
    fi
    local vstat=""
    [[ -f "${job_dir}/verify_status.txt" ]] && vstat="$(tr -d '\n' <"${job_dir}/verify_status.txt")"
    echo "MD5_OK  ${expected}  ${vstat}" | tee -a "$job_log"
    detail_bits+=("${vstat:-MD5_VERIFIED}")
  fi

  if [[ "$want_archive" -eq 1 ]]; then
    if [[ "${GCS_ONLY:-0}" -eq 1 ]]; then
      echo "[archive] -> gs://${DST_BUCKET}/${PREFIX}/${expected}/ (gcs-only: rsync + STANDARD↔ARCHIVE MD5 + delete STANDARD)" | tee -a "$job_log"
    else
      echo "[archive] -> gs://${DST_BUCKET}/${PREFIX}/${expected}/ (copy + LOCAL↔ARCHIVE MD5 + delete STANDARD)" | tee -a "$job_log"
    fi
    if ! archive_one "$expected" "$job_dir" "$local_abs" 2>&1 | tee -a "$job_log"; then
      if [[ "${GCS_ONLY:-0}" -eq 1 ]]; then
        echo "FAIL ${expected} archive (STANDARD↔ARCHIVE MD5 gate)"
        append_result FAIL "$local_rel" "$expected" "archive_gcs_md5"
      else
        echo "FAIL ${expected} archive (LOCAL↔ARCHIVE MD5 gate)"
        append_result FAIL "$local_rel" "$expected" "archive_local_md5"
      fi
      return 1
    fi
    local astat=""
    [[ -f "${job_dir}/archive_status.txt" ]] && astat="$(tr -d '\n' <"${job_dir}/archive_status.txt")"
    echo "ARCHIVE_MD5_OK  ${expected}  ${astat}" | tee -a "$job_log"
    detail_bits+=("${astat:-ARCHIVE_MD5_VERIFIED}")
  fi

  echo "end=$(date -Is) exit=0" >>"$job_log"
  local detail
  detail="$(IFS=';'; echo "${detail_bits[*]}")"
  append_result OK "$local_rel" "$expected" "$detail"
  echo "OK   ${local_rel} -> ${expected}  [${detail}]"
  return 0
}

export -f log die is_top_level_media b64md5_to_hex append_result
export -f reorganize_mv_chunk_gcloud reorganize_mv_chunk_api reorganize_mv_chunk
export -f reorganize_prefix_move reorganize_one build_local_mapped_manifest verify_one
export REORG_PARALLEL REORG_BACKEND REORG_API_THREADS
export -f build_gcs_prefix_manifest compare_manifests
export -f archive_one_gcs archive_one process_one
export SRC_BUCKET DST_BUCKET PREFIX BASE LOG_DIR RESULTS_OK RESULTS_FAIL RESULTS_LOCK
export MEDIA_EXT_REGEX want_reorganize want_verify want_archive PHASES GCS_ONLY
export GOOGLE_APPLICATION_CREDENTIALS CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE
export CLOUDSDK_CORE_DISABLE_PROMPTS CLOUDSDK_CORE_PROJECT
export CLOUDSDK_STORAGE_PROCESS_COUNT CLOUDSDK_STORAGE_THREAD_COUNT
export CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED

log "processing starting..."
START_ALL="$(date +%s)"
set +e
upload_pids=()
while IFS=$'\t' read -r local_rel expected local_abs; do
  while true; do
    alive=()
    # Never use ${arr[@]:-} here: empty array + :- expands to one empty word,
    # so upload_pids becomes ("") and this loop spins forever when JOBS=1.
    for pid in "${upload_pids[@]}"; do
      [[ -n "$pid" ]] || continue
      if kill -0 "$pid" 2>/dev/null; then
        alive+=("$pid")
      else
        wait "$pid" 2>/dev/null || true
      fi
    done
    upload_pids=("${alive[@]}")
    [[ "${#upload_pids[@]}" -lt "$JOBS" ]] && break
    sleep 0.5
  done
  process_one "$local_rel" "$expected" "$local_abs" &
  upload_pids+=($!)
done <"$READY_FILE"

for pid in "${upload_pids[@]}"; do
  [[ -n "$pid" ]] || continue
  wait "$pid" 2>/dev/null || true
done
set -e

END_ALL="$(date +%s)"
OK_COUNT="$(wc -l <"$RESULTS_OK" | tr -d ' ')"
FAIL_COUNT="$(wc -l <"$RESULTS_FAIL" | tr -d ' ')"
log "=== finished in $((END_ALL - START_ALL))s ==="
log "success=$OK_COUNT failed=$FAIL_COUNT ready=$READY_COUNT"
log "success_list=$RESULTS_OK"
log "failed_list=$RESULTS_FAIL"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  log "Some folders failed. Inspect $RESULTS_FAIL and $LOG_DIR/jobs/"
  exit 1
fi
log "All folders completed successfully."
exit 0
