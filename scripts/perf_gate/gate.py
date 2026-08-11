"""Everything that talks to git, dbt artifacts, or Snowflake.

Kept apart from checks.py so the risk logic stays testable without a warehouse.
"""

from __future__ import annotations

import json
import re
import subprocess
import tomllib
from pathlib import Path
from typing import Any

import yaml

from .checks import PlanFacts

COMPILED_ROOT = Path("target/compiled")
MANIFEST = Path("target/manifest.json")

# dbt's own aliases inside a generated merge. Reused here so the probe's plan reads recognisably
# next to a dbt log.
DEST = "DBT_INTERNAL_DEST"
SRC = "DBT_INTERNAL_SOURCE"


def load_config(path: Path) -> dict[str, Any]:
    config = yaml.safe_load(path.read_text())
    if config.get("version") != 1:
        raise ValueError(
            f"{path}: unsupported config version {config.get('version')!r}"
        )
    return config


# -------------------------------------------------------------------------------------
# Which models does this diff actually affect
# -------------------------------------------------------------------------------------


def changed_sql_files(base_ref: str) -> list[Path]:
    """Model files touched relative to the merge base.

    Uses the merge base rather than the tip of the base branch, so unrelated commits landing on
    main while the PR is open do not appear as changes belonging to this PR.
    """
    merge_base = subprocess.run(
        ["git", "merge-base", "HEAD", base_ref],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    out = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=d", merge_base, "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return [Path(p) for p in out if p.startswith("models/") and p.endswith(".sql")]


def affected_models(
    manifest: dict[str, Any], changed: list[Path], depth: int
) -> list[str]:
    """Changed models plus their dependents, breadth-first to `depth`.

    Depth is bounded because a full transitive closure on a real project is dozens of EXPLAIN
    calls and a PR comment nobody reads.
    """
    by_path = {
        node["original_file_path"]: uid
        for uid, node in manifest["nodes"].items()
        if node["resource_type"] == "model"
    }
    frontier = {by_path[str(p)] for p in changed if str(p) in by_path}
    seen = set(frontier)

    children = manifest.get("child_map", {})
    for _ in range(depth):
        nxt = set()
        for uid in frontier:
            for child in children.get(uid, []):
                if child.startswith("model.") and child not in seen:
                    nxt.add(child)
        seen |= nxt
        frontier = nxt
        if not frontier:
            break
    return sorted(seen)


def compiled_sql(manifest: dict[str, Any], unique_id: str) -> str | None:
    node = manifest["nodes"][unique_id]
    path = COMPILED_ROOT / node["package_name"] / node["original_file_path"]
    if not path.exists():
        return None
    # Block comments carry the project's reasoning and are long. They compile fine but bloat the
    # artifact and the prompt, so they go.
    return (
        re.sub(r"/\*.*?\*/", "", path.read_text(), flags=re.DOTALL).strip().rstrip(";")
    )


# -------------------------------------------------------------------------------------
# Snowflake
# -------------------------------------------------------------------------------------


def connect(connection_name: str | None = None):
    import snowflake.connector

    cfg_path = Path.home() / ".snowflake" / "connections.toml"
    cfg = tomllib.loads(cfg_path.read_text())
    name = (
        connection_name
        or cfg.get("default_connection_name")
        or next(k for k, v in cfg.items() if isinstance(v, dict))
    )
    return snowflake.connector.connect(**cfg[name])


def explain(cur, sql: str) -> tuple[dict[str, Any] | None, str | None]:
    """Compile a statement and return its plan. Never executes it.

    EXPLAIN needs no running warehouse and consumes cloud-services credits only, which is what
    makes this affordable on a project whose build is not.
    """
    try:
        cur.execute("EXPLAIN USING JSON " + sql)
        return json.loads(cur.fetchone()[0]), None
    except Exception as exc:  # noqa: BLE001 - the message is the finding
        return None, str(exc).strip().splitlines()[0]


def merge_target_probe(
    select_sql: str, target: str, unique_key: str | list[str]
) -> str:
    """A READ-ONLY statement that plans the same target-side work the merge will do.

    WHY NOT JUST EXPLAIN THE MERGE. EXPLAIN requires the privileges needed to EXECUTE the
    statement, so planning a `MERGE INTO production_table` needs INSERT and UPDATE on it. That
    would mean granting CI write access to production to run a read-only check, which is exactly
    backwards. Verified: with secondary roles disabled, as in CI, EXPLAIN of the merge fails with
    `003001 (42501): SQL access control error`.

    So the target-side read is expressed as a semi-join instead, which is the work the merge does
    internally to find its matches. It needs only SELECT, and it reports the same numbers —
    measured on the fixture, both formulations return a target scan of 221/221 partitions and
    3.93 GB.

    STILL AN APPROXIMATION, and worth being honest about. dbt generates the real merge in its
    materialization macro at run time, so it never appears in target/compiled/ — compilation emits
    only the model's SELECT. This is a faithful model of the target-side scan, not the statement
    dbt will actually run.
    """
    keys = [unique_key] if isinstance(unique_key, str) else list(unique_key)
    match = " AND ".join(f"{DEST}.{k} = {SRC}.{k}" for k in keys)
    projection = ", ".join(f"{DEST}.{k}" for k in keys)
    return (
        f"SELECT {projection}\n"
        f"FROM {target} {DEST}\n"
        f"JOIN (\n{select_sql}\n) {SRC}\n"
        f"  ON {match}"
    )


def parse_plan(plan: dict[str, Any]) -> dict[str, Any]:
    g = plan.get("GlobalStats", {})
    ops = plan.get("Operations", [[]])[0]

    scans, joins, merge_target = [], [], None
    for op in ops:
        kind = op.get("operation", "")
        if kind == "TableScan":
            scans.append(
                {
                    "object": op["objects"][0],
                    "partitions_assigned": op.get("partitionsAssigned", 0),
                    "partitions_total": op.get("partitionsTotal", 0),
                    "bytes_assigned": op.get("bytesAssigned", 0),
                    "columns": op.get("expressions", []),
                }
            )
        elif "Join" in kind:
            joins.append(
                {"operation": kind, "expression": "; ".join(op.get("expressions", []))}
            )
        elif kind == "Merge":
            merge_target = (op.get("objects") or [None])[0]

    return {
        "partitions_assigned": g.get("partitionsAssigned", 0),
        "partitions_total": g.get("partitionsTotal", 0),
        "bytes_assigned": g.get("bytesAssigned", 0),
        "scans": scans,
        "joins": joins,
        "has_merge": merge_target is not None,
        "merge_target": merge_target,
    }


def table_volumes(cur, objects: set[str]) -> dict[str, dict[str, Any]]:
    """Row counts, bytes and clustering keys, straight from INFORMATION_SCHEMA.

    Metadata only, so no data is read and no warehouse work is done. This is the context that
    turns a plan into a judgement: 385 partitions scanned matters at 7 GB and not at 7 MB.
    """
    out: dict[str, dict[str, Any]] = {}
    by_db: dict[str, list[tuple[str, str]]] = {}
    for obj in objects:
        parts = obj.split(".")
        if len(parts) != 3:
            continue
        by_db.setdefault(parts[0], []).append((parts[1], parts[2]))

    for db, pairs in by_db.items():
        predicate = " OR ".join(
            f"(table_schema = '{s}' AND table_name = '{t}')" for s, t in pairs
        )
        try:
            cur.execute(
                f"""SELECT table_schema, table_name, row_count, bytes, clustering_key, last_altered
                    FROM {db}.INFORMATION_SCHEMA.TABLES WHERE {predicate}"""
            )
        except Exception:  # noqa: BLE001 - a missing grant degrades, it does not fail the build
            continue
        for schema, table, rows, size, clustering, altered in cur.fetchall():
            out[f"{db}.{schema}.{table}"] = {
                "row_count": rows,
                "bytes": size,
                "clustering_key": clustering,
                "last_altered": str(altered) if altered else None,
            }
    return out


def model_history(cur, model_names: list[str], days: int) -> dict[str, dict[str, Any]]:
    """Historical cost per model, correlated through dbt's query comment.

    ACCOUNT_USAGE lags by up to ~45 minutes. That is fine for "what did this cost historically"
    and useless for "what did this run just do", so it is never used for the latter. A missing
    grant or an empty result yields no baseline, which is reported as such rather than treated
    as a pass.
    """
    if not model_names:
        return {}
    likes = " OR ".join(f"query_text ILIKE '%{n}%'" for n in model_names)
    sql = f"""
        SELECT
            REGEXP_SUBSTR(query_text, '({"|".join(model_names)})') AS model,
            COUNT(*)                                              AS runs,
            MEDIAN(total_elapsed_time)                            AS median_ms,
            MAX(bytes_scanned)                                    AS max_bytes_scanned,
            MAX(partitions_scanned)                               AS max_partitions_scanned,
            MAX(bytes_spilled_to_local_storage)                   AS bytes_spilled_local,
            MAX(bytes_spilled_to_remote_storage)                  AS bytes_spilled_remote
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE start_time >= DATEADD(day, -{days}, CURRENT_TIMESTAMP())
          AND execution_status = 'SUCCESS'
          AND ({likes})
        GROUP BY 1
    """
    try:
        cur.execute(sql)
    except Exception:  # noqa: BLE001 - no IMPORTED PRIVILEGES means no baseline, not a failure
        return {}
    cols = [
        "model",
        "runs",
        "median_ms",
        "max_bytes_scanned",
        "max_partitions_scanned",
        "bytes_spilled_local",
        "bytes_spilled_remote",
    ]
    return {row[0]: dict(zip(cols[1:], row[1:])) for row in cur.fetchall() if row[0]}


def build_facts(
    cur,
    manifest: dict[str, Any],
    unique_id: str,
    config: dict[str, Any],
    history: dict[str, dict[str, Any]],
) -> list[PlanFacts]:
    """Plan one model: its SELECT always, plus a read-only merge-target probe when incremental."""
    node = manifest["nodes"][unique_id]
    name = node["name"]
    sql = compiled_sql(manifest, unique_id)
    if sql is None:
        return [
            PlanFacts(
                model=name,
                kind="select",
                partitions_assigned=0,
                partitions_total=0,
                bytes_assigned=0,
                scans=[],
                joins=[],
                has_merge=False,
                merge_target=None,
                table_volumes={},
                history=history.get(name),
                explain_error="no compiled artifact - was `dbt compile` run for this model?",
            )
        ]

    out: list[PlanFacts] = []
    statements: list[tuple[str, str, str | None]] = [("select", sql, None)]

    cfg = node.get("config", {})
    if cfg.get("materialized") == "incremental" and cfg.get("unique_key"):
        target = node["relation_name"]
        statements.append(
            ("merge_probe", merge_target_probe(sql, target, cfg["unique_key"]), target)
        )

    for kind, statement, probe_target in statements:
        plan, error = explain(cur, statement)
        if error:
            out.append(
                PlanFacts(
                    model=name,
                    kind=kind,
                    partitions_assigned=0,
                    partitions_total=0,
                    bytes_assigned=0,
                    scans=[],
                    joins=[],
                    has_merge=False,
                    merge_target=None,
                    table_volumes={},
                    history=history.get(name),
                    explain_error=error,
                )
            )
            continue
        parsed = parse_plan(plan)
        # The probe is a SELECT, so there is no Merge operator to read the target from. It comes
        # from the manifest instead, and stating it explicitly is what lets the merge-target check
        # tell the target scan apart from the source scan.
        if probe_target:
            parsed["merge_target"] = probe_target
            parsed["has_merge"] = True
        volumes = table_volumes(cur, {s["object"] for s in parsed["scans"]})
        out.append(
            PlanFacts(
                model=name,
                kind=kind,
                table_volumes=volumes,
                history=history.get(name),
                **parsed,
            )
        )
    return out
