# Thumbnails & Media Plan

Plan for two intertwined feature threads:

1. Thumbnail images on every item (extracted for URLs, generated for files,
   user-overridable) so a future grid view can show a Pinterest-style board.
2. **Inline media playback** — driven by mime/URL pattern matching, no new
   item types. Local audio/video files, direct stream URLs, and known
   embed hosts (YouTube, Vimeo, …) all get a player in the detail view.

No new item types in v1. Audio/video files stay as `type=file` and get a
`#audio` or `#video` tag (set by capture or by a rule). Revisit promoting
to dedicated types if usage volume grows enough that sidebar filtering
and at-a-glance recognition matter.

---

## Goals

- Every item can have a thumbnail. URL items extract one from the page;
  file items generate one with QuickLook; image items use themselves.
- The user can override the auto-pick with a URL paste or a dropped file
  at any time, regardless of original source.
- Re-fetch is on-demand from the detail view, mirroring the existing
  "Re-fetch page content" button.
- Rules can set thumbnails as part of capture-time automation.
- Inline players appear for any item whose source resolves to playable
  media: local audio/video files (mime-driven), direct stream URLs
  (e.g., podcast MP3 endpoints, HLS streams), and known embed hosts
  (YouTube, Vimeo, …).
- Video players have a fullscreen toggle (free with native AVKit chrome).
- Eventual grid view ("Pinterest mode") consumes the thumbnails.

## Non-goals (for v1)

- LLM-based tiebreaking when URL extraction returns multiple plausible
  candidates. We ship the deterministic path first; only add LLM if the
  manual-pick rate proves annoying in real use.
- Album art editing tools, video trimming, anything that mutates the
  source media. We display, we don't edit.
- Sync between devices. Thumbnails live in the local filestore.

---

## Architecture

### Storage

- Canonical thumbnail at `~/.stash/files/thumbnails/<item-id>.jpg`.
- Single canonical size: 512px on the longer edge, JPEG quality 85,
  sRGB, EXIF stripped.
- Schema: add `thumbnail_path` (TEXT, nullable) to `items`.
- No second small variant in v1. Resize on the fly for list rows; only
  cache a 128px variant if scrolling becomes janky in practice.
- Thumbnail file is owned by stash and removed when the item is deleted
  (extend the existing item-delete cleanup path).

### Item types

No new types. Audio/video files keep `type=file`; URL items keep
`type=url`. Inline-player rendering is driven by mime (for files) and
URL pattern matching (for URLs), the same way archive contents are
handled today (`ItemDetailView.swift:217` branches on `isArchiveMIME`).

A capture-time rule can add `#audio` / `#video` tags so the user can
filter on them via the existing tag UI without a schema change.

If usage volume eventually justifies it (sidebar filter, distinct
icons in the list, type-targeted rules), promote to first-class types
with a one-time `stash refresh --retype-media` migration. Out of scope
for v1.

### Thumbnail generation pipeline

All paths feed the same post-process so output is consistent.

```
            ┌────────────────────┐
URL item ─► │ HTML extractor     │ ─► candidate(s) ─►┐
            │ (og:image, …)       │                  │
            └────────────────────┘                  │
                                                    │
File item ─► QLThumbnailGenerator ─► raw bitmap ────┤
            │ (audio mime → AVAsset album art       │
            │  fallback; video mime →               │
            │  AVAssetImageGenerator frame grab)    │
                                                    │
Image item ─► source file ──────────────────────────┤
                                                    │
                                                    ▼
                              ┌─────────────────────────────┐
                              │ Post-process pipeline        │
                              │  1. Decode (HEIC/WebP/AVIF…) │
                              │  2. Saliency-aware crop      │
                              │     (Vision framework)       │
                              │  3. Resize to 512px max      │
                              │  4. sRGB normalize, strip EXIF│
                              │  5. Bg fill if transparent   │
                              │  6. JPEG q85                 │
                              └─────────────────────────────┘
                                            │
                                            ▼
                            ~/.stash/files/thumbnails/<id>.jpg
```

#### URL extraction (deterministic)

Score in this order, take the first hit above the quality floor:

1. `<meta property="og:image">`
2. `<meta name="twitter:image">`
3. JSON-LD `image` field
4. `<link rel="apple-touch-icon" sizes="…">` (largest)
5. Largest in-page `<img>` whose natural size is ≥ 200×200 and aspect
   ratio is between 0.5 and 2.0

Quality floor: ≥ 200×200 after decode. If nothing meets the floor,
leave thumbnail unset; the type icon stands in.

#### File generation

`QLThumbnailGenerator.shared.generateRepresentations(...)` at
`{ width: 512, height: 512 }` with `representationTypes: [.thumbnail]`.
Async, runs off the main thread. Progress indicator in detail/list,
same UX as URL fetch.

For audio with no embedded artwork and video with no representative
frame (rare, but corrupt files happen), fall back to a rendered
type-badge tile: SF Symbol on a tinted background derived from the
file extension. Same shape as a real thumbnail so grid layouts don't
hiccup.

#### Manual override

Three entry points, all in the detail view's thumbnail area:

- **Paste URL** — small "Use image URL…" menu. Fetches, runs through
  post-process, saves.
- **Drop file** — drop target on the thumbnail itself. Same pipeline.
- **Pick from candidates** — when extraction found 2+ candidates and
  none scored cleanly above the others, show a picker grid (small
  preview + source domain + size). User picks one.

Override is sticky — re-fetch doesn't clobber a user-set thumbnail
unless they explicitly choose "Reset to auto".

#### On-demand re-fetch

Reuses the pattern from the existing extracted-text re-fetch button.
A small `arrow.clockwise` button next to the thumbnail in detail view.
For URLs, re-runs extraction. For files, re-runs QuickLook. For
manual-override thumbnails, no-op (or asks first).

### Inline players

A `MediaResolver` service maps an item to one of:

- `.directVideo(URL)` — local file or remote stream with `video/*`
  mime / known video extension. Renders SwiftUI `VideoPlayer` from
  AVKit. Native AVPlayerView chrome includes a fullscreen button.
- `.directAudio(URL, artwork: NSImage?)` — local file or stream with
  `audio/*` mime / known audio extension. Renders a compact custom
  bar — play/pause, scrubber, time, volume. Album art beside the bar
  if `AVAsset.metadata` produced one. Underlying engine is `AVPlayer`,
  same approach as `homebar-mac`'s `MediaPlayerService.play(_ url:)`.
- `.embed(URL)` — known embed host. Renders a `WKWebView` with the
  canonical embed URL. Hosts in v1: YouTube, Vimeo. Easy to extend
  (SoundCloud, Bandcamp, Twitch) by adding entries to the resolver.
- `.none` — no player; fall back to existing detail content.

#### Resolution sources

| Item shape                                       | Resolver output |
|---|---|
| `type=file`, mime `video/*`, local path          | `.directVideo(file://…)` |
| `type=file`, mime `audio/*`, local path          | `.directAudio(file://…)` |
| `type=url`, fetched mime is `video/*` or `audio/*` | `.directVideo` / `.directAudio(remote)` |
| `type=url`, host matches embed pattern           | `.embed(embed-url)` |
| anything else                                    | `.none` |

Mime for remote URLs comes from the existing extracted-text fetch path
— if the response Content-Type isn't HTML, stash records the mime on
the item, and the resolver reads it.

#### Embed-host patterns

| Host       | URL match                                    | Embed URL                                                |
|---|---|---|
| YouTube    | `youtube.com/watch?v=ID`, `youtu.be/ID`, `youtube.com/shorts/ID` | `https://www.youtube.com/embed/<ID>`                    |
| Vimeo      | `vimeo.com/<ID>`                             | `https://player.vimeo.com/video/<ID>`                    |

Add hosts as the user encounters them. Don't preemptively cover hosts
the user hasn't actually captured.

#### Playability gate

Direct media is gated by `AVAsset(url:).isPlayable`. Unsupported codecs
(raw OGG/Vorbis on older macOS, etc.) gracefully fall back to a
"Open in default app" button. Embed hosts are assumed playable; if
the WKWebView fails to load, the user still has the original URL.

Both direct players honor `space` for play/pause when the detail view
has focus.

### Rule action

New action: `set_thumbnail`. Shape:

```yaml
- match: …
  actions:
    - set_thumbnail: auto       # run extraction; no-op if nothing
    - set_thumbnail:            # explicit URL
        url: https://example.com/img.jpg
    - set_thumbnail:            # explicit file path
        path: /Users/me/img.png
```

Automation no-user-present case: when `auto` finds multiple candidates
and the top score is within tolerance of the runner-up, take the top
candidate silently (don't queue a UI prompt during a non-interactive
run). The user can still override later from the detail view.

---

## Phased rollout

Each phase is independently shippable.

### Phase 1 — Foundations: thumbnails + inline players (file + direct stream)

The mechanical parts that don't depend on URL HTML extraction or
embed hosts.

- Go: add `thumbnail_path` column to `items`; default migration for
  existing rows; cleanup on item delete.
- Go: `stash thumbnail generate <id>` / `--all` for batch generation;
  `stash thumbnail set <id> --url … | --file …` for manual override.
- Swift: `ThumbnailService` actor — orchestrates generation via
  QuickLook, AVAssetImageGenerator (video frame), AVAsset album-art
  extraction (audio), Vision saliency crop, ImageIO encode.
- Swift: detail view renders thumbnail block at top; manual override
  drop target + paste menu.
- Swift: `MediaResolver` service for file items + direct-stream URLs;
  `VideoPlayer` for `.directVideo`, custom audio bar for
  `.directAudio`; `isPlayable` gating with "Open in default app"
  fallback.
- Swift: list-row thumbnail (resize on the fly from canonical 512px).
- Tests: thumbnail round-trip; QL fallback; resolver mime branching;
  player render gating.

### Phase 2 — URL thumbnail extraction + embed-host players

- Go: HTML extractor in `internal/extract` (or wherever the existing
  text extractor lives) — og/twitter/schema/apple-touch/in-page.
- Go: scoring + quality floor; returns ranked candidate list.
- Go: `stash thumbnail fetch <id>` (single) and integration into the
  URL-add path so capture-time auto-extraction happens for free.
- Swift: detail-view "Re-fetch thumbnail" button next to existing
  re-fetch.
- Swift: candidate picker sheet when extraction returns ambiguous
  set; surfaces source URL + dimensions per candidate.
- Swift: extend `MediaResolver` with embed-host pattern matching
  (YouTube, Vimeo); WKWebView-based embed player.

### Phase 3 — Rule action

- Go: `set_thumbnail` action in `internal/rules` with three shapes
  (auto / url / path).
- Go: rule-engine integration; capture.log entries.
- Swift: rule UI editor adds the new action type.
- Tests: rule fires correctly; auto-mode silently picks top in
  non-interactive run.

### Phase 4 — Grid / Pinterest view (deferred)

Standalone phase, only meaningful once Phases 1-2 are widely populated.

- Swift: view-mode toggle on `ItemListView` — list vs grid.
- Grid renders `LazyVGrid` of thumbnail tiles with title overlay.
- Tile menu == row menu (same right-click options).
- Persists per-collection so a "Mark's favorite fishing spots"
  collection remembers grid mode while the main library stays as a
  list.

### Phase 5 — LLM tiebreaker (deferred, conditional)

Only build if Phase 2 multi-candidate picker fires often enough to
annoy. Foundation Models (Apple Silicon, AI-enabled) gets the
candidate set + page context, returns a typed pick. Fallback to
deterministic top score on Intel / non-AI hosts.

---

## Open questions

- Thumbnail format: JPEG vs WebP. Default JPEG; revisit if disk
  becomes an issue.
- Should the `image` type also start using the post-process pipeline
  (saliency-crop into a square thumbnail) instead of always rendering
  the raw image? Probably yes for the grid; raw image still renders
  in the detail preview.
- Audio waveform thumbnail vs album-art-or-badge: waveform is
  prettier in a grid but adds a non-trivial dependency or a custom
  renderer. Defer until grid view is real.

## Out of scope (per user)

- iOS/iPad capture or playback.
- Backup of thumbnails specifically — `goback` covers the whole
  filestore.
