# Session record sync plan

## Goal

Add cross-device sync for saved session records in Termsy, while keeping passwords, live terminal sessions, open tabs, and `lastConnectedAt` local-only.

## Scope

Sync only saved session profile metadata:

- `hostname`
- `username`
- `port`
- `tmuxSessionName`
- `autoconnect`

Do not sync:

- passwords
- live SSH / terminal state
- open tabs
- `lastConnectedAt`

## Design

### Local persistence

Keep GRDB as the local source of truth on each device.

Add these fields to `Session`:

- `uuid`: stable cross-device identity
- `updatedAt`: last-write-wins timestamp for synced fields
- `deletedAt`: tombstone timestamp for propagated deletes

Keep these local-only:

- local database `id`
- `lastConnectedAt`
- Keychain password

### Sync backend

Use CloudKit private database.

CloudKit record fields:

- `uuid`
- `hostname`
- `username`
- `port`
- `tmuxSessionName`
- `autoconnect`
- `createdAt`
- `updatedAt`
- `deletedAt`

### Identity and duplicates

Use `uuid` as the stable identity.

Do not use `username` / `hostname` / `port` / `tmuxSessionName` as identity, because those are editable and should remain the same logical record when changed.

Detect exact duplicates by normalized target:

- lowercase + trimmed `hostname`
- lowercase + trimmed `username`
- exact `port`
- trimmed `tmuxSessionName`, with empty string treated as `nil`

When duplicates are found, keep one canonical record:

- canonical record = newest `updatedAt`
- preserve earliest `createdAt`
- preserve most recent local `lastConnectedAt`
- preserve one local password by moving it to the canonical session if needed
- mark the rest as tombstoned with `deletedAt`

### Conflict policy

Use last-write-wins via `updatedAt`.

Deletes are propagated with `deletedAt`. If a delete is newer than an update for the same `uuid`, the delete wins.

## Implementation plan

1. Add `uuid`, `updatedAt`, and `deletedAt` to the session schema.
2. Backfill existing rows with a UUID and `updatedAt = createdAt`.
3. Exclude tombstoned rows from normal session queries.
4. Move local password identity from host/user/port to `session.uuid`.
5. Add a CloudKit sync pass that:
   - fetches remote session records
   - applies newer remote changes locally
   - merges local exact duplicates
   - pushes local session rows, including tombstones, back to CloudKit
6. Trigger sync on launch, foreground, and after local create / update / delete.

## V1 constraints

- No password sync
- No sync status UI
- No manual conflict resolution UI
- No push-driven CloudKit subscriptions
- No hostname alias resolution beyond text normalization
- Tombstones are retained indefinitely

## Notes

This is intentionally a small, profile-only sync model. Remote session continuity should continue to come from reconnecting to the same host and tmux session, not from syncing live terminal state.
