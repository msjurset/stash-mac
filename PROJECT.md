# Project: Stash Ecosystem AI Robustness & Controls

## Architecture
The Stash ecosystem consists of a Go Server (`gostash`), an Android App (`droid_stash`), and a Chrome Extension.
- **Go Server**: Handles item storage, AI transcription, classification, embeddings, billing metadata (pricing/usage JSON logs), and client sync endpoints.
- **Android App**: Captures items offline/online, runs local/remote AI queries via Gemini API, tracks offline sync logs, and syncs data to the Go server.
- **Chrome Extension**: Integrates with local browser and communicates with the `stash` command-line executable via Native Messaging.

```
       +---------------------------------------------+
       |                 Go Server                   |
       |  (Config, Database, Ledger, AI Orchestrator)|
       +-------+-----------------------------+-------+
               ^                             ^
               |                             |
     HTTP Sync & Analytics          Native Messaging
               |                             |
               v                             v
       +-------+-------+             +-------+-------+
       |  Android App  |             |  Chrome Ext.  |
       | (droid_stash) |             |  (Browser)    |
       +---------------+             +---------------+
```

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Go Server AI Fallbacks & Cost Control | Config fallbacks/backoff, ledger budget checking, 429 errors | None | DONE |
| 2 | Go Server Paid Tier & Sync Endpoints | Paid tier middleware, 1Password resolve, `/sync-logs` endpoint | M1 | DONE |
| 3 | Android AI Client & Fallbacks | Centralize fallbacks in `GeminiClient`, update ViewModels | None | DONE |
| 4 | Android Paid Tier & Offline Sync | Fetch paid tier config, local analytics database & worker sync | M2, M3 | DONE |
| 5 | E2E Integration & Verification | Chrome extension native host verification, full E2E 429 tests | M1, M2, M3, M4 | DONE |

## Interface Contracts
### Android ↔ Go Server Sync Protocol
1. **Fetch Config & Usage (`GET /config`, `GET /gemini-usage`)**:
   - The Go server serves paid tier status, active budget limits, and current usage.
   - Android maps these locally to adapt model routing and block operations when budget is exceeded.
2. **Offline Log Sync (`POST /api/sync-logs`)**:
   - Android uploads pending offline log arrays when network becomes available.
   - Server registers and updates the DB ledger without duplication.

### Go Server AI Fallback config
- Falls back gracefully from flagship models (`gemini-2.5-flash`) to cheaper or alternative models on 429 errors.
