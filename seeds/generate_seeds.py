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

SHAPE FIDELITY
--------------
The payloads here follow observed production shapes, not only the published examples. The
two differ in ways that matter, and each divergence is reproduced deliberately:

  * `job_category` carries values outside the published four-value enum (for example
    `qa_appeal`). The published enums are incomplete, so enum tests in this project warn
    rather than fail.
  * `job.actioned` includes `job.created_at`, which the documentation does not promise.
    Job age at action time depends on it.
  * `job.actioned` sometimes carries no `entity` object at all.
  * `job.closed` policies carry a `parent_id`, forming a policy hierarchy, and a nested
    per-policy `enforcement_actions` array. Neither appears in the published schema.
  * Reviewer groups include outsourced-moderation vendor names, which is how moderator
    populations are segmented in practice.

DETERMINISM
-----------
Fixed random seed and a fixed anchor date, so regenerating produces byte-identical files.

ALL DATA IS SYNTHETIC
---------------------
Invented usernames, example.com addresses, lorem-style content, invented vendor names. No
real people, no real handles, no real moderation content.
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
    {"slug": "proactive-review-qa", "is_multi_review": False},
    {"slug": "escalations", "is_multi_review": True},
    {"slug": "high-harm-review", "is_multi_review": True},
]

# Policy tree. Parents are top-level policy areas; children are the specific violations
# beneath them. `parent_id` is how the hierarchy arrives on the wire, and rolling
# distribution up to the parent is far more useful than counting leaves.
POLICY_PARENTS = [
    {"id": "397b80a0-e139-4e34-940d-12eec813cff5", "name": "Harassment and Abuse"},
    {"id": "4a1f7d22-2222-4c11-9a0e-8f31bb920011", "name": "Violent Threats"},
    {"id": "5b2e8e33-3333-4d22-8b1f-9042cc031122", "name": "Adult Content"},
    {"id": "6c3f9f44-4444-4e33-9c20-a153dd142233", "name": "Self-Harm"},
    {"id": "7d40a055-5555-4f44-ad31-b264ee253344", "name": "Platform Integrity"},
]

POLICIES = [
    # ---- children -------------------------------------------------------------------
    {
        "id": "09049cc6-ddf9-47fe-b6ff-1d266a3aad7d",
        "name": "Direct Threat of Violence",
        "parent_id": "4a1f7d22-2222-4c11-9a0e-8f31bb920011",
        "is_illegal": True,
        "is_non_violating": False,
        "enforcement_actions": ["ban_user", "remove_content"],
    },
    {
        "id": "1a2b3c4d-1111-4444-8888-aaaabbbbcccc",
        "name": "Targeted Harassment",
        "parent_id": "397b80a0-e139-4e34-940d-12eec813cff5",
        "is_illegal": False,
        "is_non_violating": False,
        "enforcement_actions": ["restrict_account", "remove_content"],
    },
    {
        "id": "2b3c4d5e-2222-4444-8888-bbbbccccdddd",
        "name": "Mild Harassment",
        "parent_id": "397b80a0-e139-4e34-940d-12eec813cff5",
        "is_illegal": False,
        "is_non_violating": False,
        "enforcement_actions": ["warn_user"],
    },
    {
        "id": "3c4d5e6f-3333-4444-8888-ccccddddeeee",
        "name": "Explicit Imagery",
        "parent_id": "5b2e8e33-3333-4d22-8b1f-9042cc031122",
        "is_illegal": False,
        "is_non_violating": False,
        "enforcement_actions": ["remove_content", "shadow_ban"],
    },
    {
        "id": "4d5e6f70-4444-4444-8888-ddddeeeeffff",
        "name": "Suicide and Self-Injury",
        "parent_id": "6c3f9f44-4444-4e33-9c20-a153dd142233",
        "is_illegal": True,
        "is_non_violating": False,
        "enforcement_actions": ["remove_content"],
    },
    {
        "id": "5e6f7081-5555-4444-8888-eeeeffff0000",
        "name": "Spam and Inauthentic Behaviour",
        "parent_id": "7d40a055-5555-4f44-ad31-b264ee253344",
        "is_illegal": False,
        "is_non_violating": False,
        "enforcement_actions": ["restrict_account"],
    },
    {
        # Non-violating: a reviewed-and-cleared outcome. Counting "has a policy" as "is a
        # violation" is one of the easiest ways to overstate enforcement.
        "id": "77c4f022-53e8-4cb5-8275-98a656b6ba9b",
        "name": "Non-Violating Report",
        "parent_id": "397b80a0-e139-4e34-940d-12eec813cff5",
        "is_illegal": False,
        "is_non_violating": True,
        "enforcement_actions": [],
    },
    # ---- a root policy applied directly, with no parent -----------------------------
    {
        "id": "3fd5d222-94ec-421a-a66a-288db8960907",
        "name": "Automated Pre-Screen Reject",
        "parent_id": None,
        "is_illegal": False,
        "is_non_violating": True,
        "enforcement_actions": [],
    },
]

PARENT_BY_ID = {p["id"]: p for p in POLICY_PARENTS}

ENFORCEMENT_ACTIONS = [
    "ban_user",
    "warn_user",
    "remove_content",
    "restrict_account",
    "shadow_ban",
    "no_action",
]

# Moderator populations. In-house reviewers and outsourced vendor teams sit side by side,
# distinguished only by group membership — which is how vendor-level reporting is done.
VENDOR_GROUPS = [
    "NorthPoint BPO Moderator - Abuse Moderation",
    "NorthPoint BPO Moderator - Image Review",
    "Lakeside BPO Moderator - Abuse Moderation",
]

REVIEWERS = [
    {"name": "Ada Okafor", "email": "a.okafor@example.com", "groups": ["Everyone", "Reviewers"]},
    {"name": "Bruno Silva", "email": "b.silva@example.com", "groups": ["Everyone", "Reviewers"]},
    {"name": "Chen Wei", "email": "c.wei@example.com", "groups": ["Everyone", "Reviewers", "Escalation Team"]},
    {"name": "Dara Novak", "email": "d.novak@example.com", "groups": ["Everyone", "QA"]},
    {"name": "Elif Demir", "email": "e.demir@example.com", "groups": ["Everyone", "Admin", "Workflow Admins"]},
    {"name": "Farid Haddad", "email": "f.haddad@vendor.example.net", "groups": ["Everyone", VENDOR_GROUPS[0]]},
    {"name": "Grace Mwangi", "email": "g.mwangi@vendor.example.net", "groups": ["Everyone", VENDOR_GROUPS[0]]},
    {"name": "Hugo Almeida", "email": "h.almeida@vendor.example.net", "groups": ["Everyone", VENDOR_GROUPS[1]]},
    {"name": "Ivy Chen", "email": "i.chen@vendor.example.net", "groups": ["Everyone", VENDOR_GROUPS[2]]},
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
    {
        "id": "9c0d1e2f-9999-4444-8888-333344445555",
        "name": "Cancel stale low-priority jobs",
        "rule": {"id": "0d1e2f30-aaaa-4444-8888-444455556666", "name": "Age over threshold"},
        "trigger_type": "SCHEDULE",
    },
]

# Entity attribute bags differ by schema — that is why they stay a VARIANT rather than
# being flattened. 'audio_clip' is a schema the models have never seen, included to prove
# they do not break on an unfamiliar one.
ENTITY_SCHEMAS = ["user", "text_post", "image_post", "audio_clip"]

# Observed categories, wider than the published enum. `qa_appeal` in particular does not
# appear in the documentation.
JOB_CATEGORIES_ACTIONED = ["standard", "appeal", "qa", "golden", "qa_appeal"]
JOB_CATEGORIES_CLOSED = JOB_CATEGORIES_ACTIONED + ["training", "multi_review"]

WORDS = (
    "market season figure record listen society practice ready stage moment reason "
    "signal window pattern silver quiet garden matter travel bridge candle harvest"
).split()


def lorem(n: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(n)).capitalize() + "."


def iso(dt: datetime) -> str:
    """Event time: ISO 8601, microseconds, explicit offset."""
    return dt.isoformat()


def iso_zulu(dt: datetime) -> str:
    """The other observed shape: Zulu, microseconds or none. Both must parse."""
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"


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


def hexid(n: int = 8) -> str:
    return "".join(rng.choice("0123456789abcdef") for _ in range(n))


def uuid_like() -> str:
    return f"{hexid(8)}-{hexid(4)}-4{hexid(3)}-8{hexid(3)}-{hexid(12)}"


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


def user_block(reviewer: dict) -> dict:
    return {
        "name": reviewer["name"],
        "email": reviewer["email"],
        "groups": [{"name": g} for g in reviewer["groups"]],
    }


# -------------------------------------------------------------------------------------
# Job pool — shared by both events so referential integrity actually holds
# -------------------------------------------------------------------------------------


def build_jobs(n: int) -> list[dict]:
    jobs = []
    for _ in range(n):
        schema = rng.choices(ENTITY_SCHEMAS, weights=[40, 35, 20, 5])[0]
        jobs.append(
            {
                "id": uuid_like(),
                "queue": rng.choice(QUEUES),
                "entity": make_entity(schema, hexid(8)),
                "created_at": random_dt(),
                "category": rng.choices(JOB_CATEGORIES_CLOSED, weights=[62, 8, 7, 4, 9, 5, 5])[0],
                "num_reports": rng.randint(0, 9),
                "priority": rng.choice([0, 0, 0, 1, 2]),
                # Which reviewer eventually handles it. Held here so job actions and the
                # closing decision agree on who did the work — otherwise per-moderator
                # handle time is built on unrelated rows.
                "owner": rng.choice(REVIEWERS),
            }
        )
    return jobs


JOBS = build_jobs(60)


# -------------------------------------------------------------------------------------
# job.actioned
# -------------------------------------------------------------------------------------

ACTIONS_BY_SOURCE = {
    "manual": ["created", "skipped", "changed_queue", "escalated", "returned", "deferred", "assigned", "commented"],
    "workflow": ["changed_queue", "cancelled", "escalated"],
    "auto": ["escalated", "deferred"],
    "api": ["created", "changed_queue", "cancelled"],
    "agent": ["skipped", "deferred"],
}

STATUS_AFTER = {
    "created": "open",
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


def job_actioned_rows() -> tuple[list[tuple[str, str, str]], dict[str, int]]:
    """
    Returns the rows plus a per-job count of queue changes, so the closure generator can
    stay consistent with the action history.
    """
    rows: list[tuple[str, str, str]] = []
    queue_changes: dict[str, int] = {}

    for job in JOBS:
        # Every job gets a creation action, then a variable number of movements. This is
        # what makes "how many queue changes before a job closes" a real question with a
        # real answer rather than a constant.
        n_actions = rng.choices([1, 2, 3, 4, 6], weights=[35, 30, 20, 10, 5])[0]
        cursor = job["created_at"]

        for i in range(n_actions):
            if i == 0:
                source, action = "manual", "created"
            else:
                source = rng.choices(list(ACTIONS_BY_SOURCE), weights=[60, 18, 9, 8, 5])[0]
                action = rng.choice([a for a in ACTIONS_BY_SOURCE[source] if a != "created"])

            cursor = cursor + timedelta(minutes=rng.randint(1, 900))
            if cursor > ANCHOR:
                cursor = ANCHOR - timedelta(minutes=rng.randint(1, 120))

            if action == "changed_queue":
                queue_changes[job["id"]] = queue_changes.get(job["id"], 0) + 1

            if source == "manual":
                reviewer = job["owner"] if rng.random() < 0.7 else rng.choice(REVIEWERS)
                made_by = {"user": user_block(reviewer)}
                notes = rng.choice([lorem(rng.randint(2, 6)), "", "", "wrong queue"])
            elif source == "workflow":
                wf = rng.choice(WORKFLOWS)
                made_by = {
                    "workflow": {
                        "id": wf["id"],
                        "name": wf["name"],
                        "rule": wf["rule"],
                        "event": {
                            # The entity that TRIGGERED the workflow, which can differ from
                            # the entity the action landed on.
                            "entity": make_entity(rng.choice(["user", "text_post"]), hexid(8)),
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

            job_block = {
                "id": job["id"],
                # Present in practice, though the published schema does not promise it.
                # Job age at action time depends on it.
                "created_at": iso_zulu(job["created_at"]),
                "queue": job["queue"],
                "status": STATUS_AFTER.get(action, "open"),
                "priority": job["priority"],
                "num_reports": job["num_reports"],
                "job_category": job["category"]
                if job["category"] in JOB_CATEGORIES_ACTIONED
                else "standard",
            }

            # Observed: the entity object is sometimes absent entirely. Models must not
            # assume it is there.
            if rng.random() < 0.75:
                job_block["entity"] = job["entity"]

            payload = {
                "job": job_block,
                "notes": notes,
                "action": action,
                "source": source,
                "timestamp": iso(cursor),
                "action_made_by": made_by,
            }
            rows.append(("job.actioned", json.dumps(payload, sort_keys=True), import_ts(cursor)))

    # ---- Edge case: duplicate delivery -------------------------------------------
    # Identical payload, later ingestion timestamp. Deduplication must collapse this to one
    # row; a dedup key that included the ingestion timestamp would not.
    rows.append((rows[0][0], rows[0][1], import_ts(ANCHOR - timedelta(minutes=5))))

    return rows, queue_changes


# -------------------------------------------------------------------------------------
# job.closed
# -------------------------------------------------------------------------------------
# With decision.created out of scope, the `decisions` array inside job.closed is the ONLY
# decision surface. Every decision-grain metric — handle time per decision, policy
# distribution, automated share — is built from it.

DECISION_SOURCE_TYPES = ["manual", "automated", "workflow", "api", "agent"]
AUTOMATED_SOURCE_TYPES = {"automated", "workflow", "api", "agent"}


def make_closure_decision(job: dict, decided_at: datetime, source_type: str) -> dict:
    n_policies = rng.choices([1, 1, 1, 2, 3], weights=[50, 20, 10, 15, 5])[0]
    chosen = rng.sample(POLICIES, n_policies)

    policies = []
    for p in chosen:
        entry = {
            "id": p["id"],
            "name": p["name"],
            "is_illegal": p["is_illegal"],
            "is_non_violating": p["is_non_violating"],
            # Nested per-policy enforcement actions. Not in the published schema.
            "enforcement_actions": list(p["enforcement_actions"]),
        }
        # parent_id is absent on root policies, not null — so the model has to handle a
        # missing key rather than a null value.
        if p["parent_id"] is not None:
            entry["parent_id"] = p["parent_id"]
        policies.append(entry)

    all_actions = sorted({a for p in chosen for a in p["enforcement_actions"]})
    if not all_actions:
        all_actions = ["no_action"]

    decision: dict = {
        "entity": job["entity"],
        "enforcement_actions": all_actions,
        "policies": policies,
        "source": {"type": source_type},
        "timestamp": iso_zulu(decided_at),
    }

    # A human decision names the reviewer. Automated ones do not, so per-moderator metrics
    # have to exclude them rather than bucket them as unknown.
    if source_type == "manual":
        decision["source"]["user"] = user_block(
            job["owner"] if rng.random() < 0.8 else rng.choice(REVIEWERS)
        )

    return decision


def job_closed_rows() -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []

    # Not every job closes within the window — an open backlog is normal and makes the
    # closure rate a real number rather than 100%.
    closing = rng.sample(JOBS, 42)

    for job in closing:
        closed_at = job["created_at"] + timedelta(minutes=rng.randint(30, 9000))
        if closed_at > ANCHOR:
            closed_at = ANCHOR - timedelta(minutes=rng.randint(1, 60))

        source_type = rng.choices(DECISION_SOURCE_TYPES, weights=[62, 16, 10, 7, 5])[0]

        # Multi-review queues record more than one decision on the way to closure.
        n_decisions = 2 if job["queue"]["is_multi_review"] and rng.random() < 0.6 else 1
        decisions = []
        for i in range(n_decisions):
            d_at = closed_at - timedelta(minutes=rng.randint(1, 240) * (n_decisions - i))
            if d_at < job["created_at"]:
                d_at = job["created_at"] + timedelta(minutes=5)
            decisions.append(
                make_closure_decision(job, d_at, source_type if i == n_decisions - 1 else "manual")
            )

        payload = {
            "job": {
                "id": job["id"],
                # Note the field name: job.closed uses `category`, job.actioned uses
                # `job_category`. Same concept, different key, different enum width.
                "category": job["category"],
                "created_at": iso_zulu(job["created_at"]),
                "queue": job["queue"],
                "entity": job["entity"],
            },
            "decisions": decisions,
            "timestamp": iso_zulu(closed_at),
        }
        rows.append(("job.closed", json.dumps(payload, sort_keys=True), import_ts(closed_at)))

    # ---- Edge case: a closure carrying a single non-violating policy ----------------
    cleared = rng.choice([j for j in JOBS if j not in closing] or JOBS)
    closed_at = cleared["created_at"] + timedelta(hours=2)
    nv = next(p for p in POLICIES if p["is_non_violating"])
    payload = {
        "job": {
            "id": cleared["id"],
            "category": "standard",
            "created_at": iso_zulu(cleared["created_at"]),
            "queue": cleared["queue"],
            "entity": cleared["entity"],
        },
        "decisions": [
            {
                "entity": cleared["entity"],
                "enforcement_actions": [],
                "policies": [
                    {
                        "id": nv["id"],
                        "name": nv["name"],
                        "is_illegal": False,
                        "is_non_violating": True,
                        "enforcement_actions": [],
                    }
                ],
                "source": {"type": "manual", "user": user_block(cleared["owner"])},
                "timestamp": iso_zulu(closed_at - timedelta(minutes=6)),
            }
        ],
        "timestamp": iso_zulu(closed_at),
    }
    rows.append(("job.closed", json.dumps(payload, sort_keys=True), import_ts(closed_at)))

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
    actioned, queue_changes = job_actioned_rows()
    closed = job_closed_rows()

    write_seed("seed_cinder_job_actioned", actioned)
    write_seed("seed_cinder_job_closed", closed)

    changed = sum(queue_changes.values())
    print(f"  ({changed} queue changes across {len(queue_changes)} jobs)")
    print("Done.")


if __name__ == "__main__":
    main()
