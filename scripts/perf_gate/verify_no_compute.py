"""Assert the gate never spends warehouse compute.

    python -m scripts.perf_gate.verify_no_compute --base-ref origin/main

THE CLAIM THIS DEFENDS. The whole premise is that the expensive question — will this be slow
against production volumes — can be answered without building anything. If the gate quietly
started scanning data, it would be a worse version of the build it replaced, and the failure
would be invisible: correct findings, unexpected bill.

So it is asserted rather than assumed. The check runs the gate, then reads back every statement
the session issued and fails if any of them read data or wrote anything.

Uses INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER rather than ACCOUNT_USAGE.QUERY_HISTORY, because
ACCOUNT_USAGE lags by up to ~45 minutes and cannot see the run that just happened. This is the
one place the gate needs real-time history, which is exactly what ACCOUNT_USAGE is unfit for.

SCOPE, STATED PLAINLY. The window covers the gate invocation, not the `dbt compile` that precedes
it in CI. Compile issues metadata SELECTs to resolve relation existence and writes nothing, and
those reads fall inside the allowance below — but if you want the stronger claim, run compile
inside the window too. As written this proves the measuring step is free, not the whole job.

It also watches the CURRENT user, so run it as the CI service user to make a claim about CI.
Run as an administrator it proves the same thing about a different identity.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

from . import gate

# Statement types that read or write data. Anything here means the gate stopped being free.
FORBIDDEN_TYPES = {
    "CREATE_TABLE_AS_SELECT",
    "INSERT",
    "MERGE",
    "UPDATE",
    "DELETE",
    "TRUNCATE_TABLE",
    "COPY",
    "CREATE_DYNAMIC_TABLE",
    "ALTER_DYNAMIC_TABLE_REFRESH",
    "UNLOAD",
}

# dbt's compile does issue SELECTs against INFORMATION_SCHEMA to resolve relation existence, and
# those are metadata reads that touch no micro-partitions. This is the ceiling for total bytes
# scanned by the whole run: generous enough for metadata, far below any real table.
BYTES_SCANNED_ALLOWANCE = 10 * 1024 * 1024  # 10 MiB


def main() -> int:
    ap = argparse.ArgumentParser(prog="verify_no_compute")
    ap.add_argument("--base-ref", default="origin/main")
    ap.add_argument("--connection", default=None)
    ap.add_argument("--warehouse", default=None)
    ap.add_argument(
        "--database",
        default=os.environ.get("SNOWFLAKE_DATABASE", "CINDER_ANALYTICS"),
        help="QUERY_HISTORY_BY_USER is a schema-level table function, so it needs a database in "
        "context. Any database the role can use will do - the history it returns is "
        "account-wide, not scoped to it.",
    )
    args = ap.parse_args()

    con = gate.connect(args.connection)
    cur = con.cursor()
    cur.execute(f"USE DATABASE {args.database}")
    cur.execute("SELECT CURRENT_USER(), CURRENT_TIMESTAMP()")
    user, started = cur.fetchone()
    print(f"Watching statements by {user} from {started}")

    cmd = [sys.executable, "-m", "scripts.perf_gate", "--base-ref", args.base_ref]
    if args.connection:
        cmd += ["--connection", args.connection]
    if args.warehouse:
        cmd += ["--warehouse", args.warehouse]
    result = subprocess.run(cmd)
    # A blocking finding exits 1 and is a legitimate outcome. Exit 2 and above, or a missing
    # manifest, means the gate did not actually run - and asserting "no compute" about a run that
    # never happened would be a vacuous pass, which is worse than a failure.
    if not gate.MANIFEST.exists():
        print(
            "::error::No target/manifest.json - the gate did not run, so this proves nothing."
        )
        con.close()
        return 1
    print(
        f"Gate exited {result.returncode} (a blocking finding is not a failure of this check)"
    )

    cur.execute(
        """
        SELECT query_type, SUM(COALESCE(bytes_scanned, 0)), COUNT(*)
        FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
            USER_NAME => %s,
            END_TIME_RANGE_START => TO_TIMESTAMP_LTZ(%s),
            RESULT_LIMIT => 10000))
        WHERE query_text NOT ILIKE '%%QUERY_HISTORY_BY_USER%%'
        GROUP BY query_type
        ORDER BY 3 DESC
        """,
        (user, started),
    )
    rows = cur.fetchall()
    con.close()

    total_bytes = sum(r[1] or 0 for r in rows)
    print("\nStatements issued during the gate run:")
    for qtype, scanned, count in rows:
        print(
            f"  {qtype:28} {count:>4} statements  {(scanned or 0) / 1e6:9.2f} MB scanned"
        )

    failures = []
    offending = sorted({r[0] for r in rows} & FORBIDDEN_TYPES)
    if offending:
        failures.append(
            f"statement types that read or write data were issued: {offending}"
        )
    if total_bytes > BYTES_SCANNED_ALLOWANCE:
        failures.append(
            f"{total_bytes / 1e6:.2f} MB scanned, above the "
            f"{BYTES_SCANNED_ALLOWANCE / 1e6:.2f} MB metadata allowance"
        )

    print()
    if failures:
        for f in failures:
            print(f"::error::{f}")
        print(
            "FAIL - the gate is no longer free. Something in it now reads or writes data."
        )
        return 1
    print(
        f"PASS - {total_bytes / 1e6:.2f} MB scanned, no data-reading or data-writing statements."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
