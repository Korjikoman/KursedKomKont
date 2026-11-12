"""Apply the two project SQL scripts atomically; remember their SHA-256 hashes."""

import hashlib
import logging
import os
from pathlib import Path
import re
import subprocess
import sys
from tempfile import TemporaryDirectory

LOG = logging.getLogger("migrate")
SQL_FILE_VARIABLES = ("SQL_SCHEMA_FILE", "SQL_FUNCTIONS_FILE")

SETUP_SQL = r"""
SET LOCAL lock_timeout = '5s';
SELECT pg_advisory_xact_lock(73203, 1) AS migration_lock \gset
CREATE SCHEMA IF NOT EXISTS migration_meta;
CREATE TABLE IF NOT EXISTS migration_meta.schema_migrations (
    filename text PRIMARY KEY,
    sha256 text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
);
"""

APPLY_SQL = r"""
SELECT count(*) > 0 AS already_applied,
       coalesce(bool_or(sha256 <> :'checksum_{index}'), false) AS checksum_changed
FROM migration_meta.schema_migrations
WHERE filename = :'filename_{index}'
\gset
\if :checksum_changed
    \warn Applied file has changed: :filename_{index}
    DO $$ BEGIN RAISE EXCEPTION 'Applied migration checksum mismatch'; END $$;
\endif
\if :already_applied
    \echo SKIP :filename_{index}
\else
    \echo APPLY :filename_{index}
    \include :path_{index}
    INSERT INTO migration_meta.schema_migrations (filename, sha256)
    VALUES (:'filename_{index}', :'checksum_{index}');
\endif
"""


def migration_body(source: str) -> str:
    if source.lstrip().startswith("--\n-- PostgreSQL database dump\n"):
        return source

    begin = re.compile(r"^BEGIN;[ \t]*$", re.MULTILINE)
    commit = re.compile(r"^COMMIT;[ \t]*$", re.MULTILINE)
    starts, ends = list(begin.finditer(source)), list(commit.finditer(source))
    if not starts and not ends:
        return source
    if len(starts) != 1 or len(ends) != 1 or starts[0].start() >= ends[0].start():
        raise ValueError("Expected exactly one outer BEGIN; / COMMIT; pair")
    return commit.sub("", begin.sub("", source, count=1), count=1)


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    sql_dir = Path(os.environ.get("SQL_DIR", Path(__file__).resolve().parent))
    try:
        command = [
            "psql", "-X", "-q", "-w", "-o", os.devnull,
            "-v", "ON_ERROR_STOP=1", "--single-transaction", "-f", "-",
        ]
        sql = [SETUP_SQL]
        with TemporaryDirectory(prefix="kursed-migrate-") as staging:
            for index, variable in enumerate(SQL_FILE_VARIABLES, start=1):
                name = os.environ.get(variable)
                if not name:
                    raise ValueError(f"Missing SQL filename in {variable}")
                raw = (sql_dir / name).read_bytes()
                source = raw.decode("utf-8-sig")
                if not source.strip():
                    LOG.info("SKIP %s (empty)", name)
                    continue

                path = Path(staging) / f"migration-{index}.sql"
                path.write_text(migration_body(source), encoding="utf-8")
                command.extend([
                    "-v", f"filename_{index}={name}",
                    "-v", f"checksum_{index}={hashlib.sha256(raw).hexdigest()}",
                    "-v", f"path_{index}={path}",
                ])
                sql.append(APPLY_SQL.format(index=index))

            subprocess.run(command, input="".join(sql), encoding="utf-8", check=True)
        LOG.info("SUCCESS: migrations committed; database is ready")
        return 0
    except subprocess.CalledProcessError as exc:
        LOG.error("Migration failed; psql exited with code %s", exc.returncode)
        return 1
    except (OSError, ValueError) as exc:
        LOG.error("Migration failed: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
