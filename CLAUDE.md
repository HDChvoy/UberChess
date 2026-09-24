# ÜBERCHESS — notes for Claude

Godot 4 / GDScript. A chess variant with power-ups, a gold economy, an AI opponent,
and online multiplayer over a WebSocket relay. Solo project (Henry).

## Read this first
`Master_Game_Script_GDD.txt` in this folder is the design authority, and it is kept
honest with status tags: **[BUILT]** ships today, **[PARTIAL]** has named gaps,
**[DESIGN]** is spec only — do not assume it exists in code, **[FROZEN]** is closed.
When a request touches a system, grep the GDD for that section before the code.

Current focus per the GDD: the **presentation pass** — FX system (`fx.gd`), themes,
options screen. Tap-in has LANDED (Revive is gone; GDD 3.2 and 8.5 are [BUILT]); only
its FX beat is still open, waiting on `fx.gd`. The UberBot is FROZEN on strength.

## File map
| File | Role |
|---|---|
| `game.gd` | ~2,900 lines. Board, rules, UI, shop, economy, animation, networking. Everything. |
| `uber_bot.gd` | Search engine: negamax, quiescence, make/unmake, eval, Zobrist TT. |
| `UberbotStrategy.gd` | Assembler: `plan_turn`, opening-book path, rules/veto loop. |
| `UberbotPowerupPolicy.gd` | The rule book. Open this when the bot misuses a power-up. |
| `UberbotOpenings.gd` | 96-line opening book, indexed by position signature. |
| `GameConfig.gd` | Autoload. Per-match config from the menu; owns `BOT_TURN_SECONDS`. |
| `fx.gd` | `FXPlayer`. All animation. game.gd calls `fx.play()` and knows nothing else. |
| `main_menu.gd` | Menu scene. |

Seam in one line: **the rule book decides, the search vetoes, the strategy assembles.**

## Conventions and traps in game.gd

- **Tabs, not spaces.** The whole file is tab-indented.
- **`:=` cannot infer off an untyped var.** `game_over`, `winner`, `current_turn` etc.
  are plain `var`s (Variant to the compiler), so `var live := not game_over` is a
  *parse error*, not a runtime one — the scene won't load at all. Write
  `var live: bool = not game_over`.
- **`UI_FONT_SCALE`** (top of file) is the single dial for all in-game text size. The
  gutter's vertical offsets are multiplied by it too, so spacing tracks the font.
- **Animation goes in `fx.gd`, never in game.gd.** game.gd owns two guarded helpers,
  `_fx_play()` and `_fx_sync_check()`; every FX call goes through them so the null check
  lives in one place. fx asks game for `_square_center()` and `_piece_node_at()` and
  nothing else — keep that dependency one-way.
- **`_slide_piece` is the single movement animation** for normal moves AND Cheat-
  puppeted ones, and it dispatches on `piece_type` — that is the seam per-piece
  movement hangs off (Knight leaps; see GDD 6.8). Pass `piece_type` at every call site.
- **Tween a piece FROM the piece** (`piece.create_tween()`), so the tween dies with the
  node when `update_visuals()` rebuilds it mid-animation instead of writing to a freed
  object. Persistent markers must be drawn by the FX node itself for the same reason.
- **`update_visuals()` frees children on every redraw** — anything whose name starts
  with `Piece`, that has a `Sprite2D` child, or that is in the `dynamic_overlay` group.
  Persistent UI must avoid all three. Long-lived groups: `slot_display`,
  `captured_display`.
- **Never hardcode an x-offset to sit a control beside another one.** Widths depend on
  `UI_FONT_SCALE` and on how wide the pixel font renders. Use a container (see `TopBar`).
- **Do NOT anchor a gutter row off a label's measured height either.** Poxast reports a
  box far taller than its glyphs (a 19px bank label measures 44px, ~14 of it leading), so
  `get_combined_minimum_size()` lands a row in the empty gap and looks broken. The
  `*_DY` constants are tuned against the RENDERED text; re-check the band by eye after
  touching `UI_FONT_SCALE` or the fonts. The stack has ~5px of slack at four bench rows.
- **Refusals must reach the SCREEN, not just the console.** `show_refusal()` banners
  them. Tap-In read as broken in a real game purely because at $0 gold every swap was
  correctly refused and the only trace was a `print()`. A rule the player cannot see is
  indistinguishable from a bug — and the shop button must go dim in the same breath.
- **A Control's `size` is clamped up to its minimum on assignment,** and an autowrapping
  Label computes its minimum HEIGHT at its minimum WIDTH — the longest single word if you
  leave it at zero. Set `custom_minimum_size.x` to the real box width, then read
  `size.y` BACK after assigning; that is the only height a layout clamp may trust. The
  shop tooltip does both. Getting this wrong measured a 4-line box at 1521px.
  The same trap bit the power-up slots from the other side: a Button's minimum height is
  its font line box PLUS the theme stylebox's vertical margins, so 30px-tall slots
  rendered at 45 on a 30.6 pitch and each one covered the bottom of the one above. Any
  fixed pitch must clear the RENDERED height; `flat = true` hides the box but keeps its
  margins, only `StyleBoxEmpty` overrides remove them.
- **Two fonts, two jobs.** `font_body` (Poxast) is the display face for labels and
  buttons. `font_prose` (Merchant Copy) is for anything that is a SENTENCE — currently
  the shop tooltip. Poxast is genuinely hard to read past a few words. Setting a font
  override also opts a node out of `_apply_body_font_to`.
- **`_scale_text_node` multiplies every `font_size` override by `UI_FONT_SCALE`** after
  the fact, so pass RAW sizes to `add_theme_font_size_override` — pre-scaling shrinks
  text twice.
- **`Node2D._input` runs BEFORE Control GUI handling.** A full-screen overlay does not
  by itself stop a click from also reaching the board — gate `_input` with a flag
  (`_confirm_open` does this for the resign dialog).
- **View flip:** `board_state`, all move logic, and the wire protocol use LOGICAL coords.
  Only drawing and click-decoding pass through `_disp()`. Never flip anything else.
- **Tap-in eligibility lives in exactly one function.** `_tapin_targets(owner, type)`
  answers "which of my pieces can this benched piece come on for" — King, Grounded,
  pawn-promotion-rank and per-target affordability all live there. The arm step, the
  highlight pass, `_do_tapin`, `_bot_tapin` and the bot's `_rule_tapin` all call it.
  Add a rule there, never at a call site.
- **The bench is the owner's LOSSES.** `bench["White"]` is what White has lost, not
  what White has taken — `record_capture` files a victim under the victim's color. A
  tapped-out piece is appended to the same list, so `uber_bot._revert_turn` must pop
  the tail BEFORE reinserting at `idx`, or every bench index above the swap shifts.
- **`_finish_turn(color)` is the single turn-swap chokepoint** for moves and tap-ins.
  It early-returns when `game_over` is already true, so a terminal result (king capture,
  resignation) can't be overwritten by an animation finishing late.
- **Input locks:** `game_over`, `is_animating`, `_confirm_open`.

## Networking rules
- `send_to_server()` is the ONLY outbound chokepoint. It no-ops offline and while
  replaying a remote action — that guard is what stops echo loops.
- Inbound: `_net_route()` handles control messages immediately; chess actions queue in
  `_net_inbox` and replay one at a time through `_apply_remote_action()`, which calls the
  SAME local function a human click would, with `net_applying_remote = true`.
- **Adding a networked action means touching both sides.** A broadcast with no matching
  `_apply_remote_action` case desyncs the match silently.
- `_do_rematch()` resets ALL match state. Any new state var must be reset there too.

## Bot timing
The bot's whole turn is a fixed wall-clock budget (`GameConfig.BOT_TURN_SECONDS`, 4.0s),
anchored so the turn-ending action always lands on the deadline regardless of plan
length. The search is spent FROM the budget, not added to it. FX must overlap the gaps,
never extend them — at Über with three actions the gap is ~233ms.

## Known drift
Older notes describe `game.gd` split into `powerup_defs.gd`, `economy.gd`,
`net_client.gd`, `board_view.gd`, `shop_ui.gd`. **None of that is on disk** — it is still
one file. Don't go looking for those modules.

## Working style
`game.gd` is 126 KB — reading it whole costs ~35k tokens. Grep for the function, read the
range around it. Edits go back to the same path in this folder; Henry reloads in Godot.
