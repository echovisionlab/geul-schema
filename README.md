# Geul schema

Canonical PostgreSQL schema for a fresh Geul installation.

Apply the installable snapshot in `schema.sql` to a new database; `geul` is the
recommended database name.

The snapshot requires PostgreSQL 17+ with `pgroonga`, `ip4r`, `postgis`,
`pgcrypto`, and `pgmq`. It creates non-login `geul_*` service roles and
validation/replay functions. Queue names and public table, column, and enum
identifiers are public contracts. Deployment configures database owners and
login roles.

Current snapshot: `0.1.0`

## CI performance

On the same local `linux/amd64` host, a cold-ish fresh-schema run fell from
82.149 seconds with the inline extension build to 16.430 seconds with the
pinned public image (65.719 seconds, or 80.0%, faster). Hosted-runner timings
will vary.

Questions: state303 <state303@dsub.io>

## License

PolyForm Noncommercial 1.0.0. Commercial use requires a separate license from
state303. See [LICENSE.md](LICENSE.md).
