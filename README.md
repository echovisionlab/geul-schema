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

## Page locale write authority

`page_translation.incarnation_id` identifies one locale row's lifetime. It is
assigned by PostgreSQL on creation and remains stable during updates. Deleting
and recreating a locale creates a new identity, even when timestamps match.
Page target write revisions bind this identity, the locale's `updated_at`, and
the shared Content Document revision, so an old editor cannot write into a
replacement locale.

Existing installations must apply the following schema change before deploying
an API that reads Page locale incarnations:

```sql
ALTER TABLE public.page_translation
    ADD COLUMN incarnation_id uuid DEFAULT gen_random_uuid() NOT NULL;
```

This repository supplies a fresh-install snapshot. Applying it or this upgrade
to a running installation is a separate deployment operation.

## Campaign delivery recipient claims

`email_delivery_recipient.delivery_claim_id` and
`email_delivery_recipient.delivery_claim_expires_at` record the owner and expiry
of a pending recipient's delivery claim. They are nullable and constrained to be
either both null or both present. A fresh install creates both columns without
defaults. Existing installations must apply the versioned
`email-delivery-claims-v1` operation in the deployment repository before running
an API that persists recipient claims. The forward-only operation adds both
nullable columns without changing existing recipients, including terminal
delivery rows; those rows remain unclaimed. It verifies the column contract,
pair constraint, and preexisting row values, and can be safely retried after a
successful run.

## CI performance

On the same local `linux/amd64` host, a cold-ish fresh-schema run fell from
82.149 seconds with the inline extension build to 16.430 seconds with the
pinned public image (65.719 seconds, or 80.0%, faster). Hosted-runner timings
will vary.

Questions: state303 <state303@dsub.io>

## License

PolyForm Noncommercial 1.0.0. Commercial use requires a separate license from
state303. See [LICENSE.md](LICENSE.md).
