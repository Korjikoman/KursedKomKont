"""Apply the two project SQL scripts atomically; remember their SHA-256 hashes."""

import hashlib
import logging
import os
from pathlib import Path
import re
import sys

import psycopg


SQL_FILES = (
    "kursed_postgresql12_dbeaver.sql",
    "komkont_triggers_12_functions.sql",
)
LOG = logging.getLogger("migrate")


def migration_body(source: str) -> str:
    begin = re.compile(r"^BEGIN;[ \t]*$", re.MULTILINE)
    commit = re.compile(r"^COMMIT;[ \t]*$", re.MULTILINE)
    starts, ends = list(begin.finditer(source)), list(commit.finditer(source))
    if len(starts) != 1 or len(ends) != 1 or starts[0].start() >= ends[0].start():
        raise ValueError("Expected exactly one outer BEGIN; / COMMIT; pair")
    return commit.sub("", begin.sub("", source, count=1), count=1)


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    sql_dir = Path(os.environ.get("SQL_DIR", Path(__file__).resolve().parent))
    try:
        migrations = []
        for name in SQL_FILES:
            raw = (sql_dir / name).read_bytes()
            migrations.append((name, hashlib.sha256(raw).hexdigest(),
                               migration_body(raw.decode("utf-8-sig"))))

        with psycopg.connect(autocommit=True, connect_timeout=10) as conn:
            with conn.transaction():
                conn.execute("SET LOCAL lock_timeout = '5s'")
                conn.execute("SELECT pg_advisory_xact_lock(73203, 1)")
                conn.execute("CREATE SCHEMA IF NOT EXISTS migration_meta")
                conn.execute("""
                    CREATE TABLE IF NOT EXISTS migration_meta.schema_migrations (
                        filename text PRIMARY KEY,
                        sha256 text NOT NULL,
                        applied_at timestamptz NOT NULL DEFAULT now()
                    )
                """)
                applied = dict(conn.execute(
                    "SELECT filename, sha256 FROM migration_meta.schema_migrations"
                ).fetchall())

                for name, checksum, body in migrations:
                    if name in applied:
                        if applied[name] != checksum:
                            raise ValueError(
                                f"Applied file has changed: {name}. "
                                "Restore it; use a new migration for schema changes."
                            )
                        LOG.info("SKIP %s (already applied)", name)
                        continue
                    LOG.info("APPLY %s", name)
                    conn.execute(body, prepare=False)
                    conn.execute(
                        "INSERT INTO migration_meta.schema_migrations "
                        "(filename, sha256) VALUES (%s, %s)", (name, checksum)
                    )
            LOG.info("SUCCESS: migrations committed; database is ready")
        return 0
    except (OSError, UnicodeError, ValueError, psycopg.Error) as exc:
        LOG.error("Migration failed; uncommitted changes rolled back: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
