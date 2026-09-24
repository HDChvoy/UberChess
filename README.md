# ÜberChess

Chess, but the pieces have superpowers.

ÜberChess is a fully custom chess engine built from scratch in Godot 4 — standard rules intact, but every game you're earning gold, buying power-ups, and using them to break the rules in calculated ways. Shield your queen. Phase your rook through a wall of pawns. Teleport a threatened piece to safety. Tap a benched knight back into the game. Cheat an enemy piece off the board entirely.

> **Current version: v0.2.0-alpha (work in progress).** The `main` branch is a mid-development snapshot of the presentation pass. The last packaged build is [v0.1-alpha](../../releases). See [CHANGELOG.md](CHANGELOG.md) for what's changed.

---

## What's in it

- **Full chess engine** — castling, en passant, check/checkmate/stalemate, promotion, the works
- **9 slotted power-ups** with a gold economy: Ground, Shield, Phase, Teleport, Capture, Super Pawn, Multiply, Negate, Cheat
- **Tap-in** — sub a piece from your bench back onto the board in exchange for one of yours (3 subs per match; cost scales with the value you gain). Replaces Revive.
- **AI opponent (ÜberBot)** — iterative deepening negamax with alpha-beta pruning, quiescence search, transposition table + Zobrist hashing, piece-square tables, an opening book, and a rule-based power-up policy that the search can veto
- **Online multiplayer** via a WebSocket relay — create a room, share the code, play
- **Three modes** — Local 2-Player, vs ÜberBot (Easy / Normal / Hard / Über), Online
- **FX system** — check alert, knight leap animation, with more effects landing

---

## Status

Early alpha, mid-development. The game is playable end-to-end, but this snapshot is partway through a presentation pass (animation, themes, options screen), so expect rough edges.

**Online note:** v0.2 changed the multiplayer protocol (Revive → Tap-in). A v0.2 build can't play online against the v0.1-alpha `.exe`. Both players need to be on the same version.

If something breaks or feels wrong, open an issue.

---

## How to run it

**Option A — Download the build (easiest)**
Grab the latest `.exe` from the [Releases](../../releases) page (currently v0.1-alpha). Windows only for now. Double-click and play — no install needed. Windows may show a SmartScreen warning since it's unsigned; click "More info → Run anyway."

**Option B — Run from source (latest work in progress)**
1. Download [Godot 4.6](https://godotengine.org/download)
2. Clone this repo
3. Open `project.godot` in Godot
4. Hit play

---

## Built with

- [Godot 4](https://godotengine.org/) — GDScript
- WebSocket relay server — Node.js, deployed on [Railway](https://railway.app/)

---

## Roadmap

- **In progress:** FX & animation pass (per-piece movement, power-up cast effects, payoff beats)
- Board themes and piece skins (Rainbow / Noir / Neon / Cathedral / Terracotta)
- Options screen
- Sound and music
- Win-condition rework — the King as a capturable piece
- ÜberBot personalities (The Broker, The Bruiser, The Ghost, The Fixer)
- Mobile / iOS build
- Persistent stats and game history

---

*Solo dev project. All feedback welcome.*

© 2026 Henry David Chvoy. All rights reserved. This source code is made available for viewing purposes only. No license is granted to use, copy, modify, or distribute.
