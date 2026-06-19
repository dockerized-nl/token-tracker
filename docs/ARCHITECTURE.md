# Architecture

Token Tracker is a single-window SwiftUI macOS app with one independent "store"
per provider feeding a matching dashboard view, plus a shared settings screen.

```
TokenTrackerApp (@main)
└── RootView  ── NavigationSplitView
    ├── Sidebar: Claude · Codex · Copilot · DeepSeek · Settings
    └── Detail:
        ├── ClaudeDashboardView   ← ClaudeStore
        ├── CodexDashboardView    ← CodexStore
        ├── CopilotDashboardView  ← CopilotStore
        ├── DeepSeekDashboardView ← DeepSeekStore
        └── SettingsView          ← all stores
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

### Copilot — `~/.copilot/session-state/<session-id>/events.jsonl`
The GitHub Copilot CLI writes one event per line. Relevant event `type`s:

- `session.start`        → `data.sessionId`, `data.model`, `data.cwd`
- `session.model_change` → `data.newModel`
- `assistant.message` with `data.usage`:

```jsonc
{
  "type": "assistant.message",
  "timestamp": "2026-06-19T07:04:12.248Z",
  "data": {
    "model": "claude-sonnet-4.6",
    "usage": {
      "prompt_tokens": 22344,
      "completion_tokens": 12,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 0,
      "total_tokens": 22356
    }
  }
}
```

- `session.shutdown` with per-model `modelMetrics`:

```jsonc
{
  "type": "session.shutdown",
  "timestamp": "…",
  "data": {
    "modelMetrics": {
      "claude-sonnet-4.6": {
        "requests": { "count": 1, "cost": 1 },
        "usage": { "inputTokens": 22344, "outputTokens": 12,
                   "cacheReadTokens": 0, "cacheWriteTokens": 0 }
      }
    }
  }
}
```

`CopilotStore.scan` walks the tree (the containing folder is the session id),
tracks the current model across `session.start` / `session.model_change`, and emits
one `UsageRecord` (the same struct Claude uses) per `assistant.message`. Token
categories are treated as disjoint, so `total = input + output + cacheCreate + cacheRead`.
The GitHub **premium-request** units in `session.shutdown` (`modelMetrics.*.requests.cost`,
with `.count`) have no per-message equivalent and are summed separately for the
"Premium Requests" tile. For older CLI builds that emit only `session.shutdown`, the
scanner falls back to synthesising one record per model from `modelMetrics.*.usage`
(splitting cache out of `inputTokens` to keep the categories disjoint).

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

| Metric        | Claude / Codex / Copilot                         | DeepSeek                         |
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
