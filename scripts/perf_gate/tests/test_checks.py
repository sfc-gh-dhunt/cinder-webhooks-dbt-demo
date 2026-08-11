"""Check logic tests, run without a warehouse.

The plan fragments below are TRIMMED FROM REAL `EXPLAIN USING JSON` OUTPUT against this account,
not invented. That matters: these thresholds decide whether a merge is blocked, and a test built
on a guessed plan shape would pass while the gate misread production.

Recorded against:
  CINDER_RAW.FIXTURE.JOB_EVENTS_VOLUME              50M rows, 385 partitions, 7.36 GB
  CINDER_ANALYTICS.PERF_FIXTURE.FCT_JOB_EVENTS...   221 partitions, 3.93 GB
  SNOWFLAKE_SAMPLE_DATA.TPCH_SF1000.{ORDERS,CUSTOMER}  for the cartesian case
"""

from __future__ import annotations

from pathlib import Path
import sys

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from scripts.perf_gate import checks  # noqa: E402

CONFIG = yaml.safe_load(Path(".perf-gate.yml").read_text())

VOLUME = "CINDER_RAW.FIXTURE.JOB_EVENTS_VOLUME"
TARGET = "CINDER_ANALYTICS.PERF_FIXTURE.FCT_JOB_EVENTS_INCREMENTAL"

BIG = {
    VOLUME: {"row_count": 50_000_000, "bytes": 7_356_743_680, "clustering_key": None}
}
BOTH = {
    **BIG,
    TARGET: {"row_count": 50_000_000, "bytes": 3_929_133_568, "clustering_key": None},
}


def facts(**kw) -> checks.PlanFacts:
    base = dict(
        model="m",
        kind="select",
        partitions_assigned=0,
        partitions_total=0,
        bytes_assigned=0,
        scans=[],
        joins=[],
        has_merge=False,
        merge_target=None,
        table_volumes={},
        history={"bytes_spilled_remote": 0},
    )
    base.update(kw)
    return checks.PlanFacts(**base)


def scan(obj, assigned, total, size):
    return {
        "object": obj,
        "partitions_assigned": assigned,
        "partitions_total": total,
        "bytes_assigned": size,
        "columns": [],
    }


def names(findings):
    return {f.check for f in findings}


# -------------------------------------------------------------------------------------
# The one hard blocker
# -------------------------------------------------------------------------------------


def test_cartesian_join_blocks():
    f = facts(
        bytes_assigned=63_096_938_496,
        scans=[scan(VOLUME, 385, 385, 7_356_743_680)],
        joins=[
            {
                "operation": "CartesianJoin",
                "expression": "joinFilter: O.O_TOTALPRICE > C.C_ACCTBAL",
            }
        ],
        table_volumes=BIG,
    )
    found = checks.evaluate(f, CONFIG)
    cartesian = [x for x in found if x.check == checks.CARTESIAN_JOIN]
    assert len(cartesian) == 1
    assert cartesian[0].severity == "blocking"
    assert checks.exit_code(found, CONFIG) == 1


def test_inner_join_does_not_block():
    f = facts(
        bytes_assigned=1_000_000,
        scans=[scan(VOLUME, 1, 385, 2_829_824)],
        joins=[{"operation": "InnerJoin", "expression": "joinKey: (A.ID = B.ID)"}],
        table_volumes=BIG,
    )
    found = checks.evaluate(f, CONFIG)
    assert checks.CARTESIAN_JOIN not in names(found)
    assert checks.exit_code(found, CONFIG) == 0


# -------------------------------------------------------------------------------------
# Pruning, and the volume context that makes it meaningful
# -------------------------------------------------------------------------------------


def test_unpruned_scan_of_large_table_is_advisory_not_blocking():
    """Advisory on purpose. partitionsAssigned is an upper-bound estimate, so blocking on it
    would fail merges the author cannot clear without running the query."""
    f = facts(scans=[scan(VOLUME, 385, 385, 7_356_743_680)], table_volumes=BIG)
    found = checks.evaluate(f, CONFIG)
    hits = [x for x in found if x.check == checks.UNPRUNED_LARGE_SCAN]
    assert len(hits) == 1
    assert hits[0].severity == "advisory"
    assert checks.exit_code(found, CONFIG) == 0


def test_well_pruned_scan_is_silent():
    f = facts(scans=[scan(VOLUME, 1, 385, 2_829_824)], table_volumes=BIG)
    assert checks.UNPRUNED_LARGE_SCAN not in names(checks.evaluate(f, CONFIG))


def test_full_scan_of_a_small_table_is_silent():
    """The demo's seeded tables are kilobytes. A full scan of one is free, and reporting it on
    every model would bury the findings that matter."""
    small = "CINDER_ANALYTICS.SEEDS.SEED_CINDER_JOB_ACTIONED"
    f = facts(
        scans=[scan(small, 1, 1, 21_504)],
        table_volumes={
            small: {"row_count": 500, "bytes": 21_504, "clustering_key": None}
        },
    )
    assert checks.UNPRUNED_LARGE_SCAN not in names(checks.evaluate(f, CONFIG))


# -------------------------------------------------------------------------------------
# The merge-target check: the case that justifies the gate
# -------------------------------------------------------------------------------------


def test_merge_target_full_scan_is_reported_even_when_source_prunes_perfectly():
    """The real measured case. Source pruned to 1 of 385 partitions - the model looks efficient
    by every text-visible measure - while the merge reads its whole 3.93 GB target."""
    f = facts(
        kind="merge",
        has_merge=True,
        merge_target=TARGET,
        bytes_assigned=3_929_133_568,
        scans=[scan(VOLUME, 1, 385, 2_829_824), scan(TARGET, 221, 221, 3_929_133_568)],
        table_volumes=BOTH,
    )
    found = checks.evaluate(f, CONFIG)
    hits = [x for x in found if x.check == checks.MERGE_TARGET_UNPRUNED]
    assert len(hits) == 1
    assert "incremental_predicates" in hits[0].remedy
    # Not double-reported as a generic unpruned scan: different cause, different remedy.
    assert checks.UNPRUNED_LARGE_SCAN not in names(found)


def test_merge_target_that_prunes_is_silent():
    f = facts(
        kind="merge",
        has_merge=True,
        merge_target=TARGET,
        scans=[scan(VOLUME, 1, 385, 2_829_824), scan(TARGET, 4, 221, 70_000_000)],
        table_volumes=BOTH,
    )
    assert checks.MERGE_TARGET_UNPRUNED not in names(checks.evaluate(f, CONFIG))


# -------------------------------------------------------------------------------------
# Plans that cannot be judged must say so, never pass quietly
# -------------------------------------------------------------------------------------


def test_plan_with_no_table_scan_is_not_analysable():
    """SELECT COUNT(*) is answered from metadata: 0/0 and no scan operator. A predicate that
    prunes every partition also returns 0/0, so GlobalStats alone cannot separate them."""
    found = checks.evaluate(facts(scans=[]), CONFIG)
    assert names(found) == {checks.NOT_ANALYSABLE}
    assert checks.exit_code(found, CONFIG) == 0


def test_explain_failure_is_reported_and_does_not_block():
    found = checks.evaluate(
        facts(
            explain_error="SQL compilation error: Object does not exist or not authorized"
        ),
        CONFIG,
    )
    assert names(found) == {checks.NOT_ANALYSABLE}
    assert checks.exit_code(found, CONFIG) == 0


def test_missing_history_is_reported_as_no_baseline():
    found = checks.evaluate(
        facts(scans=[scan(VOLUME, 1, 385, 100)], table_volumes=BIG, history=None),
        CONFIG,
    )
    hits = [x for x in found if x.check == checks.HISTORICAL_SPILL]
    assert hits and hits[0].severity == "info"
    assert "no baseline" in hits[0].summary.lower()


def test_historical_remote_spill_is_advisory():
    found = checks.evaluate(
        facts(
            scans=[scan(VOLUME, 1, 385, 100)],
            table_volumes=BIG,
            history={"bytes_spilled_remote": 12_000_000_000, "runs": 9},
        ),
        CONFIG,
    )
    hits = [x for x in found if x.check == checks.HISTORICAL_SPILL]
    assert hits and hits[0].severity == "advisory"


# -------------------------------------------------------------------------------------
# Suppression: visible, reasoned, and it clears the exit code
# -------------------------------------------------------------------------------------


def test_suppression_demotes_a_blocker_and_keeps_its_reason():
    config = dict(CONFIG)
    config["suppressions"] = [
        {
            "model": "m",
            "check": checks.CARTESIAN_JOIN,
            "reason": "Cross join against a 400-row calendar seed. Bounded by construction.",
        }
    ]
    found = checks.evaluate(
        facts(
            joins=[{"operation": "CartesianJoin", "expression": "joinFilter: x > y"}],
            scans=[scan(VOLUME, 385, 385, 7_356_743_680)],
            table_volumes=BIG,
        ),
        config,
    )
    found = checks.apply_suppressions(found, config)
    cartesian = [x for x in found if x.check == checks.CARTESIAN_JOIN][0]
    assert cartesian.severity == "suppressed"
    assert "calendar seed" in cartesian.suppression_reason
    # Still present, so it stays in the comment and keeps being looked at.
    assert checks.exit_code(found, config) == 0


def test_suppression_without_a_reason_is_rejected():
    config = dict(CONFIG)
    config["suppressions"] = [{"model": "m", "check": checks.CARTESIAN_JOIN}]
    with pytest.raises(ValueError, match="no\nreason|no reason"):
        checks.apply_suppressions([], config)
