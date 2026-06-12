extends Node

# =============================================================================
# GameConfig — cross-scene settings singleton (AUTOLOAD). The menu writes choices
# here; game.gd / uber_bot.gd read them back after the scene swap.
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

# --- DIFFICULTY ---
# Difficulty only caps search depth + think time; uber_bot.gd reads these in _init().
enum Difficulty { EASY, NORMAL, HARD, UBER }
var difficulty: Difficulty = Difficulty.HARD

# Per-tier caps. Time budgets (think_ms) have been reduced for a snappier response.
const DIFFICULTY_PRESETS := {
	Difficulty.EASY:   {"depth": 2, "think_ms": 250,   "label": "Easy"},
	Difficulty.NORMAL: {"depth": 4, "think_ms": 800,   "label": "Normal"},
	Difficulty.HARD:   {"depth": 6, "think_ms": 1800,  "label": "Hard"},
	Difficulty.UBER:   {"depth": 8, "think_ms": 3000,  "label": "Über"},
}

func bot_max_depth() -> int:
	return DIFFICULTY_PRESETS[difficulty]["depth"]

func bot_think_ms() -> int:
	return DIFFICULTY_PRESETS[difficulty]["think_ms"]

func difficulty_label() -> String:
	return DIFFICULTY_PRESETS[difficulty]["label"]

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
