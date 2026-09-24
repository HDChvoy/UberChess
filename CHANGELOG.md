# Changelog

All notable changes to ÜberChess. Versions follow `MAJOR.MINOR.PATCH-stage`.

## [0.2.0-alpha] — work in progress (snapshot pushed 2026-09-22)

A mid-development snapshot of the presentation pass. It's playable from source, but there's no packaged build for it yet.

### Added
- **Tap-in** (replaces Revive). Sub a piece from your bench onto the board in place of one of your own, and the replaced piece goes to your bench. 3 subs per match, cost = $1 + 2 × value gained. Kings, Grounded pieces and pawns onto the promotion rank are blocked. Includes a SUBS meter in the gutter.
- **FX system** (`fx.gd`). All animation now runs through one module with a FULL / REDUCED / OFF intensity setting.
  - Check alert: a cast plus a persistent hold on the checked king.
  - Knight leap: an arc, two front flips, a ground shadow and a crash landing.
- **Resign button**, synced over the network so both clients end the match the same way.
- **On-screen refusal banners.** When an action is blocked, the game now tells you why instead of silently doing nothing.
- **Pixel-font typography**: Poxast for the UI, Merchant Copy for tooltips and prose, 3D-Thirteen for the turn banner. All text size is controlled by one `UI_FONT_SCALE` dial.
- **Rainbow board.** The hue sweeps the diagonals corner to corner, and the light/dark checker pattern is kept through brightness.
- **ÜberBot opening book** (`UberbotOpenings.gd`).

### Changed
- **ÜberBot rewrite.** The engine is now split into three files:
  - `uber_bot.gd` handles search: negamax, quiescence and the Zobrist transposition table.
  - `UberbotStrategy.gd` plans each turn.
  - `UberbotPowerupPolicy.gd` is a rule book for power-up decisions, and the search can veto its picks.
  - Difficulty is now two dials: search depth sets strength, and `aggression` sets how freely the bot spends power-ups. The dozen old tuning knobs are gone.
  - The bot's whole turn fits a fixed 4-second budget.
- **Shop UI redesign**, with live affordability colors and a readable prose tooltip.
- **Captured pieces are now the "bench"**: each side's losses, which Tap-in draws from.
- **Online protocol**: `REVIVE` is replaced by `TAP_IN`.

### Removed
- **Revive** power-up (replaced by Tap-in).

### Compatibility
- **Online play is not compatible with the v0.1-alpha build**, because the wire protocol changed. Both players need the same version.

### Still open in this snapshot
- Tap-in bench-to-board animation
- Movement animations for the other five piece types
- Power-up cast effects
- Themes
- Options screen
- Sound

## [0.1-alpha] — first public release

- Full chess rules: castling, en passant, promotion, check/checkmate/stalemate
- 10 power-ups with a gold economy and slot-based inventory
- ÜberBot AI: iterative-deepening negamax with alpha-beta, quiescence and a transposition table
- Online multiplayer through a WebSocket relay on Railway
- Local 2-player, vs ÜberBot (Easy / Normal / Hard / Über) and online modes
- Windows `.exe` on the Releases page
