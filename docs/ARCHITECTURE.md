# Architecture

Token Tracker is a single-window SwiftUI macOS app with three independent "stores"
(one per provider) feeding three dashboard views, plus a shared settings screen.

```
TokenTrackerApp (@main)
└── RootView  ── NavigationSplitView
    ├── Sidebar: Claude · Codex · DeepSeek · Settings
    └── Detail:
        ├── ClaudeDashboardView   ← ClaudeStore
        ├── CodexDashboardView    ← CodexStore
        ├── DeepSeekDashboardView ← DeepSeekStore
        └── SettingsView          ← all three stores
```

Each store is an `@MainActor ObservableObject`. Scanning/network work happens on a
background `Task`, then results are published on the main actor. A timer in `RootView`
refreshes every store on the chosen interval.

## Data sources & schemas

### Claude — `~/.claude/projects/**/*.jsonl`
Each line is one log event. Assistant messages contain:

```jsonc
{
  "type": "assistant",
  "timestamp": "2026-06-19T07:04:12.248Z",
  "sessionId": "45f013e6-…",
  "cwd": "/Users/you/project",
  "message": {
    "model": "claude-opus-4-8",
    "usage": {
      "input_tokens": 3772,
      "output_tokens": 1190,
      "cache_creation_input_tokens": 2454,
      "cache_read_input_tokens": 15840
    }
  }
}
```

`ClaudeStore.scan` walks the tree, decodes only the fields above, and emits one
`UsageRecord` per assistant message. A record's `total = input + output + cacheCreate + cacheRead`.
Aggregations (session / hour / day / model) are computed from the record list.

### Codex — `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
Relevant line types:

- `session_meta` → session `id`, `cwd`
- `turn_context` → `model` (e.g. `gpt-5.2-codex`), `cwd`
- `event_msg` with `payload.type == "token_count"`:

```jsonc
{
  "type": "event_msg",
  "timestamp": "2026-02-02T20:10:51.952Z",
  "payload": {
    "type": "token_count",
    "info": {
      "total_token_usage": { "input_tokens": …, "cached_input_tokens": …,
                             "output_tokens": …, "reasoning_output_tokens": …,
                             "total_tokens": … },
      "last_token_usage":  { … },
      "model_context_window": 258400
    },
    "rate_limits": {
      "primary":   { "used_percent": 0.0, "window_minutes": 300,   "resets_at": 1770080844 },
      "secondary": { "used_percent": 0.0, "window_minutes": 10080, "resets_at": 1770667644 },
      "credits":   { "has_credits": false, "balance": null, "plan_type": null }
    }
  }
}
```

**Important:** `total_token_usage` is **cumulative per session** and the same
`last_token_usage` is often repeated across consecutive `token_count` events.
Summing `last_token_usage` over-counts (verified: 77,669 vs. a true 45,985).
`CodexStore.scan` therefore sorts the events by time and computes **deltas of the
cumulative fields**, emitting one `CodexRecord` per non-zero turn. Per-category totals
(`input`, `cachedInput`, `output`, `reasoning`) are delta'd the same way. Because
`total = input + output` in Codex's accounting (cached input ⊂ input, reasoning ⊂ output),
the record total is `input + output`.

The most recent `rate_limits` block is kept and shown as gauges with reset times.

### DeepSeek — `https://api.deepseek.com/user/balance`
A `GET` with `Authorization: Bearer <key>` returns:

```jsonc
{ "is_available": true,
  "balance_infos": [ { "currency": "USD", "total_balance": "10.00",
                       "granted_balance": "0.00", "topped_up_balance": "10.00" } ] }
```

The endpoint only exposes the *current* balance, so `DeepSeekStore` records a
`BalanceSnapshot` on every refresh into
`~/Library/Application Support/TokenTracker/deepseek_snapshots.json`.
"Credit used" = highest historical balance − current balance (peak-relative, so a
top-up doesn't make usage go negative). Per-day usage = first − last snapshot of each day.

## Aggregation reference

| Metric        | Claude / Codex                                   | DeepSeek                         |
|---------------|--------------------------------------------------|---------------------------------|
| Total         | Σ record totals                                  | peak balance − current balance  |
| Today         | Σ records since local midnight                   | first − last snapshot today     |
| This hour     | Σ records in the current clock hour              | —                               |
| Per session   | group records by `sessionId`                     | —                               |
| Per day/hour  | bucket records into fixed-width time windows     | snapshot deltas per day         |
| Per model     | group records by `model`                         | —                               |

## Build & packaging

`build.sh` compiles all of `Sources/*.swift` with `swiftc -parse-as-library` against the
Command-Line-Tools SDK (SwiftUI + Charts ship inside it), assembles a `.app` bundle
with a generated `Info.plist`, renders an icon via `Tools/makeicon.swift` + `iconutil`,
ad-hoc code-signs the bundle, and builds a `UDZO` DMG with `hdiutil`. No Xcode project
or `xcodebuild` is required.

## Adding another provider

1. Create a `FooStore` (`ObservableObject`) with a `scan`/`refresh` and the same
   aggregation helpers (`perDay`, `perHour`, `sessions`, `models`).
2. Create a `FooDashboardView` reusing `Card`, `StatTile`, `SectionTitle`, `StatRow`.
3. Add a `case foo` to `Section`, instantiate the store in `TokenTrackerApp`, and wire
   it into `RootView`'s switch, `onAppear`, timer, and footer.
