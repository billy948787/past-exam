"""Migrate a private MySQL database to the current PostgreSQL ORM schema.

The script never prints row values. Reports contain only table/column names,
counts, and order-independent SHA-256 signatures.
"""

import argparse
import hashlib
import json
import os
import sys
from datetime import date, datetime, time, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable
from zoneinfo import ZoneInfo

from alembic.config import Config
from alembic.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import (
    URL,
    Boolean,
    DateTime,
    MetaData,
    String,
    and_,
    bindparam,
    create_engine,
    func,
    inspect,
    select,
    text,
    update,
)
from sqlalchemy.engine import Connection, Engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.dialects.mysql import TIMESTAMP as MYSQL_TIMESTAMP
from sqlalchemy.sql.schema import Column, Table

from sql.database import SQLALCHEMY_DATABASE_URL
from sql.models import Base

TABLE_ORDER = [
    "users",
    "departments",
    "courses",
    "user_preferences",
    "users_departments",
    "bulletins",
    "posts",
    "threads",
    "posts_files",
    "thread_comments",
    "thread_likes",
    "comment_likes",
]

REQUIRED_SOURCE_TABLES = set(TABLE_ORDER)
ALLOWED_NON_DATA_SOURCE_TABLES = {"alembic_version"}

LOGICAL_RELATIONSHIPS = [
    ("courses", "department_id", "departments", "id"),
    ("posts", "owner_id", "users", "id"),
    ("posts", "course_id", "courses", "id"),
    ("posts", "department_id", "departments", "id"),
    ("posts_files", "post_id", "posts", "id"),
    ("bulletins", "department_id", "departments", "id"),
]

UNIQUE_KEYS = [
    ("users", ("username",)),
    ("user_preferences", ("user_id",)),
    ("thread_likes", ("thread_id", "user_id")),
    ("comment_likes", ("comment_id", "user_id")),
]

BOOLEAN_COLUMNS = {
    ("users", "is_super_user"),
    ("departments", "is_public"),
    ("users_departments", "is_department_admin"),
    ("user_preferences", "show_empty_courses"),
    ("user_preferences", "default_is_anonymous"),
    ("posts", "is_migrate"),
    ("posts", "is_anonymous"),
    ("threads", "is_anonymous"),
    ("thread_comments", "is_anonymous"),
}

MASK_256 = (1 << 256) - 1

# Unknown schema differences fail preflight instead of being silently dropped.
ALLOWED_EXTRA_SOURCE_COLUMNS = {
    ("posts", "group_id"),
    ("thread_comments", "reply_to_user_id"),
}

ALLOWED_MISSING_SOURCE_VALUES = {
    ("users", "note"): None,
    ("posts", "is_anonymous"): False,
    ("departments", "sort_order"): 999,
    ("user_preferences", "default_is_anonymous"): False,
}


class MigrationError(RuntimeError):
    """Raised when migration safety checks fail."""


def _service_root() -> Path:
    script_directory = Path(__file__).resolve().parent
    candidates = [
        script_directory,
        script_directory.parent / "ntpu-past-exam-service",
    ]
    for candidate in candidates:
        if (candidate / "alembic.ini").is_file():
            return candidate
    raise MigrationError("cannot locate backend Alembic configuration")


def _source_url() -> str:
    explicit_url = os.getenv("MIGRATION_SOURCE_URL")
    if explicit_url:
        return explicit_url
    return URL.create(
        drivername="mysql+mysqlconnector",
        username=os.getenv("MIGRATION_SOURCE_USERNAME", "root"),
        password=os.getenv("MIGRATION_SOURCE_PASSWORD"),
        host=os.getenv("MIGRATION_SOURCE_HOST", "migration-mysql"),
        port=int(os.getenv("MIGRATION_SOURCE_PORT", "3306")),
        database=os.getenv("MIGRATION_SOURCE_DATABASE", "past_exam_source"),
        query={"charset": "utf8mb4"},
    ).render_as_string(hide_password=False)


def _engines() -> tuple[Engine, Engine]:
    return (
        create_engine(_source_url(), pool_pre_ping=True, hide_parameters=True),
        create_engine(
            SQLALCHEMY_DATABASE_URL, pool_pre_ping=True, hide_parameters=True
        ),
    )


def _reflect_source(source_engine: Engine) -> MetaData:
    metadata = MetaData()
    metadata.reflect(bind=source_engine, only=lambda name, _: name in TABLE_ORDER)
    return metadata


def _count(connection: Connection, table: Table) -> int:
    return connection.execute(select(func.count()).select_from(table)).scalar_one()


def _duplicate_group_count(
    connection: Connection, table: Table, column_names: tuple[str, ...]
) -> int:
    columns = [table.c[name] for name in column_names]
    groups = (
        select(*columns)
        .where(and_(*(column.is_not(None) for column in columns)))
        .group_by(*columns)
        .having(func.count() > 1)
        .subquery()
    )
    return connection.execute(select(func.count()).select_from(groups)).scalar_one()


def _relationship_checks(metadata: MetaData) -> list[tuple[str, str, str, str]]:
    checks = set(LOGICAL_RELATIONSHIPS)
    for table in Base.metadata.tables.values():
        for foreign_key in table.foreign_keys:
            checks.add(
                (
                    table.name,
                    foreign_key.parent.name,
                    foreign_key.column.table.name,
                    foreign_key.column.name,
                )
            )
    return sorted(checks)


def _orphan_count(
    connection: Connection,
    metadata: MetaData,
    child_name: str,
    child_column: str,
    parent_name: str,
    parent_column: str,
) -> int | None:
    if child_name not in metadata.tables or parent_name not in metadata.tables:
        return None
    child = metadata.tables[child_name]
    parent = metadata.tables[parent_name].alias(f"parent_{parent_name}")
    if child_column not in child.c or parent_column not in parent.c:
        return None
    statement = (
        select(func.count())
        .select_from(
            child.outerjoin(parent, child.c[child_column] == parent.c[parent_column])
        )
        .where(
            child.c[child_column].is_not(None),
            parent.c[parent_column].is_(None),
        )
    )
    return connection.execute(statement).scalar_one()


def _schema_report(source_engine: Engine, source: MetaData) -> dict[str, Any]:
    source_tables = set(source.tables)
    discovered_tables = set(inspect(source_engine).get_table_names())
    missing_required = sorted(REQUIRED_SOURCE_TABLES - source_tables)
    unexpected_tables = sorted(
        discovered_tables - set(TABLE_ORDER) - ALLOWED_NON_DATA_SOURCE_TABLES
    )
    report: dict[str, Any] = {
        "missing_required_tables": missing_required,
        "unexpected_tables": unexpected_tables,
        "tables": {},
        "relationships": {},
        "duplicates": {},
        "casefold_username_duplicates": 0,
        "warnings": [],
        "issues": [],
    }

    with source_engine.connect() as connection:
        for table_name in TABLE_ORDER:
            target_table = Base.metadata.tables[table_name]
            if table_name not in source.tables:
                report["tables"][table_name] = {"present": False, "rows": 0}
                continue

            source_table = source.tables[table_name]
            source_columns = set(source_table.c.keys())
            target_columns = set(target_table.c.keys())
            missing_columns = sorted(target_columns - source_columns)
            extra_columns = sorted(source_columns - target_columns)
            report["tables"][table_name] = {
                "present": True,
                "rows": _count(connection, source_table),
                "missing_target_columns": missing_columns,
                "ignored_source_columns": extra_columns,
            }

            unexpected_missing = [
                column
                for column in missing_columns
                if (table_name, column) not in ALLOWED_MISSING_SOURCE_VALUES
            ]
            unexpected_extra = [
                column
                for column in extra_columns
                if (table_name, column) not in ALLOWED_EXTRA_SOURCE_COLUMNS
            ]
            if unexpected_missing:
                report["issues"].append(
                    f"{table_name} has unreviewed missing columns: "
                    f"{', '.join(unexpected_missing)}"
                )
            if unexpected_extra:
                report["issues"].append(
                    f"{table_name} has unreviewed extra columns: "
                    f"{', '.join(unexpected_extra)}"
                )
            for column in missing_columns:
                if (table_name, column) in ALLOWED_MISSING_SOURCE_VALUES:
                    report["warnings"].append(
                        f"{table_name}.{column} will be synthesized"
                    )
            for column in extra_columns:
                if (table_name, column) in ALLOWED_EXTRA_SOURCE_COLUMNS:
                    report["warnings"].append(
                        f"{table_name}.{column} is intentionally ignored"
                    )

            if "id" not in source_columns:
                report["issues"].append(f"{table_name}.id is missing")

            for target_column in target_table.c:
                if target_column.name not in source_columns:
                    continue
                source_column = source_table.c[target_column.name]
                if isinstance(target_column.type, DateTime) and isinstance(
                    source_column.type, MYSQL_TIMESTAMP
                ):
                    report["issues"].append(
                        f"{table_name}.{target_column.name} uses MySQL TIMESTAMP; "
                        "only timezone-less DATETIME is accepted"
                    )
                if isinstance(target_column.type, String) and target_column.type.length:
                    max_length = connection.execute(
                        select(func.max(func.char_length(source_column)))
                    ).scalar_one()
                    if max_length and max_length > target_column.type.length:
                        report["issues"].append(
                            f"{table_name}.{target_column.name} exceeds "
                            f"{target_column.type.length} characters"
                        )

                if not target_column.nullable:
                    null_count = connection.execute(
                        select(func.count())
                        .select_from(source_table)
                        .where(source_column.is_(None))
                    ).scalar_one()
                    if null_count:
                        report["issues"].append(
                            f"{table_name}.{target_column.name} has {null_count} NULL rows"
                        )

            for column_name in source_columns:
                if (table_name, column_name) not in BOOLEAN_COLUMNS:
                    continue
                column = source_table.c[column_name]
                invalid_count = connection.execute(
                    select(func.count())
                    .select_from(source_table)
                    .where(column.is_not(None), ~column.in_([0, 1, False, True]))
                ).scalar_one()
                if invalid_count:
                    report["issues"].append(
                        f"{table_name}.{column_name} has {invalid_count} non-boolean rows"
                    )

        for child, child_column, parent, parent_column in _relationship_checks(source):
            key = f"{child}.{child_column}->{parent}.{parent_column}"
            orphan_count = _orphan_count(
                connection,
                source,
                child,
                child_column,
                parent,
                parent_column,
            )
            report["relationships"][key] = orphan_count
            if orphan_count:
                report["issues"].append(f"{key} has {orphan_count} orphan rows")

        for table_name, columns in UNIQUE_KEYS:
            if table_name not in source.tables or not all(
                column in source.tables[table_name].c for column in columns
            ):
                continue
            duplicate_count = _duplicate_group_count(
                connection, source.tables[table_name], columns
            )
            key = f"{table_name}({','.join(columns)})"
            report["duplicates"][key] = duplicate_count
            if duplicate_count:
                report["issues"].append(f"{key} has {duplicate_count} duplicate groups")

        if "users" in source.tables and "username" in source.tables["users"].c:
            users = source.tables["users"]
            lowered = func.lower(users.c.username)
            groups = (
                select(lowered)
                .where(users.c.username.is_not(None))
                .group_by(lowered)
                .having(func.count() > 1)
                .subquery()
            )
            casefold_count = connection.execute(
                select(func.count()).select_from(groups)
            ).scalar_one()
            report["casefold_username_duplicates"] = casefold_count
            if casefold_count:
                report["warnings"].append(
                    f"users.username has {casefold_count} case-insensitive duplicate groups"
                )

    if missing_required:
        report["issues"].append(
            f"missing required tables: {', '.join(missing_required)}"
        )
    if unexpected_tables:
        report["issues"].append(
            f"unreviewed source tables: {', '.join(unexpected_tables)}"
        )
    try:
        _repository_head()
    except MigrationError as exc:
        report["issues"].append(str(exc))
    return report


def _coerce_value(value: Any, target_column: Column, source_zone: ZoneInfo) -> Any:
    if value is None:
        return None
    if isinstance(target_column.type, Boolean):
        if isinstance(value, bytes):
            return bool(int.from_bytes(value, "big"))
        return bool(value)
    if isinstance(target_column.type, DateTime):
        if isinstance(value, str):
            if value.startswith("0000-00-00"):
                raise MigrationError(
                    f"zero date found in {target_column.table.name}.{target_column.name}"
                )
            value = datetime.fromisoformat(value)
        if isinstance(value, datetime):
            if value.tzinfo is None:
                value = value.replace(tzinfo=source_zone)
            return value.astimezone(timezone.utc)
    return value


def _default_value(column: Column, migration_time: datetime) -> Any:
    if column.name == "id":
        raise MigrationError(
            f"{column.table.name}.id cannot be generated during migration"
        )
    if column.name == "create_time":
        return migration_time
    if column.name == "updated_time":
        return None
    allowed_key = (column.table.name, column.name)
    if allowed_key in ALLOWED_MISSING_SOURCE_VALUES:
        return ALLOWED_MISSING_SOURCE_VALUES[allowed_key]
    if column.default and column.default.is_scalar:
        return column.default.arg
    if column.nullable:
        return None
    raise MigrationError(f"no safe value for missing {column.table.name}.{column.name}")


def _target_row(
    source_row: Any,
    source_columns: set[str],
    target_table: Table,
    source_zone: ZoneInfo,
    migration_time: datetime,
) -> dict[str, Any]:
    values = source_row._mapping
    target: dict[str, Any] = {}
    for column in target_table.c:
        if column.name in source_columns:
            if values[column.name] is None and not column.nullable:
                raise MigrationError(
                    f"NULL found in required {target_table.name}.{column.name}"
                )
            target[column.name] = _coerce_value(
                values[column.name], column, source_zone
            )
        else:
            target[column.name] = _default_value(column, migration_time)
    return target


def _target_existing_tables(target_engine: Engine) -> list[str]:
    return sorted(inspect(target_engine).get_table_names())


def _repository_head() -> str:
    service_root = _service_root()
    config = Config(str(service_root / "alembic.ini"))
    config.set_main_option("script_location", str(service_root / "alembic"))
    script = ScriptDirectory.from_config(config)
    heads = script.get_heads()
    if len(heads) != 1:
        raise MigrationError(
            f"repository must have exactly one Alembic head; found {len(heads)}"
        )
    return heads[0]


def _stamp_head(connection: Connection) -> str:
    service_root = _service_root()
    config = Config(str(service_root / "alembic.ini"))
    config.set_main_option("script_location", str(service_root / "alembic"))
    script = ScriptDirectory.from_config(config)
    head = _repository_head()
    MigrationContext.configure(connection).stamp(script, head)
    return head


def migrate(
    source_engine: Engine,
    target_engine: Engine,
    source: MetaData,
    batch_size: int,
    source_zone: ZoneInfo,
) -> dict[str, Any]:
    preflight = _schema_report(source_engine, source)
    if preflight["issues"]:
        raise MigrationError("source preflight failed; run the preflight command")
    existing_tables = _target_existing_tables(target_engine)
    if existing_tables:
        raise MigrationError(
            f"target is not blank; existing tables: {', '.join(existing_tables)}"
        )

    migration_time = datetime.now(timezone.utc)
    copied: dict[str, int] = {}
    with source_engine.connect() as source_connection:
        with target_engine.begin() as target_connection:
            target_connection.execute(text("SET TIME ZONE 'UTC'"))
            Base.metadata.create_all(target_connection)

            comment_parent_links: list[dict[str, Any]] = []
            for table_name in TABLE_ORDER:
                target_table = Base.metadata.tables[table_name]
                if table_name not in source.tables:
                    copied[table_name] = 0
                    continue
                source_table = source.tables[table_name]
                source_columns = set(source_table.c.keys())
                statement = select(source_table).order_by(source_table.c.id)
                result = source_connection.execution_options(
                    stream_results=True
                ).execute(statement)
                table_count = 0
                for partition in result.partitions(batch_size):
                    rows = [
                        _target_row(
                            row,
                            source_columns,
                            target_table,
                            source_zone,
                            migration_time,
                        )
                        for row in partition
                    ]
                    if table_name == "thread_comments":
                        for row in rows:
                            if row.get("parent_comment_id"):
                                comment_parent_links.append(
                                    {
                                        "row_id": row["id"],
                                        "parent_id": row["parent_comment_id"],
                                    }
                                )
                                row["parent_comment_id"] = None
                    if rows:
                        target_connection.execute(target_table.insert(), rows)
                    table_count += len(rows)
                copied[table_name] = table_count

            if comment_parent_links:
                comments = Base.metadata.tables["thread_comments"]
                statement = (
                    update(comments)
                    .where(comments.c.id == bindparam("row_id"))
                    .values(parent_comment_id=bindparam("parent_id"))
                )
                for offset in range(0, len(comment_parent_links), batch_size):
                    target_connection.execute(
                        statement,
                        comment_parent_links[offset : offset + batch_size],
                    )

            head = _stamp_head(target_connection)

            verification = _verify_connections(
                source_connection,
                target_connection,
                source,
                source_zone,
            )
            if verification["issues"]:
                raise MigrationError(
                    "in-transaction verification failed: "
                    + "; ".join(verification["issues"])
                )

    return {
        "copied_rows": copied,
        "alembic_head": head,
        "verification": verification,
    }


def _canonical(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).isoformat(timespec="microseconds")
    if isinstance(value, (date, time)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return format(value, "f")
    if isinstance(value, bytes):
        return {"bytes_sha256": hashlib.sha256(value).hexdigest()}
    return str(value)


def _signature(rows: Iterable[dict[str, Any]]) -> str:
    digest_sum = 0
    digest_xor = 0
    for row in rows:
        encoded = json.dumps(
            {key: _canonical(value) for key, value in sorted(row.items())},
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode()
        value = int.from_bytes(hashlib.sha256(encoded).digest(), "big")
        digest_sum = (digest_sum + value) & MASK_256
        digest_xor ^= value
    return f"{digest_sum:064x}:{digest_xor:064x}"


def _source_signature_rows(
    connection: Connection,
    source_table: Table,
    target_table: Table,
    common_columns: list[str],
    source_zone: ZoneInfo,
) -> Iterable[dict[str, Any]]:
    columns = [source_table.c[name] for name in common_columns]
    result = connection.execution_options(stream_results=True).execute(select(*columns))
    for row in result:
        yield {
            name: _expected_source_value(
                row._mapping[name], target_table.c[name], source_zone
            )
            for name in common_columns
        }


def _expected_source_value(
    value: Any, target_column: Column, source_zone: ZoneInfo
) -> Any:
    if value is None and not target_column.nullable:
        raise MigrationError(
            f"NULL found in required {target_column.table.name}.{target_column.name}"
        )
    return _coerce_value(value, target_column, source_zone)


def _target_signature_rows(
    connection: Connection, target_table: Table, common_columns: list[str]
) -> Iterable[dict[str, Any]]:
    columns = [target_table.c[name] for name in common_columns]
    result = connection.execution_options(stream_results=True).execute(select(*columns))
    for row in result:
        yield {name: row._mapping[name] for name in common_columns}


def verify(
    source_engine: Engine,
    target_engine: Engine,
    source: MetaData,
    source_zone: ZoneInfo,
) -> dict[str, Any]:
    with source_engine.connect() as source_connection, target_engine.connect() as target_connection:
        target_connection.execute(text("SET TIME ZONE 'UTC'"))
        return _verify_connections(
            source_connection,
            target_connection,
            source,
            source_zone,
        )


def _verify_connections(
    source_connection: Connection,
    target_connection: Connection,
    source: MetaData,
    source_zone: ZoneInfo,
) -> dict[str, Any]:
    target_metadata = MetaData()
    target_metadata.reflect(
        bind=target_connection, only=lambda name, _: name in TABLE_ORDER
    )
    report: dict[str, Any] = {
        "tables": {},
        "relationships": {},
        "null_violations": {},
        "synthesized_value_violations": {},
        "issues": [],
    }

    for table_name in TABLE_ORDER:
        if table_name not in target_metadata.tables:
            report["issues"].append(f"target table {table_name} is missing")
            continue
        target_table = target_metadata.tables[table_name]
        target_count = _count(target_connection, target_table)
        source_count = 0
        common_columns: list[str] = []
        source_signature = _signature([])
        target_signature = _signature([])
        if table_name in source.tables:
            source_table = source.tables[table_name]
            source_count = _count(source_connection, source_table)
            common_columns = sorted(
                set(source_table.c.keys()) & set(target_table.c.keys())
            )
            source_signature = _signature(
                _source_signature_rows(
                    source_connection,
                    source_table,
                    target_table,
                    common_columns,
                    source_zone,
                )
            )
            target_signature = _signature(
                _target_signature_rows(target_connection, target_table, common_columns)
            )
        report["tables"][table_name] = {
            "source_rows": source_count,
            "target_rows": target_count,
            "compared_columns": common_columns,
            "source_signature": source_signature,
            "target_signature": target_signature,
            "match": source_count == target_count
            and source_signature == target_signature,
        }
        if not report["tables"][table_name]["match"]:
            report["issues"].append(f"{table_name} count or signature mismatch")

        source_columns = (
            set(source.tables[table_name].c.keys())
            if table_name in source.tables
            else set()
        )
        for column in Base.metadata.tables[table_name].c:
            if not column.nullable and column.name in target_table.c:
                null_count = target_connection.execute(
                    select(func.count())
                    .select_from(target_table)
                    .where(target_table.c[column.name].is_(None))
                ).scalar_one()
                report["null_violations"][f"{table_name}.{column.name}"] = null_count
                if null_count:
                    report["issues"].append(
                        f"target {table_name}.{column.name} has {null_count} NULL rows"
                    )

            allowed_key = (table_name, column.name)
            if (
                column.name not in source_columns
                and allowed_key in ALLOWED_MISSING_SOURCE_VALUES
            ):
                expected = ALLOWED_MISSING_SOURCE_VALUES[allowed_key]
                violation_count = target_connection.execute(
                    select(func.count())
                    .select_from(target_table)
                    .where(target_table.c[column.name].is_distinct_from(expected))
                ).scalar_one()
                report["synthesized_value_violations"][
                    f"{table_name}.{column.name}"
                ] = violation_count
                if violation_count:
                    report["issues"].append(
                        f"target {table_name}.{column.name} has "
                        f"{violation_count} unexpected synthesized values"
                    )

    for child, child_column, parent, parent_column in _relationship_checks(
        target_metadata
    ):
        key = f"{child}.{child_column}->{parent}.{parent_column}"
        orphan_count = _orphan_count(
            target_connection,
            target_metadata,
            child,
            child_column,
            parent,
            parent_column,
        )
        report["relationships"][key] = orphan_count
        if orphan_count:
            report["issues"].append(f"target {key} has {orphan_count} orphan rows")

    version_tables = inspect(target_connection).get_table_names()
    if "alembic_version" not in version_tables:
        report["issues"].append("target alembic_version table is missing")
    else:
        versions = sorted(
            target_connection.execute(
                text("SELECT version_num FROM alembic_version")
            ).scalars()
        )
        service_root = _service_root()
        config = Config(str(service_root / "alembic.ini"))
        config.set_main_option("script_location", str(service_root / "alembic"))
        expected_versions = [_repository_head()]
        report["alembic_versions"] = versions
        report["expected_alembic_versions"] = expected_versions
        if versions != expected_versions:
            report["issues"].append(
                "target Alembic versions do not match repository heads"
            )

    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["preflight", "migrate", "verify"])
    parser.add_argument("--batch-size", type=int, default=1000)
    args = parser.parse_args()
    if args.batch_size < 1:
        parser.error("--batch-size must be positive")

    source_engine: Engine | None = None
    target_engine: Engine | None = None
    try:
        source_zone = ZoneInfo(os.getenv("MIGRATION_SOURCE_TIMEZONE", "Asia/Taipei"))
        source_engine, target_engine = _engines()
        source = _reflect_source(source_engine)
        if args.command == "preflight":
            report = _schema_report(source_engine, source)
        elif args.command == "migrate":
            report = migrate(
                source_engine,
                target_engine,
                source,
                args.batch_size,
                source_zone,
            )
        else:
            report = verify(source_engine, target_engine, source, source_zone)
    except MigrationError as exc:
        print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        return 2
    except SQLAlchemyError:
        print(
            json.dumps(
                {"error": "database operation failed; row values were suppressed"},
                indent=2,
            ),
            file=sys.stderr,
        )
        return 2
    finally:
        if source_engine is not None:
            source_engine.dispose()
        if target_engine is not None:
            target_engine.dispose()

    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    issues = report.get("issues", report.get("verification", {}).get("issues", []))
    return 1 if issues else 0


if __name__ == "__main__":
    raise SystemExit(main())
