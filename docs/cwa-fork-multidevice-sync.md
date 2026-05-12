# CWA Fork: Multi-Device Kobo Sync Fix

**Date**: 2026-05-12
**State**: deployed to homelab as `homelab.example.com/calibre-web-automated:v4.0.6-multidevice-sync.2`. Not yet filed upstream.

## Why it exists

Stock Calibre-Web-Automated (CWA) at `v4.0.6` has a `/v1/library/sync` endpoint that filters out books already in `kobo_synced_books` for the current user — regardless of which device is syncing. This breaks every "two devices share one CWA account" setup:

- **Initial pair**: device A syncs and "claims" all books in `kobo_synced_books` (user_id-keyed). Device B joining later receives nothing because everything is already-synced *for the user*.
- **Steady-state delta**: device A wins the race to fetch a newly-added book. Server INSERTs the row; device B never sees that book as `NewEntitlement`.

The CWA design assumes one Kobo device per user. The Kobo protocol itself is fine for multi-device — it relies on the per-device `x-kobo-synctoken` cursor in HTTP headers to track "what changed for this device". CWA's user-level filter is an addition that subverts the protocol's natural mechanism.

Symptom on iOS Reader: `/v1/library/sync` returns `ChangedReadingState` entries (deltas) but **zero `NewEntitlement` entries** even on a fresh device. The Library tab stays empty.

## The fix (Alt 2)

Two `cps/kobo.py` changes inside `HandleSyncRequest`:

1. **Drop the user-level `notin_` filter** in `changed_entries` (both `kobo_only_shelves` and full-library branches). The remaining `last_modified > sync_token.books_last_modified` filter handles "what's new for THIS device" via the per-device sync-token cursor.

2. **Drop the magic-shelf bypass from the inner timestamp OR**. The original code had `db.Books.id.in_(magic_shelf_book_ids)` as a third OR clause that bypassed the timestamp cursor for magic-shelf books. Combined with the `notin_` removal, this caused magic-shelf books to re-emit on every paginated request forever (`cont_sync = True` loop). Magic-shelf membership is still enforced in the **outer** "what's in scope" filter — only its bypass of the inner cursor was wrong.

Result: per-device sync state works correctly. Each device's `x-kobo-synctoken` cursor independently tracks what it has received. New devices joining an existing account get everything on first sync; subsequent syncs are deltas; cross-device new-book scenarios work because each device's cursor advances independently.

## Patch state

| | |
|---|---|
| Fork | `git@github.com:raphi011/Calibre-Web-Automated.git` |
| Branch | `multidevice-sync-fix` (off the `v4.0.6` tag) |
| Commits | `ba3b06b` (notin_ removal), `d203344` (magic-shelf inner-OR removal) |
| Image | `homelab.example.com/calibre-web-automated:v4.0.6-multidevice-sync.2` |
| Deployed in | `manifests/calibre-web/deployment.yaml` (turingpi-k8s repo) |
| ArgoCD app | `calibre-web` — synced + healthy |

## What's still broken in the fork (not relevant to current homelab config)

The `else` branch of `HandleSyncRequest` — the full-library sync path (when `user.kobo_only_shelves_sync = 0`) — had no timestamp filter at all in the original code. The `notin_(KoboSyncedBooks)` filter was its only throttle. After Alt 2, this branch needs a timestamp filter added:

```python
.filter(or_(
    db.Books.last_modified > sync_token.books_last_modified,
))
```

Without it, full-library users get every book on every sync → infinite loop. **Irrelevant for the current homelab** because the user has `kobo_only_shelves_sync = 1`, which uses the `if` branch that we did fix. Worth fixing before any upstream PR though.

## Operational notes

- **Roll back**: edit `manifests/calibre-web/deployment.yaml` to set `image: crocodilestick/calibre-web-automated:v4.0.6`. Commit + push. ArgoCD picks up + Recreate rollout (~2 min).
- **Re-deploy a new patched version**: build + push to Zot with a fresh tag (`v4.0.6-multidevice-sync.N`), bump the manifest, commit + push.
- **Verify the fix is active**: `curl https://cwa.example.com/kobo/<TOKEN>/v1/library/sync | jq '[.[]] | length, ([.[] | keys[0]] | unique_by(.))'`. Should return both `NewEntitlement` and `ChangedReadingState` keys.

## Upstream contribution

Worth filing as a CWA PR. Bundle:

1. The two-line filter removals (`notin_` + magic-shelf inner-OR).
2. Add the timestamp filter to the `else` branch.
3. Test: verify the existing two-way-deletion logic still works (book added to a kobo_sync shelf → emitted → removed from shelf → archived emitted to next device that syncs).
4. PR description referencing the multi-device issue [janeczku/calibre-web#2230](https://github.com/janeczku/calibre-web/issues/2230).

## Related docs

- `~/Git/Calibre-Web-Automated/cps/kobo.py` — patched file (look for `Multi-device fix` comments)
- `docs/superpowers/plans/2026-05-12-multi-protocol-sync-resume.md` — Phase 6–10 resume plan
- `docs/superpowers/specs/2026-05-11-multi-protocol-sync-design.md` — original spec
