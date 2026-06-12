# ÜberChess

Chess, but the pieces have superpowers.

ÜberChess is a fully custom chess engine built from scratch in Godot 4 — standard rules intact, but every game you're earning gold, buying power-ups, and using them to break the rules in calculated ways. Shield your queen. Phase your rook through a wall of pawns. Teleport a threatened piece to safety. Revive a captured knight. Cheat an enemy piece off the board entirely.

---

## What's in it

- **Full chess engine** — castling, en passant, check/checkmate/stalemate, promotion, the works
- **10 power-ups** with a slot-based economy: Ground, Shield, Phase, Teleport, Capture, Super Pawn, Multiply, Negate, Revive, Cheat
- **AI opponent (ÜberBot)** — iterative deepening negamax with alpha-beta pruning, quiescence search, transposition table + Zobrist hashing, piece-square tables, and a search-driven power-up layer that actually thinks before spending
- **Online multiplayer** via a WebSocket relay — create a room, share the code, play
- **Three modes** — Local 2-Player, vs ÜberBot (Easy / Normal / Hard / Über), Online

---

## Status

Early alpha. The game is fully playable end-to-end but rough around the edges — missing sound, limited art, no options screen. Putting it out now specifically to get feedback and real game data.

If something breaks or feels wrong, open an issue.

---

## How to run it

**Option A — Download the build (easiest)**
Grab the latest `.exe` from the [Releases](../../releases) page. Windows only for now. Double-click and play — no install needed. Windows may show a SmartScreen warning since it's unsigned; click "More info → Run anyway."

**Option B — Run from source**
1. Download [Godot 4](https://godotengine.org/download)
2. Clone this repo
3. Open `project.godot` in Godot
4. Hit play

---

## Built with

- [Godot 4](https://godotengine.org/) — GDScript
- WebSocket relay server — Node.js, deployed on [Railway](https://railway.app/)

---

## Roadmap

- Sound and music
- Board themes and piece skins
- Options screen
- Mobile / iOS build
- Better AI (opponent power-up awareness, multi-power-up combos)
- Persistent stats and game history

---

*Solo dev project. All feedback welcome.*
