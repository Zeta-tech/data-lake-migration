#!/usr/bin/env python3
"""Validate DATA_LAKE folder layout against the expected hierarchy.

Expected pattern (7 levels under DATA_LAKE):

    {process}/{fruit}/{client}/{variety}/{block}/{campaign}/{week}/

Strict naming for a path to be "good":
    campaign = cXXXX   (e.g. c2026 — bare 2026 is NOT good)
    week     = wXX     (exactly two digits — w5, w03b, w05_backup are NOT good)

Under each week folder, media (photos/videos) is expected. CSV files and
analysis result subfolders (detections, results, summary, calibers, ...)
are optional, expected, and never treated as layout problems.

Week-like folders nested *inside* analysis directories (e.g.
.../summary/gt_record/w22 or .../w12/fine_tunning/w12) are ignored.

Top-level folders outside the production processes (e.g. training/, backups/)
are listed but not validated against the pattern.

Outputs (written to --output-dir):
  - summary.txt          human-readable report
  - good_paths.csv       paths matching the pattern
  - bad_paths.csv        paths that deviate (with reason)
  - week_inventory.csv   every week-like folder with content flags
  - report.json          machine-readable full report
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

PRODUCTION_PROCESSES = ("counter", "sizer", "videos")

# Loose pattern: discover week-like folders so variants are still inventoried
# and flagged as bad (not silently skipped).
WEEK_RE = re.compile(r"^w\d{1,2}[a-z0-9_]*$", re.IGNORECASE)

# Strict patterns: only these count as good_paths.
STRICT_WEEK_RE = re.compile(r"^w\d{2}$")
STRICT_CAMPAIGN_RE = re.compile(r"^c\d{4}$")
BARE_YEAR_RE = re.compile(r"^20\d{2}$")

PHOTO_EXT = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".webp", ".heic"}
VIDEO_EXT = {".mp4", ".mov", ".avi", ".mkv", ".m4v", ".wmv", ".mpg", ".mpeg"}
CSV_EXT = {".csv"}

# Allowed (and expected) children of a week folder. Also used as ancestors to
# ignore: any week nested under one of these is skipped, not flagged as bad.
RESULT_SUBDIR_NAMES = {
    "detections",
    "detections_full",
    "results",
    "resultados",
    "summary",
    "summary (copy)",
    "calibers",
    "caliber",
    "output",
    "outputs",
    "analysis",
    "analisis",
    "report",
    "plots",
    "config",
    "fine_tunning",
    "gt_record",
    "gts",
    "desc",
    "descartes",
    "descart",
    "medidas",
}


def is_result_dir_name(name: str) -> bool:
    lower = name.strip().lower()
    if lower in RESULT_SUBDIR_NAMES:
        return True
    # Loose match for common analysis folder naming
    return any(
        token in lower
        for token in ("summary", "detect", "result", "caliber", "fine_tunn")
    )


def has_result_ancestor(parts: tuple[str, ...]) -> bool:
    """True if any parent of this path is an analysis/result folder."""
    return any(is_result_dir_name(p) for p in parts[:-1])


@dataclass
class WeekRecord:
    path: str
    process: str
    fruit: str
    client: str
    variety: str
    block: str
    campaign: str
    week: str
    depth: int
    shape: str
    is_good: bool
    reason: str
    n_photos: int = 0
    n_videos: int = 0
    n_csv: int = 0
    n_other_files: int = 0
    n_subdirs: int = 0
    result_subdirs: list[str] = field(default_factory=list)
    other_subdirs: list[str] = field(default_factory=list)
    is_empty: bool = False


def is_week(name: str) -> bool:
    """True for week-like folder names (discovery; may include non-standard)."""
    return bool(WEEK_RE.match(name.strip()))


def is_strict_week(name: str) -> bool:
    """True only for canonical week names: wXX (exactly two digits, lowercase)."""
    return bool(STRICT_WEEK_RE.match(name.strip()))


def is_strict_campaign(name: str) -> bool:
    """True only for canonical campaign names: cXXXX (lowercase)."""
    return bool(STRICT_CAMPAIGN_RE.match(name.strip()))


def classify_shape(parts: tuple[str, ...]) -> tuple[str, bool, str]:
    """Return (shape_label, is_good, reason) for a path ending in a week folder."""
    depth = len(parts)  # relative to DATA_LAKE
    week = parts[-1]

    if depth == 7:
        campaign = parts[5]
        reasons: list[str] = []

        if not is_strict_campaign(campaign):
            if BARE_YEAR_RE.match(campaign.strip()):
                reasons.append(f"campaign_must_be_cXXXX:{campaign}")
            else:
                reasons.append(f"invalid_campaign:{campaign}")

        if not is_strict_week(week):
            reasons.append(f"week_must_be_wXX:{week}")

        if not reasons:
            return (
                "OK process/fruit/client/variety/block/cXXXX/wXX",
                True,
                "",
            )

        return (
            f"depth7 non-standard: campaign='{campaign}' week='{week}' "
            f"(expected cXXXX/wXX)",
            False,
            "|".join(reasons),
        )

    if depth == 6:
        return (
            "MISSING campaign: process/fruit/client/variety/block/week",
            False,
            "missing_campaign",
        )

    if depth == 5:
        return (
            "SHORT: process/fruit/client/variety/week",
            False,
            "missing_block_and_campaign",
        )

    if depth < 5:
        return (
            f"VERY_SHORT week at depth {depth}",
            False,
            f"too_short_depth_{depth}",
        )

    if depth > 7:
        return (
            f"TOO_DEEP week at depth {depth}: {'/'.join(parts)}",
            False,
            f"extra_levels_depth_{depth}",
        )

    return (
        f"OTHER week at depth {depth}",
        False,
        f"other_depth_{depth}",
    )


def inspect_week_dir(path: Path) -> dict:
    n_photos = n_videos = n_csv = n_other = 0
    result_subdirs: list[str] = []
    other_subdirs: list[str] = []
    try:
        entries = list(path.iterdir())
    except PermissionError:
        return {
            "n_photos": 0,
            "n_videos": 0,
            "n_csv": 0,
            "n_other_files": 0,
            "n_subdirs": 0,
            "result_subdirs": [],
            "other_subdirs": [],
            "is_empty": True,
            "error": "permission_denied",
        }

    for entry in entries:
        if entry.is_file():
            ext = entry.suffix.lower()
            if ext in PHOTO_EXT:
                n_photos += 1
            elif ext in VIDEO_EXT:
                n_videos += 1
            elif ext in CSV_EXT:
                n_csv += 1
            else:
                n_other += 1
        elif entry.is_dir():
            name = entry.name
            if is_result_dir_name(name):
                result_subdirs.append(name)
            else:
                other_subdirs.append(name)

    n_subdirs = len(result_subdirs) + len(other_subdirs)
    return {
        "n_photos": n_photos,
        "n_videos": n_videos,
        "n_csv": n_csv,
        "n_other_files": n_other,
        "n_subdirs": n_subdirs,
        "result_subdirs": sorted(result_subdirs),
        "other_subdirs": sorted(other_subdirs),
        "is_empty": (n_photos + n_videos + n_csv + n_other + n_subdirs) == 0,
    }


def pad_parts(parts: tuple[str, ...]) -> tuple[str, str, str, str, str, str, str]:
    """Map path parts onto the 7 logical slots (empty string when missing)."""
    slots = ["", "", "", "", "", "", ""]
    for i, part in enumerate(parts[:7]):
        slots[i] = part
    # If week is not at index 6, put the last part as week for reporting clarity
    if parts and is_week(parts[-1]):
        slots[6] = parts[-1]
    return tuple(slots)  # type: ignore[return-value]


def scan_data_lake(base: Path, processes: tuple[str, ...] = PRODUCTION_PROCESSES) -> dict:
    week_records: list[WeekRecord] = []
    shape_counts: Counter[str] = Counter()
    process_fruit_clients: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    ext_at_week: Counter[str] = Counter()
    subdir_under_week: Counter[str] = Counter()
    files_before_week: list[dict] = []
    empty_incomplete: list[str] = []
    ignored_nested_weeks = 0

    other_top_level = sorted(
        p.name for p in base.iterdir() if p.is_dir() and p.name not in processes
    )

    for proc in processes:
        root = base / proc
        if not root.exists():
            continue

        for dirpath, dirnames, filenames in os.walk(root):
            rel = Path(dirpath).relative_to(base)
            parts = rel.parts
            depth = len(parts)

            # Prune very deep trees (analysis artifacts under week)
            if depth > 9:
                dirnames[:] = []
                continue

            # Skip entire subtrees under analysis folders when looking for weeks
            # (still allow inspecting a real week folder that *contains* them).
            if has_result_ancestor(parts) and not is_week(parts[-1]):
                dirnames[:] = []
                continue

            # Incomplete empty branch (depth < 7, no children)
            if depth < 7 and not dirnames and not filenames and not is_week(parts[-1]):
                empty_incomplete.append(str(rel))

            # Files appearing before reaching a week folder
            if depth < 7 and filenames and not is_week(parts[-1]):
                if len(files_before_week) < 500:
                    files_before_week.append(
                        {
                            "path": str(rel),
                            "depth": depth,
                            "n_files": len(filenames),
                            "sample_files": filenames[:8],
                        }
                    )

            # Week folder
            if is_week(parts[-1]):
                # Nested under summary/detections/fine_tunning/... → ignore
                if has_result_ancestor(parts):
                    ignored_nested_weeks += 1
                    dirnames[:] = []
                    continue

                shape, is_good, reason = classify_shape(parts)
                shape_counts[shape] += 1
                content = inspect_week_dir(Path(dirpath))

                for f in filenames:
                    ext = Path(f).suffix.lower() or "(noext)"
                    ext_at_week[ext] += 1
                for sub in dirnames:
                    subdir_under_week[sub] += 1

                process, fruit, client, variety, block, campaign, week = pad_parts(parts)
                if fruit:
                    process_fruit_clients[process][fruit].add(client or "?")

                # Lack of media is only notable when the week is truly empty.
                # CSV / summary / detections / calibers are expected, not problems.
                if is_good and content["is_empty"]:
                    reason = "ok_path_but_empty"

                week_records.append(
                    WeekRecord(
                        path=str(rel),
                        process=process,
                        fruit=fruit,
                        client=client,
                        variety=variety,
                        block=block,
                        campaign=campaign,
                        week=week,
                        depth=depth,
                        shape=shape,
                        is_good=is_good,
                        reason=reason,
                        n_photos=content["n_photos"],
                        n_videos=content["n_videos"],
                        n_csv=content["n_csv"],
                        n_other_files=content["n_other_files"],
                        n_subdirs=content["n_subdirs"],
                        result_subdirs=content["result_subdirs"],
                        other_subdirs=content["other_subdirs"],
                        is_empty=content["is_empty"],
                    )
                )

                # Do not recurse into analysis children looking for more weeks
                dirnames[:] = [d for d in dirnames if not is_result_dir_name(d)]

    good = [r for r in week_records if r.is_good]
    bad = [r for r in week_records if not r.is_good]

    coverage = {
        proc: {
            fruit: sorted(clients)
            for fruit, clients in sorted(process_fruit_clients[proc].items())
        }
        for proc in processes
        if proc in process_fruit_clients
    }

    content_flags = {
        "has_photos": sum(1 for r in week_records if r.n_photos > 0),
        "has_videos": sum(1 for r in week_records if r.n_videos > 0),
        "has_csv": sum(1 for r in week_records if r.n_csv > 0),
        "has_result_subdirs": sum(1 for r in week_records if r.result_subdirs),
        "empty": sum(1 for r in week_records if r.is_empty),
    }

    return {
        "base": str(base),
        "scanned_at": datetime.now(timezone.utc).isoformat(),
        "production_processes": list(processes),
        "other_top_level": other_top_level,
        "total_week_folders": len(week_records),
        "good_count": len(good),
        "bad_count": len(bad),
        "ignored_nested_weeks": ignored_nested_weeks,
        "shape_counts": dict(shape_counts.most_common()),
        "content_flags": content_flags,
        "extensions_at_week": dict(ext_at_week.most_common()),
        "subdirs_under_week": dict(subdir_under_week.most_common(50)),
        "coverage": coverage,
        "files_before_week_count": len(files_before_week),
        "files_before_week_sample": files_before_week[:50],
        "empty_incomplete_branches": empty_incomplete,
        "good_paths": good,
        "bad_paths": bad,
        "all_weeks": week_records,
    }


def write_csv(path: Path, rows: list[WeekRecord]) -> None:
    fieldnames = [
        "path",
        "process",
        "fruit",
        "client",
        "variety",
        "block",
        "campaign",
        "week",
        "depth",
        "shape",
        "is_good",
        "reason",
        "n_photos",
        "n_videos",
        "n_csv",
        "n_other_files",
        "n_subdirs",
        "result_subdirs",
        "other_subdirs",
        "is_empty",
    ]
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            data = asdict(row)
            data["result_subdirs"] = "|".join(row.result_subdirs)
            data["other_subdirs"] = "|".join(row.other_subdirs)
            writer.writerow(data)


def format_summary(report: dict) -> str:
    lines: list[str] = []
    lines.append("=" * 72)
    lines.append("DATA_LAKE layout validation")
    lines.append("=" * 72)
    lines.append(f"Base:        {report['base']}")
    lines.append(f"Scanned at:  {report['scanned_at']}")
    lines.append(
        "Expected:    process/fruit/client/variety/block/cXXXX/wXX/"
    )
    lines.append(
        "  (campaign must be cYYYY; week must be wNN with exactly two digits)"
    )
    lines.append("")
    lines.append("Top-level")
    lines.append(f"  Production processes: {', '.join(report['production_processes'])}")
    lines.append(
        f"  Other (not validated): {', '.join(report['other_top_level']) or '(none)'}"
    )
    lines.append("")
    lines.append("Week folders")
    lines.append(f"  Total:  {report['total_week_folders']}")
    lines.append(f"  Good:   {report['good_count']}")
    lines.append(f"  Bad:    {report['bad_count']}")
    lines.append(
        f"  Ignored (nested under summary/detections/…): {report['ignored_nested_weeks']}"
    )
    lines.append("")
    lines.append("Shape breakdown")
    for shape, count in report["shape_counts"].items():
        lines.append(f"  {count:5d}  {shape}")
    lines.append("")
    lines.append("Content flags (at week folder level)")
    for key, value in report["content_flags"].items():
        lines.append(f"  {key}: {value}")
    lines.append("")
    lines.append("Top extensions directly in week folders")
    for ext, count in list(report["extensions_at_week"].items())[:15]:
        lines.append(f"  {ext}: {count}")
    lines.append("")
    lines.append("Top subdirs directly under week")
    for name, count in list(report["subdirs_under_week"].items())[:20]:
        lines.append(f"  {name}: {count}")
    lines.append("")
    lines.append("Coverage: process → fruit → clients")
    for proc, fruits in report["coverage"].items():
        lines.append(f"  [{proc}]")
        for fruit, clients in fruits.items():
            lines.append(f"    {fruit}: {', '.join(clients)}")
    lines.append("")
    lines.append(
        f"Files before reaching week (depth<7): {report['files_before_week_count']} paths"
    )
    lines.append(
        f"Empty incomplete branches: {len(report['empty_incomplete_branches'])}"
    )
    if report["empty_incomplete_branches"]:
        for p in report["empty_incomplete_branches"][:30]:
            lines.append(f"  {p}")
        remaining = len(report["empty_incomplete_branches"]) - 30
        if remaining > 0:
            lines.append(f"  ... and {remaining} more")
    lines.append("")
    lines.append("Sample bad paths")
    for row in report["bad_paths"][:25]:
        lines.append(f"  [{row.reason}] {row.path}")
    if report["bad_count"] > 25:
        lines.append(f"  ... and {report['bad_count'] - 25} more (see bad_paths.csv)")
    lines.append("")
    lines.append("Sample good paths")
    for row in report["good_paths"][:15]:
        extra = row.reason or "ok"
        lines.append(
            f"  [{extra}] photos={row.n_photos} videos={row.n_videos} "
            f"csv={row.n_csv} :: {row.path}"
        )
    if report["good_count"] > 15:
        lines.append(f"  ... and {report['good_count'] - 15} more (see good_paths.csv)")
    lines.append("")
    return "\n".join(lines)


def serialize_report(report: dict) -> dict:
    """JSON-safe copy (dataclasses → dicts)."""
    out = dict(report)
    for key in ("good_paths", "bad_paths", "all_weeks"):
        out[key] = [asdict(r) for r in report[key]]
    return out


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate DATA_LAKE folder hierarchy and export good/bad path lists."
    )
    parser.add_argument(
        "--base",
        type=Path,
        default=Path("/media/vindoo2/vindoo_disk/DATA_LAKE"),
        help="Path to DATA_LAKE root (default: /media/vindoo2/vindoo_disk/DATA_LAKE)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help=(
            "Directory for report files "
            "(default: <script_dir>/data_lake_report)"
        ),
    )
    parser.add_argument(
        "--processes",
        nargs="+",
        default=list(PRODUCTION_PROCESSES),
        help=f"Production process folders to validate (default: {' '.join(PRODUCTION_PROCESSES)})",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    base: Path = args.base.resolve()

    if not base.is_dir():
        print(f"ERROR: DATA_LAKE path does not exist or is not a directory: {base}", file=sys.stderr)
        return 1

    script_dir = Path(__file__).resolve().parent
    output_dir: Path = (args.output_dir or (script_dir / "data_lake_report")).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Scanning {base} ...", flush=True)
    report = scan_data_lake(base, processes=tuple(args.processes))

    summary_text = format_summary(report)
    (output_dir / "summary.txt").write_text(summary_text, encoding="utf-8")
    write_csv(output_dir / "good_paths.csv", report["good_paths"])
    write_csv(output_dir / "bad_paths.csv", report["bad_paths"])
    write_csv(output_dir / "week_inventory.csv", report["all_weeks"])
    (output_dir / "report.json").write_text(
        json.dumps(serialize_report(report), indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    print(summary_text)
    print(f"Wrote report to: {output_dir}")
    print("  - summary.txt")
    print("  - good_paths.csv")
    print("  - bad_paths.csv")
    print("  - week_inventory.csv")
    print("  - report.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
