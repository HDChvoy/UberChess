extends Node

# =============================================================================
# GameConfig — cross-scene settings singleton (AUTOLOAD). The menu writes choices
# here; game.gd / uber_bot.gd / UberbotStrategy.gd read them back after the scene swap.
# SETUP (one-time): Project Settings > Globals(Autoload) tab >
#   Path: res://GameConfig.gd   Node Name: GameConfig   (Enable = on)
# =============================================================================

# --- MATCH MODE ---
enum Mode { TWO_PLAYER, VS_BOT, MULTIPLAYER }
var mode: Mode = Mode.TWO_PLAYER

# --- BOT MATCH SETTINGS (only meaningful when mode == VS_BOT) ---
# Sides are randomized per game via roll_bot_sides(); written fresh each bot match.
var bot_color: String = "Black"     # which side the AI plays
var player_color: String = "White"  # which side the human plays

# --- PRESENTATION ---
# FX intensity. Shipped from day one rather than added later as an accessibility
# bolt-on (GDD 6.5). FULL = every beat. REDUCED keeps the STATE layer, which carries
# information, and guts the cast beats, which carry drama. OFF is silent.
# The Options screen (Section 10) will write this; fx.gd reads it once in _ready.
enum FXMode { FULL, REDUCED, OFF }
var fx_mode: FXMode = FXMode.FULL

# --- DIFFICULTY ---
# Difficulty caps search depth + think time (uber_bot.gd reads these in _init) AND sets how
# freely the bot spends its power-ups (UberbotStrategy hands `aggression` to
# UberbotPowerupPolicy). Those are two independent dials on purpose — see below.
enum Difficulty { EASY, NORMAL, HARD, UBER }
var difficulty: Difficulty = Difficulty.HARD

# Per-tier caps.
#
#   depth / think_ms — the STRENGTH dial. How hard the bot is allowed to think.
#   aggression       — the FLAMBOYANCE dial, 0.0 .. 2.0. How freely it spends its kit.
#                      Named settings live in UberbotPowerupPolicy.PRESETS:
#                        0.40 hoarder · 1.00 measured · 1.45 liberal · 2.00 reckless
#
# THE TWO DIALS RUN IN OPPOSITE DIRECTIONS, DELIBERATELY (GDD 8.6). Depth is what makes the
# bot hard to beat; spending is what makes it fun to watch. An Easy bot that plays shallow
# chess quietly is just weak — an Easy bot that throws power-ups around constantly is a
# character. So the cheap tiers get the loud settings and Hard/Über play tight.
#
# TIMING CONTRACT: think_ms + the veto pass must both fit inside BOT_TURN_SECONDS below, or
# game.gd's turn pacing collapses (see bot_plan_budget_ms). Über was trimmed from 3000 to
# 2400 to leave the veto pass room; at depth 8 with iterative deepening that costs well under
# a ply, and it buys back a bot that still uses its power-ups at the top tier.
const DIFFICULTY_PRESETS := {
	Difficulty.EASY:   {"depth": 2, "think_ms": 250,   "aggression": 2.00, "label": "Easy"},
	Difficulty.NORMAL: {"depth": 4, "think_ms": 800,   "aggression": 1.45, "label": "Normal"},
	Difficulty.HARD:   {"depth": 6, "think_ms": 1800,  "aggression": 1.00, "label": "Hard"},
	Difficulty.UBER:   {"depth": 8, "think_ms": 2400,  "aggression": 1.00, "label": "Über"},
}

func bot_max_depth() -> int:
	return DIFFICULTY_PRESETS[difficulty]["depth"]

func bot_think_ms() -> int:
	return DIFFICULTY_PRESETS[difficulty]["think_ms"]

func bot_powerup_aggression() -> float:
	return float(DIFFICULTY_PRESETS[difficulty]["aggression"])

func difficulty_label() -> String:
	return DIFFICULTY_PRESETS[difficulty]["label"]

# --- BOT TURN PACING ---
# The bot's ENTIRE turn is budgeted to this many seconds of wall-clock, from the moment your
# move ends to the moment its turn-ending action fires — identical whether the plan holds one
# action or three. game.gd spreads the actions across it; UberbotStrategy sizes its veto pass
# to fit inside it. It lives HERE so those two cannot drift apart.
const BOT_TURN_SECONDS := 4.0

# Milliseconds of the turn reserved for the VISIBLE part: the pause you read as thinking, the
# gaps between power-up beats, and the final move's animation. Everything left over is what
# planning (deep search + veto pass) is allowed to spend.
const BOT_PACING_RESERVE_MS := 700

# Accessor rather than a bare const read, because `"NAME" in node` does NOT see GDScript
# constants — they are not properties — so game.gd would silently fall back to its own copy.
func bot_turn_seconds() -> float:
	return BOT_TURN_SECONDS

# How long plan_turn may block in total. UberbotStrategy stamps the clock on entry and stops
# its veto pass at this mark, so a slow deep search shortens the veto rather than overrunning
# the turn. Never negative: a badly-configured think_ms costs pacing, not correctness.
func bot_plan_budget_ms() -> int:
	return maxi(200, int(BOT_TURN_SECONDS * 1000.0) - BOT_PACING_RESERVE_MS)

# --- HELPERS THE MENU CALLS ---

func set_multiplayer() -> void:
	mode = Mode.MULTIPLAYER

func is_multiplayer() -> bool:
	return mode == Mode.MULTIPLAYER

func set_two_player() -> void:
	mode = Mode.TWO_PLAYER

func set_vs_bot(diff: Difficulty) -> void:
	mode = Mode.VS_BOT
	difficulty = diff
	roll_bot_sides()

# Randomly assign the human and bot to White/Black, once per bot match.
func roll_bot_sides() -> void:
	if randi() % 2 == 0:
		player_color = "White"
		bot_color = "Black"
	else:
		player_color = "Black"
		bot_color = "White"

func is_bot_match() -> bool:
	return mode == Mode.VS_BOT
