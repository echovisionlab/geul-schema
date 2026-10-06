# Geul schema

Canonical PostgreSQL schema for a fresh Geul installation.

Apply the installable snapshot in `schema.sql` to a new database; `geul` is the
recommended database name.

The snapshot requires PostgreSQL 17+ with `pgroonga`, `ip4r`, `postgis`,
`pgcrypto`, and `pgmq`. It creates non-login `geul_*` service roles and
validation/replay functions. Queue names and public table, column, and enum
identifiers are public contracts. Deployment configures database owners and
login roles.

Current snapshot: `0.2.0` <!-- x-release-please-version -->

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

## Page access policy

`page.access_policy` is a non-null JSONB object with an empty-object default.
The empty policy preserves existing public Page access. The API normalizes and
validates policy mode, roles, and tags; PostgreSQL enforces the object shape.

Existing installations must apply the forward-only
[`migrations/20261006-page-access-policy-v1.sql`](migrations/20261006-page-access-policy-v1.sql)
before deploying an API that reads this column. Run it with
`psql -v ON_ERROR_STOP=1 -f migrations/20261006-page-access-policy-v1.sql`.
It is transactional and retry safe, verifies existing column and constraint
metadata, and does not rewrite Page content or existing policies. Deployment
ships the same SQL in `page-access-policy-v1`; application runtime waits for
that Flux migration to become Ready.

## Post configuration revisions

`post.configuration_revision` is a non-null UUID with a `gen_random_uuid()`
default. PostgreSQL rotates it before an update when `slug`,
`comments_enabled`, `map_place_id`, or `document_layout` changes. An update that
restores an earlier value receives a new revision; a no-op or a change to body,
lifecycle, or other Post fields preserves the existing revision. This trigger
also covers older API writers. API acknowledgements use the revision returned
by PostgreSQL.

Existing installations must apply the forward-only
`post-configuration-revisions-v1` operation in the deployment repository
before running an API that reads or writes this revision. It adds and validates
the column, function, and trigger in one transaction, checks that existing Post
rows and revisions are preserved, and can be safely retried.

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

## Client media upload bundles

`upload_session.client_media_bundle_id` (UUID) and `client_media_manifest`
(JSONB) are nullable and constrained to be either both null or both present.
Existing upload sessions remain unchanged with both values null. The API stores
an immutable expected artifact manifest with a stable bundle identity; verified
artifact bodies live in session-owned staging storage. No receipt table or
mutable artifact receipt state is added to the schema.

`file.client_media_bundle_id` is a nullable UUID that preserves the committed
bundle identity after upload-session cleanup. Legacy files keep it null. The
API exposes it through authorized media-delivery reads so a lost completion
response can be recovered only for the exact committed bundle.

Existing installations must apply the forward-only SQL file
[`migrations/20261004-client-media-upload-v1.sql`](migrations/20261004-client-media-upload-v1.sql)
before deploying an API that reads or writes these columns. Run it with
`psql -v ON_ERROR_STOP=1 -f migrations/20261004-client-media-upload-v1.sql`.
The operation adds the nullable session and File columns and session pair
constraint in one transaction,
preserves existing sessions, and can be retried. Applying it to a running
installation remains a separate deployment operation.

## CI performance

On the same local `linux/amd64` host, a cold-ish fresh-schema run fell from
82.149 seconds with the inline extension build to 16.430 seconds with the
pinned public image (65.719 seconds, or 80.0%, faster). Hosted-runner timings
will vary.

Questions: state303 <state303@dsub.io>

## License

PolyForm Noncommercial 1.0.0. Commercial use requires a separate license from
state303. See [LICENSE.md](LICENSE.md).
