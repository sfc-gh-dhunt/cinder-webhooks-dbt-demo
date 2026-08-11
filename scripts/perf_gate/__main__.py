"""CLI entry point for the performance gate.

    python -m scripts.perf_gate --base-ref origin/main --out .perf-gate-out

Writes two artifacts and sets an exit code:

    signals.json   everything measured, including raw plans. The audit trail: when a threshold
                   is later argued about, this is what settles it.
    findings.json  what the checks concluded. This is what the model is given to explain.

The model is deliberately not in this path. Measurement and judgement happen here, so they are
reproducible and reviewable; the model's job is to explain the result in the pull request.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import sys
from pathlib import Path

from . import checks, gate


def main() -> int:
    ap = argparse.ArgumentParser(prog="perf_gate")
    ap.add_argument("--base-ref", default="origin/main")
    ap.add_argument("--config", type=Path, default=Path(".perf-gate.yml"))
    ap.add_argument("--out", type=Path, default=Path(".perf-gate-out"))
    ap.add_argument("--connection", default=None)
    ap.add_argument(
        "--warehouse",
        default=None,
        help="Pinned explicitly: plans vary with warehouse size, and with none in "
        "context Snowflake assumes XSMALL, so thresholds would not be "
        "comparable between runs.",
    )
    args = ap.parse_args()

    config = gate.load_config(args.config)
    args.out.mkdir(parents=True, exist_ok=True)

    if not gate.MANIFEST.exists():
        print("::error::No target/manifest.json. Run `dbt compile` before the gate.")
        return 1
    manifest = json.loads(gate.MANIFEST.read_text())

    changed = gate.changed_sql_files(args.base_ref)
    depth = config["thresholds"]["dependent_depth"]
    models = gate.affected_models(manifest, changed, depth)

    if not models:
        _write(args.out, {"changed_files": [str(p) for p in changed], "models": []}, [])
        print("No models affected by this diff.")
        return 0

    names = [manifest["nodes"][m]["name"] for m in models]
    print(f"Affected models ({len(names)}): {', '.join(names)}")

    con = gate.connect(args.connection)
    cur = con.cursor()
    if args.warehouse:
        cur.execute(f"USE WAREHOUSE {args.warehouse}")

    history = gate.model_history(cur, names, config["thresholds"]["history_days"])
    all_facts, findings = [], []
    for uid in models:
        for facts in gate.build_facts(cur, manifest, uid, config, history):
            all_facts.append(facts)
            findings += checks.evaluate(facts, config)
    con.close()

    findings = checks.apply_suppressions(findings, config)
    # Most expensive first: the argument should start with the thing that costs the most.
    findings.sort(key=lambda f: f.bytes_at_risk, reverse=True)

    signals = {
        "changed_files": [str(p) for p in changed],
        "models": names,
        "warehouse": args.warehouse,
        "history_available": bool(history),
        "plans": [dataclasses.asdict(f) for f in all_facts],
    }
    _write(args.out, signals, findings)

    code = checks.exit_code(findings, config)
    blocking = [f for f in findings if f.severity == "blocking"]
    advisory = [f for f in findings if f.severity == "advisory"]
    suppressed = [f for f in findings if f.severity == "suppressed"]
    print(
        f"{len(blocking)} blocking, {len(advisory)} advisory, {len(suppressed)} suppressed "
        f"-> exit {code}"
    )
    for f in blocking + advisory:
        print(f"  [{f.severity}] {f.model}: {f.summary}")
    return code


def _write(out: Path, signals: dict, findings: list[checks.Finding]) -> None:
    (out / "signals.json").write_text(json.dumps(signals, indent=2, default=str))
    (out / "findings.json").write_text(
        json.dumps([dataclasses.asdict(f) for f in findings], indent=2, default=str)
    )


if __name__ == "__main__":
    sys.exit(main())
