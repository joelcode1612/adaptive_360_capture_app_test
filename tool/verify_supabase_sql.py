#!/usr/bin/env python3
"""Execute the SiteWise SQL migrations and policy tests against a throwaway database.

The three files under ``supabase/migrations`` cannot run against a bare
PostgreSQL instance: they expect the ``anon``/``authenticated`` roles,
``auth.uid()``, and the ``storage`` schema. ``supabase/harness/00_supabase_standins.sql``
recreates those, which is what makes it possible to *execute* the row-level
policies instead of shipping them unrun.

What this script does, in order:

1. Creates a scratch database (dropped afterwards unless ``--keep``).
2. Applies the stand-ins and the legacy pre-migration state.
3. Applies the three migrations, one at a time, stopping on the first error.
4. Runs ``20_policy_tests.sql`` and fails if any assertion is false.
5. Proves the rollback script refuses to run while ``owner`` rows exist, then
   succeeds once they are gone, and leaves ``NOT NULL`` and the triggers intact.

Usage:
    python tool/verify_supabase_sql.py
    python tool/verify_supabase_sql.py --host 127.0.0.1 --port 5432 \\
        --user postgres --password 123456 --keep

The database it creates is named ``sitewise_sql_harness``. Nothing else on the
server is read or written; the script refuses to touch an existing database of
that name unless ``--force-recreate`` is passed, in which case it drops only that
one.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MIGRATIONS = ROOT / "supabase" / "migrations"
HARNESS = ROOT / "supabase" / "harness"
ROLLBACK = ROOT / "supabase" / "rollback"

DB_NAME = "sitewise_sql_harness"

MIGRATION_FILES = [
    MIGRATIONS / "20261116120000_sitewise_four_role_model.sql",
    MIGRATIONS / "20261116120100_sitewise_pano_jobs_property.sql",
    MIGRATIONS / "20261116120200_sitewise_panorama_storage_rls.sql",
]


class PsqlError(RuntimeError):
    pass


def find_bin(name: str) -> str:
    """Locate a PostgreSQL client binary, preferring PATH."""
    found = shutil.which(name)
    if found:
        return found
    candidates = sorted(Path("C:/Program Files/PostgreSQL").glob(f"*/bin/{name}.exe"))
    if candidates:
        return str(candidates[-1])
    raise SystemExit(
        f"{name} not found. Add the PostgreSQL bin directory to PATH, or pass "
        f"--psql-dir."
    )


class Runner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.psql = str(Path(args.psql_dir) / "psql") if args.psql_dir else find_bin("psql")
        self.createdb = (
            str(Path(args.psql_dir) / "createdb") if args.psql_dir else find_bin("createdb")
        )
        self.dropdb = (
            str(Path(args.psql_dir) / "dropdb") if args.psql_dir else find_bin("dropdb")
        )
        self.host = args.host
        self.port = str(args.port)
        self.user = args.user
        self.env = dict(os.environ)
        if args.password:
            self.env["PGPASSWORD"] = args.password
        self.env["PGCLIENTENCODING"] = "UTF8"

    def _base(self) -> list[str]:
        """Connection flags shared by psql, createdb and dropdb."""
        return [
            "-h",
            self.host,
            "-p",
            self.port,
            "-U",
            self.user,
        ]

    def _psql(self) -> list[str]:
        """psql needs -X (ignore psqlrc) on top of the connection flags."""
        return [self.psql, "-X", *self._base()]

    def run(self, command: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
        proc = subprocess.run(
            command,
            env=self.env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if check and proc.returncode != 0:
            raise PsqlError(
                f"command failed ({proc.returncode}): {' '.join(command)}\n"
                f"--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"
            )
        return proc

    def sql(self, statement: str, database: str = DB_NAME) -> str:
        proc = self.run([*self._psql(), "-d", database, "-tAc", statement])
        return proc.stdout.strip()

    def script(self, path: Path, database: str = DB_NAME) -> subprocess.CompletedProcess:
        return self.run(
            [
                *self._psql(),
                "-d",
                database,
                "-v",
                "ON_ERROR_STOP=1",
                "-f",
                str(path),
            ]
        )

    # -- database lifecycle ---------------------------------------------------
    def database_exists(self) -> bool:
        out = self.sql(
            f"select 1 from pg_database where datname = '{DB_NAME}'", database="postgres"
        )
        return out == "1"

    def create_database(self, force: bool) -> None:
        if self.database_exists():
            if not force:
                raise SystemExit(
                    f"database {DB_NAME} already exists. Re-run with "
                    f"--force-recreate to drop only that database and start over."
                )
            self.run([self.dropdb, *self._base(), "--force", DB_NAME])
        self.run([self.createdb, *self._base(), DB_NAME])

    def drop_database(self) -> None:
        self.run([self.dropdb, *self._base(), "--force", DB_NAME], check=False)


def banner(text: str) -> None:
    print()
    print("=" * 78)
    print(text)
    print("=" * 78)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=os.environ.get("PGHOST", "127.0.0.1"))
    parser.add_argument("--port", default=os.environ.get("PGPORT", "5432"))
    parser.add_argument("--user", default=os.environ.get("PGUSER", "postgres"))
    parser.add_argument("--password", default=os.environ.get("PGPASSWORD"))
    parser.add_argument("--psql-dir", default=None, help="directory holding psql/createdb")
    parser.add_argument("--keep", action="store_true", help="leave the database in place")
    parser.add_argument(
        "--force-recreate",
        action="store_true",
        help=f"drop and recreate {DB_NAME} if it already exists",
    )
    args = parser.parse_args()

    runner = Runner(args)
    failures: list[str] = []

    try:
        banner("1. Creating the scratch database")
        runner.create_database(args.force_recreate)
        print(f"  created {DB_NAME} on {args.host}:{args.port} as {args.user}")
        print(f"  server version {runner.sql('show server_version', database=DB_NAME)}")

        banner("2. Supabase stand-ins and legacy pre-migration state")
        for name in ("00_supabase_standins.sql", "10_legacy_state.sql"):
            runner.script(HARNESS / name)
            print(f"  applied {name}")
        print(
            f"  seeded {runner.sql('select count(*) from public.users', DB_NAME)} users, "
            f"{runner.sql('select count(*) from public.property', DB_NAME)} properties, "
            f"{runner.sql('select count(*) from public.pano_jobs', DB_NAME)} pano_jobs"
        )

        banner("3. Applying the migrations")
        for path in MIGRATION_FILES:
            proc = runner.script(path)
            print(f"  applied {path.name}")
            for line in (proc.stdout + proc.stderr).splitlines():
                line = line.strip()
                if line.startswith(("NOTICE:", "WARNING:")):
                    print(f"    {line}")

        banner("4. Row-level security and role assertions")
        proc = runner.script(HARNESS / "20_policy_tests.sql")
        for line in proc.stdout.splitlines():
            if line.startswith(("NOTICE:", "WARNING:")):
                print(f"  {line.strip()}")

        summary = runner.sql(
            "select count(*) filter (where ok) || '|' || count(*) filter (where not ok) "
            "|| '|' || count(*) from harness.results",
            DB_NAME,
        )
        passed, failed, total = (int(x) for x in summary.split("|"))
        print(f"\n  {passed} passed, {failed} failed, {total} assertions")

        if failed:
            rows = runner.sql(
                "select name || ' :: ' || coalesce(detail, '') from harness.results "
                "where not ok order by at",
                DB_NAME,
            )
            print("\n  FAILURES")
            for row in rows.splitlines():
                print(f"    - {row}")
                failures.append(row)

        banner("5. Rollback script")
        down = ROLLBACK / "20261116120000_sitewise_four_role_model.down.sql"

        owner_rows = runner.sql(
            "select count(*) from public.users where role = 'owner'", DB_NAME
        )
        print(f"  owner rows present before rollback: {owner_rows}")

        proc = runner.run(
            [
                *runner._psql(),
                "-d",
                DB_NAME,
                "-v",
                "ON_ERROR_STOP=1",
                "-f",
                str(down),
            ],
            check=False,
        )
        if proc.returncode == 0:
            print("  FAIL: the rollback ran despite owner rows existing")
            failures.append("rollback did not refuse while owner rows existed")
        elif "Refusing to roll back" not in proc.stderr:
            print("  FAIL: the rollback failed for the wrong reason")
            print(f"    {proc.stderr.strip()[:400]}")
            failures.append("rollback failed for the wrong reason")
        else:
            print("  PASS: refused to roll back while owner rows existed")
            first_line = next(
                (
                    line
                    for line in proc.stderr.splitlines()
                    if "Refusing to roll back" in line
                ),
                "",
            )
            print(f"    {first_line.strip()[:300]}")

        # Confirm the refusal changed nothing.
        constraint = runner.sql(
            "select pg_get_constraintdef(oid) from pg_constraint "
            "where conname = 'users_role_check'",
            DB_NAME,
        )
        if "owner" not in constraint:
            print("  FAIL: the aborted rollback modified the constraint anyway")
            failures.append("aborted rollback modified the constraint")
        else:
            print("  PASS: the aborted rollback left the four-value constraint intact")

        runner.sql("delete from public.users where role = 'owner'", DB_NAME)
        print(
            f"  removed owner rows; {runner.sql('select count(*) from public.users', DB_NAME)} "
            f"accounts remain"
        )

        proc = runner.run(
            [
                *runner._psql(),
                "-d",
                DB_NAME,
                "-v",
                "ON_ERROR_STOP=1",
                "-f",
                str(down),
            ],
            check=False,
        )
        if proc.returncode != 0:
            print("  FAIL: the rollback did not succeed once owner rows were gone")
            print(f"    {proc.stderr.strip()[:600]}")
            failures.append("rollback did not succeed after owner rows were removed")
        else:
            print("  PASS: the rollback succeeded once no owner rows remained")
            for line in proc.stdout.splitlines():
                if line.startswith(("NOTICE:", "WARNING:")):
                    print(f"    {line.strip()}")

            constraint = runner.sql(
                "select pg_get_constraintdef(oid) from pg_constraint "
                "where conname = 'users_role_check'",
                DB_NAME,
            )
            if "owner" in constraint:
                print(f"  FAIL: constraint still accepts owner: {constraint}")
                failures.append("constraint still accepts owner after rollback")
            else:
                print(f"  PASS: constraint narrowed to {constraint}")

            nullable = runner.sql(
                "select is_nullable from information_schema.columns where "
                "table_schema = 'public' and table_name = 'users' "
                "and column_name = 'role'",
                DB_NAME,
            )
            if nullable == "NO":
                print("  PASS: NOT NULL on role was retained, as documented")
            else:
                print("  FAIL: NOT NULL on role was dropped unexpectedly")
                failures.append("NOT NULL on role was dropped by the rollback")

            triggers = runner.sql(
                "select count(*) from pg_trigger where tgrelid = "
                "'public.users'::regclass and not tgisinternal",
                DB_NAME,
            )
            print(f"  non-internal triggers on public.users after rollback: {triggers}")

    except PsqlError as exc:
        print(f"\nSQL ERROR\n{exc}", file=sys.stderr)
        failures.append("SQL error")
    finally:
        if args.keep:
            print(f"\nDatabase {DB_NAME} left in place (--keep).")
        else:
            runner.drop_database()
            print(f"\nDropped {DB_NAME}.")

    print()
    if failures:
        print(f"RESULT: FAILED ({len(failures)} problem(s))")
        return 1
    print("RESULT: ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
