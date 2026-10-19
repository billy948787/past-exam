# MySQL SQL Dump To PostgreSQL

Convert one MySQL dump into one PostgreSQL dump:

```bash
./deploy/migrate-sql-dump.sh /private/path/input.sql /private/path/output.sql
```

Inspect orphan file records without migrating or modifying the input dump:

```bash
./deploy/inspect-orphan-post-files.sh /private/path/input.sql
```

The inspection prints each orphan's file ID, missing post ID, URL, timestamps,
and any valid post records that use the exact same URL. It also groups the
results by missing post ID to show whether several files belonged to one deleted
post.

Requirements:

- Docker Engine with permission to run `docker` commands.
- Internet access on the first run to download the MySQL 8, PostgreSQL 17, and
  Python base images. Later runs use Docker's local cache.
- Free disk space for the input dump, both temporary databases, images, and the
  output dump. Allow at least three times the dump size in addition to images.
- The repository source tree, because the script builds the migration code from
  `ntpu-past-exam-service/` and reads its current ORM schema.

No `.env`, Buildx plugin, Oracle connection, or database credentials are
required. Docker may print a legacy-builder deprecation warning when Buildx is
not installed; that warning is harmless.

Both one-off migration files live under `deploy/`:

- `migrate-sql-dump.sh` manages the temporary containers and output file.
- `migrate_mysql_to_postgres.py` performs schema-aware copying and validation.
- `inspect-orphan-post-files.sh` reports broken file-to-post relationships.

The script automatically:

1. Generates temporary random database passwords.
2. Starts isolated MySQL 8 and PostgreSQL 17 containers without published ports.
3. Streams `input.sql` into MySQL without copying it into an image.
4. Skips `posts_files` rows whose parent Post no longer exists and reports the
   skipped count after successful conversion.
5. Checks all expected tables, columns, relationships, unique values, booleans,
   NULL values, and string lengths.
6. Migrates into the current PostgreSQL ORM schema in one transaction.
7. Verifies exact row counts and order-independent SHA-256 signatures.
8. Writes the complete PostgreSQL schema and data to `output.sql`.
9. Removes the temporary containers, volumes, network, and generated passwords.

Historical MySQL `DATETIME` values are interpreted as `Asia/Taipei` and written
as UTC-aware PostgreSQL timestamps. MySQL `TIMESTAMP` source columns are rejected
instead of being converted with ambiguous timezone semantics.

The output path must not already exist. If any import, validation, migration, or
verification step fails, no output is produced and the temporary databases are
deleted automatically.

Skipping orphan `posts_files` changes only the temporary imported copy. The
input dump and Cloudflare R2 objects are never modified.

The resulting file can later be restored by the operator using PostgreSQL's
`psql`; this conversion command never touches the production database.
