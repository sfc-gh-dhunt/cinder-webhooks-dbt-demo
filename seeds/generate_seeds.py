#!/usr/bin/env python3
"""
Generate the synthetic webhook seed files.

WHY A GENERATOR
---------------
Each seed row carries a whole JSON webhook payload in one CSV column. Hand-writing that
means hand-escaping quotes inside quoted CSV fields, which is precisely the sort of thing
that produces a file that looks fine, loads fine, and is subtly corrupt. The generator
removes that class of error and makes the edge cases explicit and reviewable.

The generated CSVs ARE committed — you do not need Python to use this project. This script
is here so the seed data is reproducible and so it is obvious what the edge cases are and
why each one exists.

    python3 seeds/generate_seeds.py

DETERMINISM
-----------
Fixed random seed and a fixed anchor date, so regenerating produces byte-identical files.
CI can therefore assert that the committed seeds match the generator.

ALL DATA IS SYNTHETIC
---------------------
Invented usernames, example.com addresses, lorem-style content. No real people, no real
handles, no real moderation content.
"""

from __future__ import annotations

import csv
import json
import random
from datetime import datetime, timedelta, timezone
from pathlib import Path

SEED_DIR = Path(__file__).parent / "cinder"
RANDOM_SEED = 20260801

# All timestamps are generated relative to this anchor rather than to "now", so the seed
# files are stable across regenerations and across machines.
ANCHOR = datetime(2026, 7, 31, 18, 0, 0, tzinfo=timezone.utc)
WINDOW_DAYS = 30

rng = random.Random(RANDOM_SEED)

# -------------------------------------------------------------------------------------
# Reference data
# -------------------------------------------------------------------------------------

QUEUES = [
    {"slug": "flagged-text", "is_multi_review": False},
    {"slug": "flagged-images", "is_multi_review": False},
    {"slug": "user-reports", "is_multi_review": False},
    {"slug": "escalations", "is_multi_review": True},
    {"slug": "high-harm-review", "is_multi_review": True},
]

POLICIES = [
    {
        "id": "09049cc6-ddf9-47fe-b6ff-1d266a3aad7d",
        "name": "Threats of Violence",
        "customer_ref": "internal-policy-101",
        "is_illegal": True,
        "is_non_violating": False,
    },
    {
        "id": "1a2b3c4d-1111-4444-8888-aaaabbbbcccc",
        "name": "Harassment - Severe",
        "customer_ref": "internal-policy-102",
        "is_illegal": False,
        "is_non_violating": False,
    },
    {
        "id": "2b3c4d5e-2222-4444-8888-bbbbccccdddd",
        "name": "Harassment - Mild",
        # Deliberately null: customer_ref is optional and a real policy tree will have
        # gaps. Anything downstream that assumes it is populated should fail a test here.
        "customer_ref": None,
        "is_illegal": False,
        "is_non_violating": False,
    },
    {
        "id": "3c4d5e6f-3333-4444-8888-ccccddddeeee",
        "name": "Adult Nudity",
        "customer_ref": "internal-policy-104",
        "is_illegal": False,
        "is_non_violating": False,
    },
    {
        "id": "4d5e6f70-4444-4444-8888-ddddeeeeffff",
        "name": "Self-Harm and Suicide",
        "customer_ref": "internal-policy-105",
        "is_illegal": True,
        "is_non_violating": False,
    },
    {
        "id": "5e6f7081-5555-4444-8888-eeeeffff0000",
        "name": "Spam and Inauthentic Behaviour",
        "customer_ref": "internal-policy-106",
        "is_illegal": False,
        "is_non_violating": False,
    },
    {
        # A non-violating policy: used to record a reviewed-and-cleared outcome. Metrics
        # that count "decisions with a policy" as "violations" get this wrong.
        "id": "6f708192-6666-4444-8888-ffff00001111",
        "name": "Reviewed - No Violation",
        "customer_ref": "internal-policy-107",
        "is_illegal": False,
        "is_non_violating": True,
    },
]

ENFORCEMENT_ACTIONS = [
    "ban_user",
    "warn_user",
    "remove_content",
    "restrict_account",
    "shadow_ban",
    "no_action",
]

REVIEWERS = [
    {"name": "Ada Okafor", "email": "a.okafor@example.com", "groups": ["Everyone", "Reviewers"]},
    {"name": "Bruno Silva", "email": "b.silva@example.com", "groups": ["Everyone", "Reviewers"]},
    {"name": "Chen Wei", "email": "c.wei@example.com", "groups": ["Everyone", "Reviewers", "Escalation Team"]},
    {"name": "Dara Novak", "email": "d.novak@example.com", "groups": ["Everyone", "QA"]},
    {"name": "Elif Demir", "email": "e.demir@example.com", "groups": ["Everyone", "Admin", "Workflow Admins"]},
]

WORKFLOWS = [
    {
        "id": "efca2fc6-4a74-47b4-915b-582ccb181d18",
        "name": "Auto-escalate high harm",
        "rule": {"id": "4ce7b5c8-aa85-4082-9bd1-89e1833896a2", "name": "High harm classifier over threshold"},
        "trigger_type": "ENTITY_CREATED",
    },
    {
        "id": "7a8b9c0d-7777-4444-8888-111122223333",
        "name": "Close related jobs on decision",
        "rule": {"id": "8b9c0d1e-8888-4444-8888-222233334444", "name": "Duplicate report suppression"},
        "trigger_type": "DECISION_CREATED",
    },
]

# Entity attribute bags differ by schema — that is the whole point of keeping them as a
# VARIANT rather than flattening to a fixed set of columns. 'audio_clip' is included as a
# schema the models have never seen, to prove they do not break on an unfamiliar one.
ENTITY_SCHEMAS = ["user", "text_post", "image_post", "audio_clip"]

WORDS = (
    "market season figure record listen society practice ready stage moment reason "
    "signal window pattern silver quiet garden matter travel bridge candle harvest"
).split()


def lorem(n: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(n)).capitalize() + "."


def iso(dt: datetime) -> str:
    """Event time: ISO 8601, microseconds, explicit offset — as Cinder emits it."""
    return dt.isoformat()


def iso_zulu(dt: datetime) -> str:
    """The other documented shape: Zulu, no fractional seconds. Both must parse."""
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def import_ts(dt: datetime) -> str:
    """
    Ingestion timestamp as the ingestion layer writes it: naive wall-clock, second
    resolution, no offset. Always a little after event time.
    """
    return (dt + timedelta(seconds=rng.randint(1, 90))).strftime("%Y-%m-%d %H:%M:%S")


def random_dt() -> datetime:
    return ANCHOR - timedelta(
        days=rng.randint(0, WINDOW_DAYS - 1),
        hours=rng.randint(0, 23),
        minutes=rng.randint(0, 59),
        seconds=rng.randint(0, 59),
        microseconds=rng.randint(0, 999999),
    )


def make_entity(schema: str, entity_id: str) -> dict:
    if schema == "user":
        attrs = {
            "id": entity_id,
            "email": f"user{rng.randint(100, 999)}@example.net",
            "username": f"{rng.choice(WORDS)}{rng.randint(10, 99)}",
            "first_name": rng.choice(["Sam", "Noor", "Ola", "Ines", "Tomas", "Kai"]),
            "last_name": rng.choice(["Hall", "Bell", "Moore", "Ferrer", "Adeyemi", "Novak"]),
            "account_age_days": rng.randint(1, 2000),
        }
    elif schema == "text_post":
        attrs = {
            "id": entity_id,
            "caption": lorem(rng.randint(6, 14)),
            "created": iso_zulu(random_dt()),
            "object_url": f"https://example.com/post/{entity_id}",
        }
    elif schema == "image_post":
        attrs = {
            "id": entity_id,
            "caption": lorem(rng.randint(4, 10)),
            "created": iso_zulu(random_dt()),
            "object_url": f"https://example.com/image/{entity_id}",
            "media_count": rng.randint(1, 4),
        }
    else:  # audio_clip — intentionally unlike the others
        attrs = {
            "id": entity_id,
            "duration_seconds": rng.randint(3, 240),
            "transcript_available": rng.choice([True, False]),
            "object_url": f"https://example.com/audio/{entity_id}",
        }
    return {"entity_schema": schema, "attributes": attrs}


def hexid(n: int = 8) -> str:
    return "".join(rng.choice("0123456789abcdef") for _ in range(n))


def uuid_like() -> str:
    return f"{hexid(8)}-{hexid(4)}-4{hexid(3)}-8{hexid(3)}-{hexid(12)}"


# -------------------------------------------------------------------------------------
# Job pool — shared by all three events so referential integrity actually holds
# -------------------------------------------------------------------------------------

JOB_CATEGORIES_ACTIONED = ["standard", "appeal", "qa", "golden"]
# job.closed documents a wider enum than job.actioned, including these two extra values.
JOB_CATEGORIES_CLOSED = JOB_CATEGORIES_ACTIONED + ["training", "multi_review"]


def build_jobs(n: int) -> list[dict]:
    jobs = []
    for _ in range(n):
        schema = rng.choices(ENTITY_SCHEMAS, weights=[40, 35, 20, 5])[0]
        created = random_dt()
        jobs.append(
            {
                "id": uuid_like(),
                "queue": rng.choice(QUEUES),
                "entity": make_entity(schema, hexid(8)),
                "created_at": created,
                "category": rng.choices(JOB_CATEGORIES_CLOSED, weights=[70, 10, 8, 4, 4, 4])[0],
                "num_reports": rng.randint(1, 9),
                "priority": rng.choice([0, 0, 0, 1, 2]),
            }
        )
    return jobs


JOBS = build_jobs(45)


# -------------------------------------------------------------------------------------
# job.actioned
# -------------------------------------------------------------------------------------

ACTIONS_BY_SOURCE = {
    "manual": ["skipped", "changed_queue", "escalated", "returned", "deferred", "assigned", "commented"],
    "workflow": ["changed_queue", "cancelled", "escalated"],
    "auto": ["escalated", "deferred"],
    "api": ["changed_queue", "cancelled"],
    "agent": ["skipped", "deferred"],
}

STATUS_AFTER = {
    "skipped": "open",
    "changed_queue": "open",
    "escalated": "open",
    "returned": "open",
    "deferred": "deferred",
    "assigned": "open",
    "commented": "open",
    "cancelled": "cancelled",
    "paused": "paused",
    "resumed": "open",
}


def job_actioned_rows() -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []

    for _ in range(34):
        job = rng.choice(JOBS)
        source = rng.choices(list(ACTIONS_BY_SOURCE), weights=[55, 20, 10, 10, 5])[0]
        action = rng.choice(ACTIONS_BY_SOURCE[source])
        ts = job["created_at"] + timedelta(minutes=rng.randint(1, 4000))
        if ts > ANCHOR:
            ts = ANCHOR - timedelta(minutes=rng.randint(1, 600))

        if source == "manual":
            reviewer = rng.choice(REVIEWERS)
            made_by = {
                "user": {
                    "name": reviewer["name"],
                    "email": reviewer["email"],
                    "groups": [{"name": g} for g in reviewer["groups"]],
                }
            }
            # An empty note is normal and must not be confused with a missing one.
            notes = rng.choice([lorem(rng.randint(2, 6)), "", "", "wrong queue"])
        elif source == "workflow":
            wf = rng.choice(WORKFLOWS)
            trigger_schema = rng.choice(["user", "text_post"])
            made_by = {
                "workflow": {
                    "id": wf["id"],
                    "name": wf["name"],
                    "rule": wf["rule"],
                    "event": {
                        # The entity that TRIGGERED the workflow, which can differ from the
                        # entity the action was taken on. Conflating the two is a real
                        # modelling trap.
                        "entity": make_entity(trigger_schema, hexid(8)),
                        "event_name": rng.choice(["CLOSE_RELATED_JOBS", "SEND_TO_QUEUE", "ESCALATE"]),
                    },
                    "trigger_type": wf["trigger_type"],
                }
            }
            notes = ""
        else:
            # auto / api / agent carry neither a user nor a workflow.
            made_by = {}
            notes = ""

        payload = {
            "job": {
                "id": job["id"],
                "queue": job["queue"],
                "entity": job["entity"],
                "status": STATUS_AFTER.get(action, "open"),
                "priority": job["priority"],
                "num_reports": job["num_reports"],
                "job_category": job["category"]
                if job["category"] in JOB_CATEGORIES_ACTIONED
                else "standard",
            },
            "notes": notes,
            "action": action,
            "source": source,
            "timestamp": iso(ts),
            "action_made_by": made_by,
        }
        rows.append(("job.actioned", json.dumps(payload, sort_keys=True), import_ts(ts)))

    # ---- Edge case: duplicate delivery -------------------------------------------
    # Identical payload, later ingestion timestamp. Deduplication must collapse this to
    # one row; if the dedup key included import_ts it would not.
    rows.append((rows[0][0], rows[0][1], import_ts(ANCHOR - timedelta(minutes=5))))

    return rows


# -------------------------------------------------------------------------------------
# decision.created
# -------------------------------------------------------------------------------------

DECISION_TYPES = [
    "queue_review",
    "automated",
    "cinder_workflow",
    "agent",
    "manual",
    "investigate_review",
    "bulk_action",
    "api_decision",
    "manual_override",
    "qa",
    "qa_override",
]
AUTOMATED_TYPES = {"automated", "cinder_workflow", "agent", "bulk_action", "api_decision"}


def make_decision_payload(job: dict, dtype: str, ts: datetime, *, with_extras: bool = True) -> dict:
    n_policies = rng.choices([1, 1, 1, 2, 3], weights=[50, 20, 10, 15, 5])[0]
    policies = rng.sample(POLICIES, n_policies)
    non_violating = all(p["is_non_violating"] for p in policies)

    if non_violating:
        actions = ["no_action"]
    else:
        actions = rng.sample([a for a in ENFORCEMENT_ACTIONS if a != "no_action"], rng.randint(1, 2))

    entity = job["entity"]

    payload: dict = {
        "enforcement_actions": actions,
        "enforcement_actions_removed": [],
        "entity": dict(entity),
        "timestamp": iso(ts),
        "policies": [
            {
                "id": p["id"],
                "name": p["name"],
                "customer_ref": p["customer_ref"],
                "is_illegal": p["is_illegal"],
                "is_non_violating": p["is_non_violating"],
            }
            for p in policies
        ],
        "policies_removed": [],
        "notes": rng.choice([lorem(rng.randint(3, 9)), "", ""]),
        "source": {
            "decision": {"id": uuid_like(), "type": dtype, "metadata": {}},
            "job": {
                "id": job["id"],
                "created_at": iso(job["created_at"]),
                "reports": [],
                "queue": job["queue"],
            },
        },
    }

    # Human decisions carry a user; automated ones do not. Anything computing reviewer
    # productivity has to handle the absence rather than assume a name is always there.
    if dtype not in AUTOMATED_TYPES:
        reviewer = rng.choice(REVIEWERS)
        payload["source"]["user"] = {
            "name": reviewer["name"],
            "email": reviewer["email"],
            "groups": [{"name": g} for g in reviewer["groups"]],
        }

    if with_extras and rng.random() < 0.45:
        # Classifier predictions attached to the entity.
        payload["entity"]["predictions"] = [
            {
                "inference_id": uuid_like(),
                "attributes": [rng.choice(["caption", "biography", "transcript", "username"])],
                "policy_id": policies[0]["id"],
                "confidence": rng.choice(["HIGH", "MEDIUM", "LOW"]),
                "score": round(rng.uniform(0.5, 0.999), 4),
                "is_positive": True,
            }
        ]

    if with_extras and rng.random() < 0.35:
        change = rng.choice([1, 2, 3, 5, 8])
        payload["point_updates"] = [
            {
                "points_change": change,
                "points_total": change + rng.randint(0, 20),
                "entity": {
                    "entity_schema": entity["entity_schema"],
                    "attributes": {"id": entity["attributes"]["id"]},
                },
            }
        ]

    return payload


def decision_created_rows() -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []
    decided_jobs = rng.sample(JOBS, 30)

    for job in decided_jobs:
        dtype = rng.choices(DECISION_TYPES, weights=[35, 15, 8, 6, 6, 5, 5, 5, 5, 5, 5])[0]
        ts = job["created_at"] + timedelta(minutes=rng.randint(5, 5000))
        if ts > ANCHOR:
            ts = ANCHOR - timedelta(minutes=rng.randint(1, 300))
        payload = make_decision_payload(job, dtype, ts)
        rows.append(("decision.created", json.dumps(payload, sort_keys=True), import_ts(ts)))

    # ---- Edge case: multi-review resolution ---------------------------------------
    mr_job = next(j for j in JOBS if j["queue"]["is_multi_review"])
    ts = mr_job["created_at"] + timedelta(hours=6)
    payload = make_decision_payload(mr_job, "queue_review", ts, with_extras=False)
    first, second = rng.sample(REVIEWERS, 2)
    payload["resolution"] = {
        "resolution_type": "agreement",
        "resolution_path": [
            {
                "user": {"name": r["name"], "email": r["email"], "groups": [{"name": g} for g in r["groups"]]},
                "notes": lorem(4),
                "policies": [{"id": payload["policies"][0]["id"], "name": payload["policies"][0]["name"]}],
                "timestamp": iso(ts - timedelta(minutes=offset)),
            }
            for r, offset in ((first, 40), (second, 20))
        ],
    }
    rows.append(("decision.created", json.dumps(payload, sort_keys=True), import_ts(ts)))

    # ---- Edge case: escalated multi-review ----------------------------------------
    esc_job = [j for j in JOBS if j["queue"]["is_multi_review"]][1]
    ts = esc_job["created_at"] + timedelta(hours=9)
    payload = make_decision_payload(esc_job, "queue_review", ts, with_extras=False)
    payload["resolution"] = {
        "resolution_type": "escalation",
        "resolution_path": [
            {
                "user": {
                    "name": REVIEWERS[0]["name"],
                    "email": REVIEWERS[0]["email"],
                    "groups": [{"name": g} for g in REVIEWERS[0]["groups"]],
                },
                "notes": "disagree, escalating",
                "policies": [],
                "timestamp": iso(ts - timedelta(minutes=55)),
            }
        ],
    }
    rows.append(("decision.created", json.dumps(payload, sort_keys=True), import_ts(ts)))

    # ---- Edge case: appeal resolution with an override chain -----------------------
    # Three linked decisions: original applies a policy, an override removes it, an
    # appeal decision applies a different one. The previous_decision chain is recursive.
    ap_job = rng.choice([j for j in JOBS if j["category"] == "appeal"] or JOBS)
    ts = ap_job["created_at"] + timedelta(days=2)
    payload = make_decision_payload(ap_job, "manual_override", ts, with_extras=False)
    original_policy = POLICIES[1]
    payload["appeals_resolved"] = [
        {
            "appealer": {
                "entity_schema": "user",
                "attributes": {"id": hexid(8), "email": "appellant@example.net"},
            },
            "outcome": rng.choice(["accepted", "denied", "adjustment"]),
            "source": rng.choice(["subject", "reporter", "unknown"]),
        }
    ]
    payload["previous_decision"] = {
        "policies": [],
        "policies_removed": [{"id": original_policy["id"], "name": original_policy["name"]}],
        "enforcement_actions_removed": ["warn_user"],
        "notes": "override on review",
        "user": {
            "name": REVIEWERS[3]["name"],
            "email": REVIEWERS[3]["email"],
            "groups": [{"name": g} for g in REVIEWERS[3]["groups"]],
        },
        "previous_decision": {
            "policies": [{"id": original_policy["id"], "name": original_policy["name"]}],
            "policies_removed": [],
            "enforcement_actions_removed": [],
            "notes": "original decision",
            "user": {
                "name": REVIEWERS[1]["name"],
                "email": REVIEWERS[1]["email"],
                "groups": [{"name": g} for g in REVIEWERS[1]["groups"]],
            },
            "previous_decision": None,
        },
    }
    rows.append(("decision.created", json.dumps(payload, sort_keys=True), import_ts(ts)))

    # ---- Edge case: a cleared decision, policy present but non-violating -----------
    clear_job = rng.choice(JOBS)
    ts = clear_job["created_at"] + timedelta(hours=3)
    payload = make_decision_payload(clear_job, "queue_review", ts, with_extras=False)
    nv = POLICIES[-1]
    payload["policies"] = [
        {
            "id": nv["id"],
            "name": nv["name"],
            "customer_ref": nv["customer_ref"],
            "is_illegal": False,
            "is_non_violating": True,
        }
    ]
    payload["enforcement_actions"] = []
    rows.append(("decision.created", json.dumps(payload, sort_keys=True), import_ts(ts)))

    # ---- Edge case: duplicate delivery --------------------------------------------
    rows.append((rows[0][0], rows[0][1], import_ts(ANCHOR - timedelta(minutes=3))))

    return rows


# -------------------------------------------------------------------------------------
# job.closed
# -------------------------------------------------------------------------------------


def job_closed_rows(decision_rows: list[tuple[str, str, str]]) -> list[tuple[str, str, str]]:
    """
    Closures are built from the decisions that were actually generated, so the
    reconciliation test between fct_job_closures and fct_decisions has something real to
    check. One closure is left deliberately unreconciled — see below.
    """
    by_job: dict[str, list[dict]] = {}
    for _, payload_json, _ in decision_rows:
        p = json.loads(payload_json)
        job_id = p["source"]["job"]["id"]
        by_job.setdefault(job_id, []).append(p)

    jobs_by_id = {j["id"]: j for j in JOBS}
    rows: list[tuple[str, str, str]] = []

    for job_id, decisions in list(by_job.items())[:18]:
        job = jobs_by_id.get(job_id)
        if job is None:
            continue

        last_ts = max(
            datetime.fromisoformat(d["timestamp"].replace("Z", "+00:00")) for d in decisions
        )
        closed_ts = last_ts + timedelta(seconds=rng.randint(2, 600))
        if closed_ts > ANCHOR:
            closed_ts = ANCHOR

        payload = {
            "job": {
                "id": job["id"],
                # Note the field name: job.closed uses `category`, job.actioned uses
                # `job_category`. Same concept, different key.
                "category": job["category"],
                "created_at": iso_zulu(job["created_at"]),
                "queue": job["queue"],
                "entity": job["entity"],
            },
            "decisions": [
                {
                    "entity": d["entity"],
                    "enforcement_actions": d["enforcement_actions"],
                    "policies": [{"id": p["id"], "name": p["name"]} for p in d["policies"]],
                    "source": {"type": "manual" if "user" in d["source"] else "automated"},
                    "timestamp": d["timestamp"],
                }
                for d in decisions
            ],
            "timestamp": iso_zulu(closed_ts),
        }
        rows.append(("job.closed", json.dumps(payload, sort_keys=True), import_ts(closed_ts)))

    # ---- Edge case: a closure with no matching decision.created --------------------
    # Real and expected: if decision.created is not routed, or a decision predates the
    # webhook subscription, a closure arrives with no decision-grain counterpart. The
    # reconciliation test reports this at warning level rather than failing.
    orphan = rng.choice([j for j in JOBS if j["id"] not in by_job])
    closed_ts = orphan["created_at"] + timedelta(hours=5)
    payload = {
        "job": {
            "id": orphan["id"],
            "category": "training",
            "created_at": iso_zulu(orphan["created_at"]),
            "queue": orphan["queue"],
            "entity": orphan["entity"],
        },
        "decisions": [
            {
                "entity": orphan["entity"],
                "enforcement_actions": ["warn_user"],
                "policies": [{"id": POLICIES[2]["id"], "name": POLICIES[2]["name"]}],
                "source": {"type": "manual"},
                "timestamp": iso_zulu(closed_ts - timedelta(minutes=4)),
            }
        ],
        "timestamp": iso_zulu(closed_ts),
    }
    rows.append(("job.closed", json.dumps(payload, sort_keys=True), import_ts(closed_ts)))

    # ---- Edge case: duplicate delivery --------------------------------------------
    rows.append((rows[0][0], rows[0][1], import_ts(ANCHOR - timedelta(minutes=2))))

    return rows


# -------------------------------------------------------------------------------------
# Write
# -------------------------------------------------------------------------------------


def write_seed(name: str, rows: list[tuple[str, str, str]]) -> None:
    SEED_DIR.mkdir(parents=True, exist_ok=True)
    path = SEED_DIR / f"{name}.csv"
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh, quoting=csv.QUOTE_ALL, lineterminator="\n")
        writer.writerow(["event", "payload", "import_ts"])
        for row in sorted(rows, key=lambda r: (r[2], r[1])):
            writer.writerow(row)
    print(f"  {path.relative_to(Path(__file__).parent.parent)}: {len(rows)} rows")


def main() -> None:
    print("Generating Cinder webhook seeds")
    actioned = job_actioned_rows()
    decisions = decision_created_rows()
    closed = job_closed_rows(decisions)

    write_seed("seed_cinder_job_actioned", actioned)
    write_seed("seed_cinder_decision_created", decisions)
    write_seed("seed_cinder_job_closed", closed)
    print("Done.")


if __name__ == "__main__":
    main()
