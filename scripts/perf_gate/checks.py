"""Risk checks over Snowflake query plans.

Deliberately pure: every function here takes already-extracted plan data and returns findings.
No database connection, no filesystem, no dbt. That is what makes the check logic testable
against recorded plan JSON in tests/perf_gate/, which matters because these thresholds decide
whether a merge is blocked.

WHY THE CHECKS ASSERT ON MEASURED PLAN OUTPUT AND NEVER ON SQL TEXT. Measured against a
385-partition fixture, `DATE_TRUNC('day', event_ts) >= x` prunes to 22/385 — exactly as well as
the bare column, because DATE_TRUNC is monotonic and the optimiser can still use per-partition
min/max. `TO_CHAR(event_ts,'YYYY-MM-DD') >= '...'` scans all 385. A reviewer pattern-matching
"function wrapped around a column" flags both and is wrong about one of them.

That is the gate's whole reason for existing. Reading the SQL gives you a guess; reading the
plan gives you the number.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

# Check identifiers. Config refers to these by name, so renaming one is a breaking change to
# anybody's .perf-gate.yml.
CARTESIAN_JOIN = "cartesian_join"
UNPRUNED_LARGE_SCAN = "unpruned_large_scan"
MODEL_BYTES_CEILING = "model_bytes_ceiling"
MERGE_TARGET_UNPRUNED = "merge_target_unpruned"
FUNCTION_WRAPPED_JOIN_KEY = "function_wrapped_join_key"
HISTORICAL_SPILL = "historical_spill"
NOT_ANALYSABLE = "not_analysable"


@dataclass
class Finding:
    check: str
    model: str
    severity: str  # "blocking" | "advisory" | "suppressed" | "info"
    summary: str
    # Sort key for the PR comment. Bytes of the scan or plan the finding is about, so the
    # expensive things are argued about first.
    bytes_at_risk: int = 0
    evidence: dict[str, Any] = field(default_factory=dict)
    remedy: str = ""
    suppression_reason: str | None = None


@dataclass
class PlanFacts:
    """What we extracted from one EXPLAIN, plus the volumes of what it touched."""

    model: str
    kind: str  # "select" | "merge"
    partitions_assigned: int
    partitions_total: int
    bytes_assigned: int
    scans: list[
        dict[str, Any]
    ]  # object, partitions_assigned, partitions_total, bytes_assigned
    joins: list[dict[str, Any]]  # operation, expression
    has_merge: bool
    merge_target: str | None
    table_volumes: dict[
        str, dict[str, Any]
    ]  # object -> row_count, bytes, clustering_key
    history: dict[str, Any] | None
    explain_error: str | None = None


def _pct(assigned: int, total: int) -> float:
    return (assigned / total) if total else 0.0


def _is_function_wrapped(expression: str) -> bool:
    """Crude: does either side of the join key contain a call?

    Only ever used to ANNOTATE a finding already raised on measured pruning. On its own this is
    a guess — see the module docstring for why.
    """
    if "joinKey:" not in expression:
        return False
    return "(" in expression.split("joinKey:", 1)[1].replace("(", "", 1)


def evaluate(facts: PlanFacts, config: dict[str, Any]) -> list[Finding]:
    thresholds = config["thresholds"]
    findings: list[Finding] = []

    # A plan we could not obtain is reported, never treated as clean. Failing open silently is
    # how a gate becomes decoration.
    if facts.explain_error:
        return [
            Finding(
                check=NOT_ANALYSABLE,
                model=facts.model,
                severity="info",
                summary=f"Could not obtain a query plan: {facts.explain_error}",
                remedy="Check the CI role's SELECT privilege on the objects this model reads.",
            )
        ]

    # No TableScan at all is NOT the same as scanning nothing. `SELECT COUNT(*)` is answered
    # from metadata and returns 0/0 with no scan operator — and so does a predicate that prunes
    # every partition, so GlobalStats alone cannot tell them apart.
    if not facts.scans:
        return [
            Finding(
                check=NOT_ANALYSABLE,
                model=facts.model,
                severity="info",
                summary="Plan contains no table scan, so there is no scan volume to assess.",
                evidence={
                    "global": [facts.partitions_assigned, facts.partitions_total]
                },
            )
        ]

    findings += _check_cartesian(facts)
    findings += _check_unpruned_large_scans(facts, thresholds)
    findings += _check_model_ceiling(facts, thresholds)
    findings += _check_merge_target(facts, thresholds)
    findings += _check_history(facts)
    return findings


def _check_cartesian(facts: PlanFacts) -> list[Finding]:
    out = []
    for join in facts.joins:
        if join["operation"] != "CartesianJoin":
            continue
        out.append(
            Finding(
                check=CARTESIAN_JOIN,
                model=facts.model,
                severity="blocking",
                summary=(
                    "The optimiser resolved a join to a Cartesian product. Row count is the "
                    "product of both inputs, so cost grows multiplicatively with data volume."
                ),
                bytes_at_risk=facts.bytes_assigned,
                evidence={
                    "operator": "CartesianJoin",
                    "predicate": join.get("expression"),
                    "plan_bytes": facts.bytes_assigned,
                },
                remedy=(
                    "Give the join an equality condition. A non-equi predicate in the ON or "
                    "WHERE clause (>, <, BETWEEN, or a comparison between two columns) cannot "
                    "be used as a join key, so every row is compared against every row."
                ),
            )
        )
    return out


def _check_unpruned_large_scans(facts: PlanFacts, thresholds: dict) -> list[Finding]:
    out = []
    for scan in facts.scans:
        obj = scan["object"]
        # The merge target is assessed separately: an unbounded target scan has a different
        # cause and a different remedy from an unpruned source scan.
        if facts.merge_target and obj.upper() == facts.merge_target.upper():
            continue

        vol = facts.table_volumes.get(obj, {})
        table_bytes = vol.get("bytes") or 0
        if table_bytes < thresholds["large_table_bytes"]:
            continue

        ratio = _pct(scan["partitions_assigned"], scan["partitions_total"])
        if ratio < thresholds["unpruned_ratio"]:
            continue

        out.append(
            Finding(
                check=UNPRUNED_LARGE_SCAN,
                model=facts.model,
                severity="advisory",
                summary=(
                    f"{obj} is scanned almost in full: "
                    f"{scan['partitions_assigned']} of {scan['partitions_total']} micro-partitions "
                    f"({scan['bytes_assigned'] / 1e9:.2f} GB) from a "
                    f"{table_bytes / 1e9:.2f} GB table."
                ),
                bytes_at_risk=scan["bytes_assigned"],
                evidence={
                    "object": obj,
                    "partitions": [
                        scan["partitions_assigned"],
                        scan["partitions_total"],
                    ],
                    "scan_bytes": scan["bytes_assigned"],
                    "table_bytes": table_bytes,
                    "clustering_key": vol.get("clustering_key"),
                    "row_count": vol.get("row_count"),
                },
                remedy=(
                    "Add a predicate the optimiser can use to eliminate micro-partitions. It "
                    "must compare the column directly against a constant or a subquery — "
                    "wrapping it in a non-monotonic function such as TO_CHAR or a string cast "
                    "prevents pruning entirely, while a monotonic one such as DATE_TRUNC does "
                    "not. Note the estimate is an upper bound: runtime join pruning can reduce "
                    "the actual scan."
                ),
            )
        )
    return out


def _check_model_ceiling(facts: PlanFacts, thresholds: dict) -> list[Finding]:
    ceiling = thresholds["model_bytes_ceiling"]
    if facts.bytes_assigned < ceiling:
        return []
    return [
        Finding(
            check=MODEL_BYTES_CEILING,
            model=facts.model,
            severity="advisory",
            summary=(
                f"The plan for this model is estimated at {facts.bytes_assigned / 1e9:.2f} GB, "
                f"above the {ceiling / 1e9:.2f} GB ceiling."
            ),
            bytes_at_risk=facts.bytes_assigned,
            evidence={"plan_bytes": facts.bytes_assigned, "ceiling": ceiling},
            remedy="Reduce the scanned volume, or raise the ceiling in .perf-gate.yml if this size is expected.",
        )
    ]


def _check_merge_target(facts: PlanFacts, thresholds: dict) -> list[Finding]:
    """The check that justifies the gate.

    An incremental model can prune its SOURCE to a single micro-partition and still rescan its
    entire TARGET, because the merge condition is only `source.key = target.key`. Measured on
    the fixture: source 1/385, target 221/221 for 3.93 GB. The cost tracks the size of the
    target rather than the size of the increment, so it degrades as the table grows — which is
    the failure people describe as "it used to be fast".

    Invisible in the SELECT and invisible to code review.

    The figures come from a read-only semi-join probe rather than from the merge itself, because
    EXPLAIN requires the privileges to execute what it plans and the gate must not hold write
    access to production. Same numbers, no write grant. See gate.merge_target_probe.
    """
    if not facts.has_merge or not facts.merge_target:
        return []

    target_scans = [
        s for s in facts.scans if s["object"].upper() == facts.merge_target.upper()
    ]
    if not target_scans:
        return []
    scan = max(target_scans, key=lambda s: s["bytes_assigned"])

    ratio = _pct(scan["partitions_assigned"], scan["partitions_total"])
    if ratio < thresholds["merge_target_unpruned_ratio"]:
        return []

    return [
        Finding(
            check=MERGE_TARGET_UNPRUNED,
            model=facts.model,
            severity="advisory",
            summary=(
                f"The merge scans its own target in full: {scan['partitions_assigned']} of "
                f"{scan['partitions_total']} micro-partitions ({scan['bytes_assigned'] / 1e9:.2f} GB). "
                "This cost grows with the size of the target, not with the size of the increment."
            ),
            bytes_at_risk=scan["bytes_assigned"],
            evidence={
                "merge_target": facts.merge_target,
                "partitions": [scan["partitions_assigned"], scan["partitions_total"]],
                "target_scan_bytes": scan["bytes_assigned"],
            },
            remedy=(
                "Add `incremental_predicates` to the model config so the merge carries a "
                "predicate on the target side, for example "
                '["DBT_INTERNAL_DEST.event_ts >= dateadd(day, -7, current_date)"]. Without one, '
                "every run reads the whole target to find matches."
            ),
        )
    ]


def _check_history(facts: PlanFacts) -> list[Finding]:
    h = facts.history
    if not h:
        # Explicitly reported. "No baseline" is a different statement from "no regression", and
        # conflating them is how a brand-new model passes review for the wrong reason.
        return [
            Finding(
                check=HISTORICAL_SPILL,
                model=facts.model,
                severity="info",
                summary="No execution history for this model, so there is no baseline to compare against.",
            )
        ]

    remote = h.get("bytes_spilled_remote") or 0
    if remote <= 0:
        return []
    return [
        Finding(
            check=HISTORICAL_SPILL,
            model=facts.model,
            severity="advisory",
            summary=(
                f"This model has previously spilled {remote / 1e9:.2f} GB to remote storage. "
                "Remote spill is the signal that most reliably precedes a timeout."
            ),
            bytes_at_risk=remote,
            evidence=h,
            remedy=(
                "The working set exceeded local disk. Reduce the volume being sorted, joined or "
                "aggregated, or run this model on a larger warehouse."
            ),
        )
    ]


def apply_suppressions(
    findings: list[Finding], config: dict[str, Any]
) -> list[Finding]:
    """Demote suppressed findings rather than dropping them.

    A dropped finding is indistinguishable from one that never fired, which means a suppression
    silently stops being scrutinised. Keeping it and printing its reason means somebody has to
    look at it again the next time the file changes.
    """
    rules = config.get("suppressions") or []
    for rule in rules:
        if not rule.get("reason"):
            raise ValueError(
                f"Suppression for model={rule.get('model')} check={rule.get('check')} has no "
                "reason. A suppression without a stated reason is not permitted."
            )

    for finding in findings:
        for rule in rules:
            if (
                rule.get("model") == finding.model
                and rule.get("check") == finding.check
            ):
                finding.severity = "suppressed"
                finding.suppression_reason = rule["reason"]
                break
    return findings


def exit_code(findings: list[Finding], config: dict[str, Any]) -> int:
    """Non-zero only for an unsuppressed finding whose check is configured as blocking."""
    blocking = set(config.get("blocking") or [])
    return int(any(f.check in blocking and f.severity == "blocking" for f in findings))
