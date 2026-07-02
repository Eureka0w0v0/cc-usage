<div align="center">

# CC Usage

**Real-time Claude Code / Codex / Gemini usage in your macOS menu bar**

A native companion app derived from the Usage dashboard of [cc-switch](https://github.com/farion1231/cc-switch)

[简体中文](README.md) | English

<img src="docs/screenshots/menu-bar.png" alt="Menu bar chips" width="420">

</div>

---

## What is this

The Usage dashboard in [cc-switch](https://github.com/farion1231/cc-switch) is great, but it lives inside a tab of the main app. CC Usage makes it **always visible**:

- **Menu bar chips**: today's tokens & cost plus your official 5H / Weekly subscription quota, refreshed every 5 seconds;
- **A standalone main window** embedding cc-switch's **real frontend** (not a lookalike) — numbers, charts and interactions are pixel-identical to upstream.

<div align="center">
<img src="docs/screenshots/main-window.png" alt="Main window" width="720">
<br><br>
<img src="docs/screenshots/menu-bar-panel.png" alt="Menu bar panel" width="340">
</div>

## Features

- ⚡ **Composable menu bar chips**: Tokens & cost for today / last 7 days / last 30 days (D/W/M), plus official 5H / Weekly quota percentages — pick any combination
- 📊 **The real dashboard, 1:1**: the main window runs cc-switch's actual frontend build — Usage Hero, genuine Recharts trend chart (hover tooltips identical to upstream), source/model filters, date ranges, and the Request Logs / Provider Stats / Model Stats tabs
- 🔄 **5-second live refresh**: choose 5/10/30/60s or off; the choice persists, and the menu bar and main window share one refresh cadence so they never disagree
- 🔋 **Official subscription quota**: queries Anthropic's `/api/oauth/usage` with your local Claude Code OAuth credentials, throttled to once per 5 minutes with an in-process shared cache (no 429s); shown from the very first paint
- 🔌 **Live even with cc-switch closed**: a built-in read-only overlay incrementally parses Claude Code session logs and prices them with cc-switch's own pricing table; when cc-switch imports those rows later the overlay drains via exact request-id dedup — verified seamless handoff, zero double counting
- 🪟 **Well-behaved windowing**: a single unique main window; closing it keeps the menu bar resident

## Prerequisites (read this)

> [!IMPORTANT]
> 1. **macOS 14 (Sonoma) or later**;
> 2. [cc-switch](https://github.com/farion1231/cc-switch) (≥ 3.16 recommended) installed — it owns the local database, history and pricing table; this app reads its database **read-only**.
>    **cc-switch does NOT need to be running**: while it's closed, the app incrementally parses Claude Code's session logs (`~/.claude/projects`) itself and overlays the not-yet-imported usage in real time; when cc-switch comes back and imports those rows, the overlay deduplicates by request id and hands off seamlessly with no double counting (importing **new** Codex / Gemini usage still requires cc-switch to run);
> 3. The quota chips/badges require a Claude Code login on this machine (OAuth credentials are read from the Keychain / `~/.claude/.credentials.json`).

## Install

### Option 1: download a Release (recommended)

1. Grab `CC.Usage.app.zip` from [Releases](https://github.com/Eureka0w0v0/cc-usage/releases) and unzip;
2. Drag `CC Usage.app` into Applications;
3. The app is ad-hoc signed (personal open-source project, no paid developer certificate), so clear the quarantine flag before first launch:

```bash
xattr -d com.apple.quarantine "/Applications/CC Usage.app"
```

### Option 2: build from source

Requires full Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```bash
git clone https://github.com/Eureka0w0v0/cc-usage.git
cd cc-usage
bash scripts/build.sh   # generate project → Release build → install to /Applications and launch
```

## Usage notes

- **Menu bar chips**: click the ⚡ icon → expand "Menu Bar Display" → tick what you want (Tokens/Cost each offer Day/Week/Month; Quota offers 5H/Week). The label renders like `D: 42.9M·$34.9 5H: 10%`;
- **Refresh interval**: the ⟳ dropdown in the main-window toolbar; it applies to both the panel and the menu bar, and persists across restarts;
- **Quota update cadence**: the 5H/Week percentages change **at most once per 5 minutes** — the official endpoint is throttled exactly like cc-switch does to avoid rate-limiting your account. Tokens/cost from the local database are the truly-every-5-seconds numbers;
- Date/source/model filters and the three stats tabs behave exactly like upstream cc-switch.

## How it works

```
┌────────────────────────── CC Usage.app ──────────────────────────┐
│                                                                  │
│  Menu bar chips + panel (SwiftUI)     Main window (WKWebView)    │
│        │                                │                        │
│        │                        cc-switch real-frontend bundle   │
│        │                        (built with the embed/ bridge)   │
│        │                                │ invoke(cmd, args)      │
│        ▼                                ▼                        │
│  ┌──────────────────── Swift data layer ────────────────────┐    │
│  │ UsageStore     → read-only ~/.cc-switch/cc-switch.db      │    │
│  │ SessionOverlay → reads ~/.claude/projects session JSONL   │    │
│  │                  (rows cc-switch hasn't imported yet)     │    │
│  │ QuotaCache     → official /api/oauth/usage, 5-min throttle│    │
│  └───────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
     ▲ the only database writer is cc-switch (history + Codex/Gemini)
```

- The main window is not a re-implementation: cc-switch's frontend source plus a thin `invoke` bridge (`embed/`) is compiled by Vite into a single-file `index.html` running in a WKWebView. Tauri `invoke` calls from the frontend are intercepted in Swift and answered straight from the local SQLite database — aggregation semantics faithfully reimplement cc-switch's `usage_stats.rs`;
- While cc-switch is closed, `SessionOverlay` resumes from the line offsets cc-switch recorded in `session_log_sync` and read-only parses the session JSONL tails, mirroring its importer (`session_usage.rs`) rule by rule — parsing, dedup and pricing alike. The pending rows are merged into every query in memory and drain to zero via exact `request_id` dedup once cc-switch imports them: nothing is ever written, nothing is ever counted twice;
- Subscription quota uses your local Claude Code OAuth credentials; results live in one in-process shared cache read by both the menu bar and the panel, which is why the two always agree.

## Rebuilding the panel frontend (optional)

A prebuilt `Sources/App/web-panel/index.html` ships with the repo, so normal builds **don't need this**. To track upstream cc-switch updates:

```bash
git clone https://github.com/farion1231/cc-switch ../cc-switch   # or point to your existing clone
CC_SWITCH_DIR=../cc-switch bash scripts/build-embed.sh
```

The script copies the bridge files under `embed/` into the cc-switch tree (all additive — no upstream file is modified), builds the single-file panel with pnpm + Vite and writes it back into this repo.

## Privacy

- All usage data stays **on your machine**: the app reads cc-switch's SQLite database read-only and uploads nothing;
- The only network request is Anthropic's official quota endpoint `api.anthropic.com/api/oauth/usage` (only when a quota chip/badge is enabled, at most once per 5 minutes);
- OAuth credentials are read locally, never persisted elsewhere, never sent anywhere else.

## Credits & License

- This project is a derivative work of [cc-switch](https://github.com/farion1231/cc-switch) (MIT, © [@farion1231](https://github.com/farion1231)): the main-window panel is built directly from its frontend source, and the statistics semantics mirror its backend line by line. Huge thanks to the original author;
- Released under the [MIT License](LICENSE); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled third-party code.
