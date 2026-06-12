extends Node2D

# ==========================================
# 1. IDENTITY: VARIABLES & DATA STRUCTURES
# ==========================================

# --- ECONOMY & SHOP DATA ---
var player_gold = {"White": 10, "Black": 10}
# Pieces each side has captured (for the trays by each bank). Each entry:
# {"color": <captured piece's color>, "type": ..., "is_super_pawn": bool}
var captured_pieces = {"White": [], "Black": []}
var white_gold_label = Label.new()
var black_gold_label = Label.new()
var powerup_classes = {
	"Phase": "Movement", "Teleport": "Movement",
	"Super Pawn": "Attack", "Capture": "Attack",
	"Ground": "Defense", "Shield": "Defense",
	"Multiply": "Economy", "Negate": "Economy",
	"Revive": "Uber", "Cheat": "Uber"
}
var powerup_costs = {
	"Ground": 3, "Shield": 5, "Phase": 6, "Teleport": 8,
	"Super Pawn": 10, "Capture": 7, "Multiply": 2, "Negate": 4, "Cheat": 15, "Revive": 0
}
# How many of the OWNER'S upcoming turns a buff survives into.
# 1 = lasts through the opponent's single reply, then expires when control returns.
# -1 = permanent, never expires. Default 1.
var powerup_durations = {
	"Ground": 1, "Shield": 1
}
var current_turn = "White"
var selected_square = Vector2(-1, -1) # -1,-1 means nothing is selected right now
var en_passant_target = Vector2(-1, -1) # -1,-1 means no ghost trail exists right now

# --- SHOP STATE & MEMORY ---
var held_powerup = "" # Stores the name of the item currently being dragged
var used_classes_this_turn = [] # Remembers if we already bought 'Defense', 'Movement', etc.
var shop_buttons = {}

# --- POWER-UP SLOTS (shared-visibility inventory) ---
# Up to 3 bought-but-unused power-ups per side. Each entry: {"name": <str>, "ready": <bool>}.
# ready=false the turn it's bought; flips true when control returns to the owner, so a
# power-up can never be used on the same turn it was purchased. Both rows are always drawn.
const MAX_SLOTS = 3
var powerup_slots = {"White": [], "Black": []}
var held_slot_index = -1  # which of the current player's slots is picked up for use (-1 = none)
# Square holding an opponent piece just relocated by Cheat — the cheater cannot
# capture it for the rest of this turn. Cleared at the turn swap.
var cheat_protected_square = Vector2(-1, -1)
var game_over = false
var is_animating = false  # true while a piece slide tween is running; blocks input
var winner = ""
var is_draw = false  # true on stalemate (or other draws later)
var in_check = false  # true when the side to move is currently in check
# When a revive is awaiting tile placement, holds {owner, index, type, cost, candidates}.
# Empty dict means no revive is in progress.
var revive_pending = {}

# --- AI OPPONENT ---
# These defaults are overridden in _ready() by GameConfig (set from the main menu).
# Kept as sane fallbacks so the scene still runs if launched directly in the editor.
var vs_bot := true        # set from GameConfig.is_bot_match()
var bot_color := "Black"  # set from GameConfig.bot_color
var bot                   # the UberBot instance

# --- ONLINE MULTIPLAYER (Phase 1 WebSocket relay) ---
# The game connects to a central relay (wss URL below). The relay forwards messages
# between the two clients unchanged — it does NOT understand chess. Each client runs
# the full local rules engine and is authoritative for its OWN color: a local action
# is sent to the server (relayed to the opponent) and then executed locally; an
# opponent action arrives over the socket and is replayed by calling the same local
# function with net_applying_remote=true (so the replay does NOT re-broadcast and echo).
const SERVER_URL := "wss://uberchess-relay-production.up.railway.app"
var is_multiplayer := false          # set from GameConfig in _ready()
var my_side := "White"                   # which side the LOCAL player controls online
var net_match_started := false       # true after MATCH_START; gates board input
var net_applying_remote := false     # true while replaying an opponent's networked action
var bot_buying := false               # true while the bot routes its OWN purchase through the shop handler
var ws: WebSocketPeer = null         # the live relay connection
var _net_open_seen := false          # one-shot: socket reached OPEN
var _net_closed_seen := false        # one-shot: socket reached CLOSED
var _net_inbox: Array = []           # queued opponent chess-action messages (Dictionaries)
var _net_pumping := false            # true while the inbox pump coroutine is draining
var room_code := ""                  # this match's room code (creator side)
var _net_promo_choice := ""          # buffered remote promotion pick (it can arrive before the replay is ready to await it)
var board_flipped := false           # true when the local view is rotated 180° (you play Black)
# --- REMATCH (within the same room, after a game ends) ---
var rematch_local := false           # this player has clicked Rematch
var rematch_remote := false          # the opponent has requested a rematch
var _rematch_status: Label = null    # status line in the rematch panel
var _rematch_button: Button = null   # the Rematch button (disabled once requested)

# Lobby UI node references (built in _build_lobby_ui when is_multiplayer).
var _lobby: CanvasLayer = null
var _lobby_status: Label = null
var _lobby_code_label: Label = null
var _lobby_code_input: LineEdit = null
var _lobby_create_btn: Button = null
var _lobby_join_btn: Button = null

# --- BOARD SETTINGS ---
const TILE_SIZE = 100
const BOARD_OFFSET = Vector2(300, 100)

# --- LEFT-GUTTER LAYOUT ---
# Each player owns a vertical band. Within it, three clearly separated sections stack
# top->bottom from the bank label: BANK, then POWER-UP SLOTS, then CAPTURED PIECES.
# Captures grow downward and stay inside the band (max 15 captures = 4 rows). The two
# bands don't overlap, so nothing interferes with clicking a captured piece to revive.
const GUTTER_X := 50.0
const SLOTS_HEADING_DY := 38.0    # heading offset below the bank label
const SLOTS_FIRST_DY := 60.0      # first slot button offset below the bank label
const SLOT_STEP_Y := 32.0         # vertical pitch between slot buttons
const CAPTURED_HEADING_DY := 162.0  # captured-tray heading offset below the bank label
const CAPTURED_FIRST_DY := 184.0    # first captured-icon row offset below the bank label

# --- PIECE & BOARD DATA ---
var piece_rules = {
	"Pawn": {"value": 1, "revive_cost": 4},
	"Knight": {"value": 3, "revive_cost": 6},
	"Bishop": {"value": 3, "revive_cost": 6},
	"Rook": {"value": 5, "revive_cost": 10},
	"Queen": {"value": 9, "revive_cost": 18},
	"King": {"value": 0, "revive_cost": 0} 
}

var starting_positions = {
	"Black": {
		"Rook": [Vector2(0, 0), Vector2(7, 0)],
		"Knight": [Vector2(1, 0), Vector2(6, 0)],
		"Bishop": [Vector2(2, 0), Vector2(5, 0)],
		"Queen": [Vector2(3, 0)],
		"King": [Vector2(4, 0)],
		"Pawn": [Vector2(0, 1), Vector2(1, 1), Vector2(2, 1), Vector2(3, 1), Vector2(4, 1), Vector2(5, 1), Vector2(6, 1), Vector2(7, 1)]
	},
	"White": {
		"Rook": [Vector2(0, 7), Vector2(7, 7)],
		"Knight": [Vector2(1, 7), Vector2(6, 7)],
		"Bishop": [Vector2(2, 7), Vector2(5, 7)],
		"Queen": [Vector2(3, 7)],
		"King": [Vector2(4, 7)],
		"Pawn": [Vector2(0, 6), Vector2(1, 6), Vector2(2, 6), Vector2(3, 6), Vector2(4, 6), Vector2(5, 6), Vector2(6, 6), Vector2(7, 6)]
	}
}

var board_state = {}

const PIECE_SCENE = preload("res://piece.tscn")

# Modifier -> sprite tint. Shield is not tinted; it is drawn as a translucent
# bubble over the piece in update_visuals() instead.
const MOD_TINTS = {
	"Ground": Color(0.6, 0.4, 0.2),       # earthy brown
	"Phase": Color(1.0, 0.9, 0.15, 0.6),  # translucent yellow ghost
	"Teleport": Color(0.6, 0.2, 0.85),    # purple
	"Multiply": Color(0.2, 0.85, 0.2),    # green - boosted value
	"Negate": Color(0.9, 0.2, 0.2),       # red - worthless to capture
	"Capture": Color(1.0, 0.2, 0.7),      # magenta - primed to strike
}

# Fired by the promotion picker UI when the player taps a piece choice.
# execute_move() awaits this signal before continuing past the promotion step.
signal promotion_chosen(piece_type: String)

# ==========================================
# 2. SETUP & BOT TURN DRIVER
# ==========================================

func _maybe_let_bot_move():
	if not vs_bot or game_over or current_turn != bot_color:
		return
	# Brief pause so your move renders first and the bot feels like it's thinking.
	await get_tree().create_timer(1.6).timeout
	if game_over or current_turn != bot_color:
		return

	# plan_turn() is a heavy blocking search; yield one frame after it so the first
	# slide tween animates smoothly.
	var plan = bot.plan_turn(bot_color)
	await get_tree().process_frame
	for act in plan:
		if game_over or current_turn != bot_color:
			break
		match act["kind"]:
			"use":
				_bot_use(act["item"], act["target"])
				await get_tree().create_timer(1.5).timeout  # let you see each power-up land
			"cheat":
				await _bot_cheat(act["from"], act["to"])
				await get_tree().create_timer(1.5).timeout
			"buy":
				_bot_buy(act["item"])
				await get_tree().create_timer(1.5).timeout
			"revive":
				_bot_revive(act["index"], act["tile"])  # this ends the turn
			"move":
				# MUST await: the turn-swap happens inside execute_move; exiting early
				# would let the safety net fire a second move mid-animation.
				await execute_move(act["from"], act["to"])  # this ends the turn

	# SAFETY NET: if the plan never swapped the turn, force a fallback move so the
	# game can't hang on the bot. Runs ONCE, after the loop.
	if not game_over and current_turn == bot_color:
		print("⚠️ Bot plan produced no completed move — playing a fallback.")
		await _bot_fallback_move()

# Bot purchases route through the same shop handler the human uses.
func _bot_buy(item_name: String) -> bool:
	var before = powerup_slots[bot_color].size()
	bot_buying = true
	_on_shop_item_pressed(item_name, int(powerup_costs.get(item_name, 9999)))
	bot_buying = false
	return powerup_slots[bot_color].size() > before

# Bot power-up use: stage the slot as "held" and route through apply_powerup, so the
# bot obeys exactly the same rules (class limit, stacking, targets) as a human click.
func _bot_use(item_name: String, target: Vector2) -> bool:
	if powerup_classes[item_name] in used_classes_this_turn:
		return false
	var idx = _find_ready_slot(bot_color, item_name)
	if idx == -1:
		return false
	held_powerup = item_name
	held_slot_index = idx
	if apply_powerup(target):
		show_bot_action_banner("Used " + item_name + " on its " + board_state[target]["type"])
		return true
	held_powerup = ""
	held_slot_index = -1
	return false


# Bot Cheat: validate the puppet, stage the slot as held, run the shared execute_cheat_move.
func _bot_cheat(from_pos: Vector2, to_pos: Vector2) -> bool:
	if "Uber" in used_classes_this_turn or not board_state.has(from_pos):
		return false
	var piece = board_state[from_pos]
	if piece["color"] == bot_color or piece["type"] == "King":
		return false
	if board_state.has(to_pos) and board_state[to_pos]["type"] == "King":
		return false
	var idx = _find_ready_slot(bot_color, "Cheat")
	if idx == -1:
		return false
	held_powerup = "Cheat"
	held_slot_index = idx
	await execute_cheat_move(from_pos, to_pos)
	show_bot_action_banner("Cheated — moved your " + piece["type"])
	return true

# Bot-side Revive: brings a fallen piece back from the bot's tray onto a free starting
# square, mirroring _do_revive. This ENDS the turn (reviving is the bot's move).
func _bot_revive(index: int, tile: Vector2) -> bool:
	if index < 0 or index >= captured_pieces[bot_color].size():
		return false
	if board_state.has(tile):
		return false
	var cap = captured_pieces[bot_color][index]
	var ptype = cap["type"]
	var cost = piece_rules[ptype]["revive_cost"]
	if player_gold[bot_color] < cost:
		return false
	# Tentatively place, then verify it doesn't leave the bot's King in check.
	board_state[tile] = {"type": ptype, "color": bot_color, "modifier": "", "modifier_duration": 0, "is_super_pawn": false, "has_moved": false, "is_revived": true}
	if is_in_check(bot_color):
		board_state.erase(tile)
		return false
	player_gold[bot_color] -= cost
	captured_pieces[bot_color].remove_at(index)
	print("🤖✨ Bot REVIVED its ", ptype, " at ", tile, " for $", cost, " — ends turn.")
	en_passant_target = Vector2(-1, -1)
	_finish_turn(bot_color)
	show_bot_action_banner("Revived a " + ptype)
	return true

# Last-resort: play the bot's single best raw move with no power-ups, guaranteeing the
# turn advances even if plan_turn somehow produced a non-executable plan.
func _bot_fallback_move():
	for pos in board_state.keys():
		var pc = board_state[pos]
		if pc.get("color", "") != bot_color:
			continue
		if pc.get("modifier", "") == "Ground":
			continue
		var moves = get_safe_moves(pos)
		if moves.size() > 0:
			await execute_move(pos, moves[0])
			return

# Flashes a short banner announcing a bot power-up action, so its buffed/odd-looking
# moves are readable instead of feeling like a glitch. Auto-fades after a couple seconds.
func show_bot_action_banner(text: String):
	var banner = get_node_or_null("BotActionBanner")
	if banner == null:
		banner = Label.new()
		banner.name = "BotActionBanner"
		banner.position = Vector2(550, 75)   # just under the TurnIndicator
		banner.add_theme_font_size_override("font_size", 20)
		add_child(banner)
	banner.text = "🤖 " + text
	banner.modulate = Color(1, 0.7, 0.1, 1)   # orange, fully opaque
	# Fade it out over ~2s using a tween; it'll be refreshed if another action fires.
	var t = create_tween()
	t.tween_interval(1.2)
	t.tween_property(banner, "modulate:a", 0.0, 0.8)

func _ready():
	print("--- Welcome to ÜberChess ---")

	# Match config from the menu (GameConfig autoload); defaults above cover editor-direct launches.
	var cfg = get_node_or_null("/root/GameConfig")
	if cfg != null:
		vs_bot = cfg.is_bot_match()
		bot_color = cfg.bot_color
		is_multiplayer = cfg.is_multiplayer()
		if is_multiplayer:
			vs_bot = false
			print("🌐 Multiplayer match — connecting to the relay server.")
		elif vs_bot:
			# Put the HUMAN on the bottom of the board: flip the view when the human plays
			# Black (i.e. the bot is White). Reuses the same board_flipped path multiplayer
			# uses, so drawing, coordinates, gutters, and click-decoding all stay correct.
			board_flipped = (bot_color == "White")
			print("🤖 Bot match — AI plays ", bot_color, " at ", cfg.difficulty_label(), " difficulty.")
		else:
			print("👥 Local 2-player match.")

	# Left gutter: two vertical bands (bank → slots → captured), Black on top by default.
	black_gold_label.add_theme_font_size_override("font_size", 24)
	add_child(black_gold_label)
	white_gold_label.add_theme_font_size_override("font_size", 24)
	add_child(white_gold_label)
	_layout_gutter_bands()

	var turn_indicator = Label.new()
	turn_indicator.name = "TurnIndicator"
	turn_indicator.position = Vector2(550, 40)
	turn_indicator.add_theme_font_size_override("font_size", 28)
	add_child(turn_indicator)

	# Returns to the main menu; swapping scenes discards the match, so it doubles as a reset.
	var menu_btn = Button.new()
	menu_btn.name = "MainMenuButton"
	menu_btn.text = "≡ Menu"
	menu_btn.position = Vector2(GUTTER_X, 30)
	menu_btn.add_theme_font_size_override("font_size", 18)
	menu_btn.pressed.connect(self._on_main_menu_pressed)
	add_child(menu_btn)

	update_gold_display()
	draw_shop_ui()
	draw_board()
	draw_coordinates()
	initialize_board()
	spawn_visual_pieces()
	update_captured_display()
	update_slot_display()

	# Online: lobby overlay + relay connection. Board input stays locked until MATCH_START.
	if is_multiplayer:
		_build_lobby_ui()
		_net_connect()

	if vs_bot:
		bot = UberBot.new(self)
		_maybe_let_bot_move()

# ==========================================
# 3. BEHAVIOR: CORE SYSTEMS & LOGIC
# ==========================================

func update_gold_display():
	white_gold_label.text = "White Bank: $" + str(player_gold["White"])
	black_gold_label.text = "Black Bank: $" + str(player_gold["Black"])
	# Gold (or the active player) may have changed — repaint shop buyable/blocked colors.
	# Guarded because update_gold_display() runs once before the shop is built in _ready().
	if not shop_buttons.is_empty():
		refresh_shop_affordability()

# Logs a fallen piece into ITS OWNER'S tray for later revival. (The capturer's
# gold reward is handled separately in execute_move.)
func record_capture(victim: Dictionary):
	var owner = victim.get("color", "")
	if owner == "" or not captured_pieces.has(owner):
		return
	# A piece that was itself a revival is used up — it never returns to the tray, so
	# every piece can be revived at most once in the whole game.
	if victim.get("is_revived", false):
		print("⚰️ ", owner, " ", victim.get("type", "?"), " was a revived piece — gone for good.")
		return
	captured_pieces[owner].append({
		"type": victim.get("type", "Pawn"),
		"is_super_pawn": victim.get("is_super_pawn", false)
	})

# Positions the two left-gutter bands; they swap when the local view is flipped so the
# local player's bank/slots/captured sit at the bottom. Each band is drawn relative to
# its bank label's Y — redraw the slot/captured rows after calling this.
func _layout_gutter_bands() -> void:
	var top_y := 100.0
	var bottom_y := 510.0
	if board_flipped:
		black_gold_label.position = Vector2(GUTTER_X, bottom_y)
		white_gold_label.position = Vector2(GUTTER_X, top_y)
	else:
		black_gold_label.position = Vector2(GUTTER_X, top_y)
		white_gold_label.position = Vector2(GUTTER_X, bottom_y)

# Redraws both captured-piece trays. Icons are clickable (click your own fallen piece
# to revive it) and live in the "captured_display" group so board redraws skip them.
func update_captured_display():
	for child in get_children():
		if child.is_in_group("captured_display"):
			child.queue_free()
	_draw_captured_tray("Black", black_gold_label.position.y)
	_draw_captured_tray("White", white_gold_label.position.y)

func _draw_captured_tray(owner: String, label_y: float):
	var pieces: Array = captured_pieces[owner]
	var icon_size := 46.0
	var spacing_x := 50.0
	var row_spacing := 50.0
	var per_row := 4
	var x_start := GUTTER_X
	var tray_top := label_y + CAPTURED_FIRST_DY

	# Section heading (always shown, so the zone is labeled even when empty).
	var head := Label.new()
	head.add_to_group("captured_display")
	head.text = owner + " captured (tap to revive):"
	head.add_theme_font_size_override("font_size", 14)
	head.position = Vector2(x_start, label_y + CAPTURED_HEADING_DY)
	add_child(head)

	if pieces.is_empty():
		var none := Label.new()
		none.add_to_group("captured_display")
		none.text = "—"
		none.add_theme_font_size_override("font_size", 14)
		none.position = Vector2(x_start, tray_top)
		add_child(none)
		return

	var i := 0
	for cap in pieces:
		var col = i % per_row
		var row = i / per_row
		var art = "SuperPawn" if cap.get("is_super_pawn", false) else cap["type"]
		var btn = TextureButton.new()
		btn.add_to_group("captured_display")
		btn.texture_normal = load("res://assets/pieces/" + owner + "_" + art + ".png")
		btn.ignore_texture_size = true
		btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		btn.custom_minimum_size = Vector2(icon_size, icon_size)
		btn.size = Vector2(icon_size, icon_size)
		btn.position = Vector2(x_start + col * spacing_x, tray_top + row * row_spacing)
		btn.pressed.connect(self._on_captured_pressed.bind(owner, i))
		add_child(btn)
		i += 1

# Both players' 3 power-up slots are drawn in the SLOTS section of their band (between the
# bank label above and the captured tray below), in the "slot_display" group so the board
# redraw never clears them. Color: gray = locked (bought this turn), green = ready,
# gold = currently held.
func update_slot_display():
	for child in get_children():
		if child.is_in_group("slot_display"):
			child.queue_free()
	_draw_slot_row("Black", black_gold_label.position.y)
	_draw_slot_row("White", white_gold_label.position.y)

func _draw_slot_row(owner: String, label_y: float):
	var slots: Array = powerup_slots[owner]
	var x_start := GUTTER_X
	var btn_w := 185.0
	var btn_h := 26.0

	# Section heading, clearly below the bank label.
	var head := Label.new()
	head.add_to_group("slot_display")
	head.text = owner + " power-ups:"
	head.add_theme_font_size_override("font_size", 14)
	head.position = Vector2(x_start, label_y + SLOTS_HEADING_DY)
	add_child(head)

	for i in range(MAX_SLOTS):
		var btn := Button.new()
		btn.add_to_group("slot_display")
		btn.position = Vector2(x_start, label_y + SLOTS_FIRST_DY + i * SLOT_STEP_Y)
		btn.custom_minimum_size = Vector2(btn_w, btn_h)
		btn.size = Vector2(btn_w, btn_h)
		btn.add_theme_font_size_override("font_size", 14)
		btn.flat = true

		if i < slots.size():
			var slot = slots[i]
			var is_ready: bool = slot["ready"]
			var tag := " ✓" if is_ready else " (locked)"
			btn.text = slot["name"] + tag

			var col := Color(0.6, 0.6, 0.6)  # locked
			if is_ready:
				col = Color(0.3, 0.9, 0.4)   # ready
			if owner == current_turn and held_slot_index == i and held_powerup != "":
				col = Color(1, 0.8, 0)       # held
			_style_shop_button(btn, col)

			# Only the active player can click their own slots to use them.
			if owner == current_turn:
				btn.pressed.connect(self._on_slot_pressed.bind(owner, i))
			else:
				btn.disabled = true
		else:
			btn.text = "[ empty ]"
			_style_shop_button(btn, Color(0.4, 0.4, 0.4))
			btn.disabled = true

		add_child(btn)


func _on_main_menu_pressed():
	# Close the relay connection cleanly so the server drops our room (which also
	# fires OPPONENT_DISCONNECTED to the other player) before we swap scenes.
	if ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.close()
	get_tree().change_scene_to_file("res://main_menu.tscn")

# Clicking one of your fallen pieces starts a revive. We validate ownership, the Uber
# class limit, gold, and that at least one of its default starting squares is free, then
# enter placement mode (highlight the free starting squares; the player clicks one).
func _on_captured_pressed(owner: String, index: int):
	if game_over:
		return
	# Single-player: the revive tray is the human's — lock it during the bot's turn.
	if vs_bot and current_turn == bot_color:
		return
	# Online: only interact on your OWN turn. (Opponent revives are replayed via
	# _do_revive directly, not through here, so this never blocks a remote action.)
	if is_multiplayer and not net_applying_remote and current_turn != my_side:
		return
	# TOGGLE OFF: clicking the same fallen piece that's already pending cancels the revive,
	# so the tray selects and deselects like the board pieces and power-up slots do.
	# (Clicking a DIFFERENT fallen piece falls through below and re-targets to that one.)
	if not revive_pending.is_empty() \
	and revive_pending["owner"] == owner \
	and revive_pending["index"] == index:
		print("✨ Revive deselected.")
		revive_pending = {}
		update_visuals()
		return
	if owner != current_turn:
		print("⛔ You can only revive your own pieces, on your own turn.")
		return
	if "Uber" in used_classes_this_turn:
		print("⛔ You've already used an Uber power this turn.")
		return
	if index < 0 or index >= captured_pieces[owner].size():
		return
	var cap = captured_pieces[owner][index]
	var ptype = cap["type"]
	var cost = piece_rules[ptype]["revive_cost"]
	if player_gold[owner] < cost:
		print("⛔ Not enough gold to revive a ", ptype, " ($", cost, ").")
		return
	# Which of this piece's default starting squares are currently empty?
	var candidates = []
	for tile in starting_positions[owner][ptype]:
		if not board_state.has(tile):
			candidates.append(tile)
	if candidates.is_empty():
		print("⛔ Cannot revive ", ptype, ": all of its starting squares are occupied.")
		return
	# Enter placement mode — highlight the free starting squares and wait for a click.
	# (Drop any held power-up / board selection so the modes don't collide.)
	held_powerup = ""
	selected_square = Vector2(-1, -1)
	clear_shop_highlights()
	revive_pending = {"owner": owner, "index": index, "type": ptype, "cost": cost, "candidates": candidates}
	print("✨ Reviving a ", ptype, " — click a highlighted square (click the piece again, or right-click, to cancel).")
	update_visuals()

# Spawns the revived piece, deducts the cost, and ENDS the turn (reviving is your move).
# A revived piece is flagged is_revived so it can never be revived a second time. The
# placement is rejected if it would leave your own King in check.
func _do_revive(owner: String, index: int, tile: Vector2):
	if index < 0 or index >= captured_pieces[owner].size():
		revive_pending = {}
		return
	if board_state.has(tile):
		print("⛔ That starting square is no longer free.")
		return
	var cap = captured_pieces[owner][index]
	var ptype = cap["type"]
	var cost = piece_rules[ptype]["revive_cost"]
	if player_gold[owner] < cost:
		revive_pending = {}
		return
	# Tentatively place to verify it doesn't leave our own King in check. A revived piece
	# returns as a plain piece (no buffs / Super Pawn) with has_moved=false, flagged
	# is_revived so a later capture removes it for good.
	board_state[tile] = {"type": ptype, "color": owner, "modifier": "", "modifier_duration": 0, "is_super_pawn": false, "has_moved": false, "is_revived": true}
	if is_in_check(owner):
		board_state.erase(tile)
		print("⛔ Reviving there would leave your King in check — pick another square.")
		return  # keep revive_pending so the player can choose a different square
	# --- NETWORK: broadcast the revive (tray index + target square) before it commits.
	# We only reach here once the placement is validated, so it never desyncs.
	send_to_server({"type": "REVIVE", "index": index, "tile": _v2arr(tile)})
	# Commit: charge gold, remove from the tray, and spend the turn.
	player_gold[owner] -= cost
	captured_pieces[owner].remove_at(index)
	print("✨ REVIVED: ", owner, " ", ptype, " at ", tile, " for $", cost, " — this uses your turn.")
	en_passant_target = Vector2(-1, -1)  # reviving leaves no en passant trail
	_finish_turn(owner)

# --- SYSTEM: BOARD INITIALIZATION ---
func initialize_board():
	board_state.clear()
	for color in starting_positions.keys():
		for piece_type in starting_positions[color].keys():
			for pos in starting_positions[color][piece_type]:
				# Add "has_moved" to the DNA of every piece
				board_state[pos] = {"type": piece_type, "color": color, "modifier": "", "modifier_duration": 0, "is_super_pawn": false, "has_moved": false, "is_revived": false}
	print("Board initialized. Tracking ", board_state.size(), " pieces.")

# --- SYSTEM: RULE ENFORCEMENT & TURN LOGIC ---
# Colors EVERY interactive state of a shop button at once. A Godot Button shows its
# hover / pressed / focus color while the cursor is on it, so overriding only
# "font_color" leaves the highlight invisible until the mouse moves away. Setting all
# states makes the selection highlight appear instantly on click.
func _style_shop_button(btn: Button, color: Color) -> void:
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		btn.add_theme_color_override(state, color)

# "Clearing" the shop selection means dropping the gold held-item highlight and
# repainting every button by its true affordability state (not flat white).
func clear_shop_highlights() -> void:
	refresh_shop_affordability()

# Lights one shop button up in the selection gold (the item currently in hand).
func highlight_shop_button(item_name: String) -> void:
	_style_shop_button(shop_buttons[item_name], Color(1, 0.8, 0))

# Repaints shop FONT colors for the active player: green = buyable, dim red = not,
# gold = held selection, cyan = Revive (dynamic cost). Called on every gold/slot
# change. Hover background is a separate system and is not disturbed here.
func refresh_shop_affordability() -> void:
	var gold: int = player_gold[current_turn]
	var slots_full: bool = powerup_slots[current_turn].size() >= MAX_SLOTS
	# Online: the shop belongs to whoever's turn it is, so on the opponent's turn the
	# local player's shop is locked (greyed out and unclickable). Always open otherwise.
	var shop_open: bool = (not is_multiplayer) or (current_turn == my_side)

	var buyable_col   := Color(0.45, 0.95, 0.5)   # green
	var blocked_col   := Color(0.55, 0.4, 0.4)    # dim red-gray
	var revive_col    := Color(0.55, 0.85, 1.0)   # cyan (special: tray-driven)
	var held_col      := Color(1, 0.8, 0)         # selection gold
	var locked_col    := Color(0.4, 0.4, 0.45)    # opponent's turn — shop unavailable

	for item_name in shop_buttons.keys():
		var btn: Button = shop_buttons[item_name]
		btn.disabled = not shop_open
		if not shop_open:
			_style_shop_button(btn, locked_col)
			continue

		# The held item always shows gold, regardless of affordability.
		if held_powerup == item_name and held_powerup != "":
			_style_shop_button(btn, held_col)
			continue

		# Revive is bought by clicking a fallen piece in the tray, not from a slot,
		# and its cost varies by piece — show it in its own informative color.
		if item_name == "Revive":
			_style_shop_button(btn, revive_col)
			continue

		var cost: int = btn.get_meta("cost", 0)
		if slots_full or gold < cost:
			_style_shop_button(btn, blocked_col)
		else:
			_style_shop_button(btn, buyable_col)

func _on_shop_item_pressed(item_name, cost):
	if game_over:
		return
	# Single-player: the shop is the human's — lock it while the bot is on move. The bot's
	# OWN purchases come through _bot_buy (which sets bot_buying), so they're exempt.
	if vs_bot and current_turn == bot_color and not bot_buying:
		print("⛔ It's the bot's turn — the shop is locked.")
		return
	# Online: only your own turn buys here; remote replays pass via net_applying_remote.
	if is_multiplayer and not net_applying_remote and current_turn != my_side:
		print("⛔ Not your turn — the shop is locked.")
		return

	# Revive isn't slotted — it's triggered live by clicking a fallen piece in your tray.
	if item_name == "Revive":
		print("✨ To revive, click one of your fallen pieces shown above your bank.")
		return

	# Buying pays gold NOW and drops the power-up into a slot as not-yet-usable. The
	# opponent can see it sitting there and play around it. No class limit on buying —
	# the slot cap and gold are the only constraints. Buying does not end your turn.
	if powerup_slots[current_turn].size() >= MAX_SLOTS:
		print("❌ Rejected: all ", MAX_SLOTS, " power-up slots are full.")
		return
	if player_gold[current_turn] < cost:
		print("❌ Rejected: Not enough gold for ", item_name, " ($", cost, ").")
		return

	# --- NETWORK: broadcast the purchase so the opponent's slot row stays in sync ---
	send_to_server({"type": "BUY_ITEM", "item": item_name})

	player_gold[current_turn] -= cost
	powerup_slots[current_turn].append({"name": item_name, "ready": false})
	print("🛒 ", current_turn, " bought ", item_name, " for $", cost, " — locked until next turn.")
	update_gold_display()
	update_slot_display()


# Clicking one of YOUR ready slots picks the power-up up for targeting. Clicking the slot
# you're already holding puts it back. Opponent / locked slots are display-only.
func _on_slot_pressed(owner: String, slot_index: int):
	if game_over:
		return
	# Single-player: don't let the human pick up the bot's slots during the bot's turn.
	if vs_bot and current_turn == bot_color:
		return
	# Online: only pick up your own slots, on your own turn.
	if is_multiplayer and not net_applying_remote and current_turn != my_side:
		return
	if owner != current_turn:
		print("⛔ That's the opponent's power-up slot.")
		return
	if slot_index < 0 or slot_index >= powerup_slots[owner].size():
		return

	# Toggle off if this slot is already the one in hand.
	if held_slot_index == slot_index and held_powerup != "":
		cancel_powerup()
		return

	var slot = powerup_slots[owner][slot_index]
	if not slot["ready"]:
		print("⏳ ", slot["name"], " was bought this turn — usable from your next turn.")
		return

	# One ability per CLASS per turn still gates USING a power-up.
	var item_class = powerup_classes[slot["name"]]
	if item_class in used_classes_this_turn:
		print("❌ Rejected: already used a [", item_class, "] power-up this turn.")
		return

	# Pick it up. The slot is consumed only on a successful apply (see _consume_held_slot).
	held_powerup = slot["name"]
	held_slot_index = slot_index
	selected_square = Vector2(-1, -1)
	clear_shop_highlights()
	update_slot_display()  # re-color so the held slot reads as active
	update_visuals()
	print("✋ Holding ", held_powerup, " — click a target piece (or the slot again to cancel).")


# Removes the picked-up slot from the active player's inventory. Called by apply_powerup
# and execute_cheat_move on a SUCCESSFUL use only.
func _consume_held_slot():
	if held_slot_index >= 0 and held_slot_index < powerup_slots[current_turn].size():
		var spent = powerup_slots[current_turn][held_slot_index]
		powerup_slots[current_turn].remove_at(held_slot_index)
		print("✅ Used ", spent.get("name", "?"), " from slot — slot freed.")
	held_slot_index = -1


func apply_powerup(pos: Vector2) -> bool:
	if not board_state.has(pos):
		print("❌ Invalid: You must target a piece.")
		return false
	var piece = board_state[pos]
	if piece["type"] == "King":
		print("❌ Invalid: Power-ups cannot target Kings.")
		return false
	if piece["color"] != current_turn:
		print("❌ Invalid: You can only buff your own pieces.")
		return false
	if piece.get("is_super_pawn", false):
		print("❌ Invalid: Super Pawns cannot use power-ups.")
		return false
	# One power-up per piece per turn — no stacking, even across classes.
	if held_powerup != "Super Pawn" and piece.get("modifier", "") != "":
		print("❌ Invalid: that piece already has a power-up this turn.")
		return false
	if held_powerup == "Super Pawn" and piece["type"] != "Pawn":
		print("❌ Invalid: Super Pawn can only be applied to a Pawn.")
		return false

	# Tell the opponent before it lands locally (no-ops offline / during remote replays).
	send_to_server({"type": "USE_POWERUP", "item": held_powerup, "target": _v2arr(pos)})

	# Gold was paid at purchase; applying books the class use and consumes the slot.
	used_classes_this_turn.append(powerup_classes[held_powerup])
	_consume_held_slot()

	# Super Pawn is a permanent intrinsic flag; everything else is a timed modifier.
	if held_powerup == "Super Pawn":
		piece["is_super_pawn"] = true
		piece["modifier"] = ""
		piece["modifier_duration"] = 0
		print("⚡ Super Pawn upgrade applied to ", current_turn, " Pawn at ", pos)
	else:
		piece["modifier"] = held_powerup
		piece["modifier_duration"] = powerup_durations.get(held_powerup, 1)
		print("⚡ ", held_powerup, " applied to ", current_turn, " ", piece["type"], " at ", pos)

	held_powerup = ""
	clear_shop_highlights()
	update_gold_display()
	update_slot_display()
	update_visuals()
	return true

func is_invulnerable(target_pos: Vector2) -> bool:
	# A piece just relocated by Cheat can't be captured by the cheater this turn.
	if target_pos == cheat_protected_square:
		return true
	if board_state.has(target_pos):
		# We safely check for the modifier. If it doesn't exist, it defaults to ""
		var mod = board_state[target_pos].get("modifier", "")
		if mod == "Ground" or mod == "Shield":
			return true
	return false

# What the capturer collects for taking `piece`. A Super Pawn is worth $8 flat
# (its type is still "Pawn", so we special-case the flag).
func base_capture_value(piece: Dictionary) -> int:
	if piece.get("is_super_pawn", false):
		return 8
	return piece_rules[piece["type"]]["value"]

# The boosted value a "Multiply" confers: everything doubled, except normal pawns
# which are quadrupled ($4). A multiplied Super Pawn is $16 ($8 base, doubled).
func multiplied_capture_value(piece: Dictionary) -> int:
	if piece.get("is_super_pawn", false):
		return 16
	if piece["type"] == "Pawn":
		return piece_rules["Pawn"]["value"] * 4
	return piece_rules[piece["type"]]["value"] * 2

# What the capturer is paid for taking `victim`, after economy modifiers.
# Priority: victim Negate ($0) beats victim Multiply beats capturer Multiply.
func _capture_payout(capturer: Dictionary, victim: Dictionary) -> int:
	var value = base_capture_value(victim)
	var vmod = victim.get("modifier", "")
	if vmod == "Negate":
		value = 0
		print("🚫 NEGATE: ", victim["type"], " was worth nothing to capture.")
	elif vmod == "Multiply":
		value = multiplied_capture_value(victim)
		print("💰 MULTIPLY (liability): captured a boosted ", victim["type"], " for $", value)
	elif capturer.get("modifier", "") == "Multiply":
		value = multiplied_capture_value(victim)
		print("💰 MULTIPLY (offense): boosted capture of ", victim["type"], " for $", value)
	return value

# Ticks down every timed buff belonging to `color`; at zero the modifier clears (the
# tint resets on the next redraw). Call for the player ABOUT TO MOVE, so a buff from
# turn N survives the opponent's reply and expires as control returns on turn N+1.
func expire_modifiers(color: String):
	for pos in board_state.keys():
		var piece = board_state[pos]
		if not piece.has("color") or piece["color"] != color:
			continue
		if piece.get("modifier", "") == "":
			continue
		if piece.get("modifier_duration", 0) < 0:
			continue  # permanent buff (duration -1) — never expires
		var remaining = piece.get("modifier_duration", 0) - 1
		if remaining <= 0:
			print("⌛ ", piece.get("modifier", ""), " expired on ", color, " ", piece.get("type", "?"), " at ", pos)
			piece["modifier"] = ""
			piece["modifier_duration"] = 0
		else:
			piece["modifier_duration"] = remaining


# ==========================================
# 4. MATHEMATICS: MOVEMENT & GRID RULES
# ==========================================

func is_within_bounds(pos: Vector2) -> bool:
	return pos.x >= 0 and pos.x < 8 and pos.y >= 0 and pos.y < 8

func is_valid_destination(pos: Vector2, my_color: String) -> bool:
	if not is_within_bounds(pos):
		return false
		
	if board_state.has(pos):
		# We cannot step on our own pieces
		if board_state[pos]["color"] == my_color:
			return false
		# --- NEW RULE: We cannot step on an invulnerable enemy ---
		if is_invulnerable(pos):
			return false
			
	return true

func is_in_check(color: String) -> bool:
	var king_pos = Vector2(-1, -1)
	
	# 1. Find the King
	for pos in board_state:
		# --- DETECTIVE CHECK ---
		if not board_state[pos].has("type"):
			print("🚨 CORRUPTED DATA AT ", pos, ": ", board_state[pos])
			continue # This safely skips the broken piece and keeps searching
			
		if board_state[pos]["type"] == "King" and board_state[pos]["color"] == color:
			king_pos = pos
			break
			
	if king_pos == Vector2(-1, -1):
		return false
		
	# 2. Check if any enemy piece can attack the King
	for pos in board_state:
		# --- DETECTIVE CHECK ---
		if not board_state[pos].has("type"):
			continue # Silently skip corrupted data here as well
			
		if board_state[pos]["color"] != color:
			# Pass 'true' so the engine knows it's only looking for threats
			var enemy_moves = get_legal_moves(pos, true) 
			if king_pos in enemy_moves:
				return true
				
	return false

# Walks continuously in given directions until it hits an edge, a friend, or an enemy.
# When phase=true (the Phase power-up), the slide may tunnel through ONE piece (friend
# or foe) and keep going; the very next piece is a hard wall. It still can't land on a
# friendly and can't capture an invulnerable.
func get_sliding_moves(start_pos: Vector2, my_color: String, directions: Array, phase: bool = false) -> Array:
	var valid_moves = []
	
	for dir in directions:
		var current_pos = start_pos + dir
		var pieces_phased = 0  # Phase may tunnel through at most ONE piece per direction.
		
		while is_within_bounds(current_pos):
			# If the square is empty, we can move there and keep sliding.
			if not board_state.has(current_pos):
				valid_moves.append(current_pos)
			else:
				# We hit a piece. If it's a vulnerable enemy, we can capture it.
				if board_state[current_pos]["color"] != my_color and not is_invulnerable(current_pos):
					valid_moves.append(current_pos)
				
				# A piece blocks any further sliding — UNLESS Phase still has its single
				# pass-through left, in which case we tunnel through this one piece and
				# continue. Once that pass-through is spent, the next piece is a hard wall.
				if phase and pieces_phased < 1:
					pieces_phased += 1
				else:
					break
				
			current_pos += dir
			
	return valid_moves
	
func get_legal_moves(pos: Vector2, checking_threats: bool = false) -> Array:
	var moves = []
	
	if not board_state.has(pos):
		return []
		
	var piece = board_state[pos]
	
	# Corrupted piece data — eject safely.
	if not piece.has("color") or not piece.has("type"):
		print("🚨 GHOST PIECE DETECTED at ", pos, "! Data is corrupted: ", piece)
		return [] 
		
	var color = piece["color"]
	
	# --- MOVEMENT POWER-UPS ---
	# These only reshape moves for the piece's own real move, never for threat scans
	# (checking_threats), so check/checkmate detection always uses normal geometry.
	var modifier = piece.get("modifier", "")
	
	# TELEPORT: relocate to ANY empty square on the board, ignoring geometry.
	if modifier == "Teleport" and not checking_threats:
		for x in range(8):
			for y in range(8):
				var sq = Vector2(x, y)
				if not board_state.has(sq):
					moves.append(sq)
		return moves
	
	# PHASE: sliding pieces pass through blockers for this one move.
	var phasing = modifier == "Phase" and not checking_threats
	
	match piece["type"]:
		"Knight":
			var knight_jumps = [
				Vector2(1, -2), Vector2(2, -1), Vector2(2, 1), Vector2(1, 2),
				Vector2(-1, 2), Vector2(-2, 1), Vector2(-2, -1), Vector2(-1, -2)
			]
			for jump in knight_jumps:
				var target = pos + jump
				if is_valid_destination(target, color):
					moves.append(target)
					
		"Pawn":
			# SUPER PAWN: moves/captures one square straight forward OR backward; captures
			# (and en passant) on the FORWARD diagonals only. Permanent, so this geometry
			# also defines its threats in check scans. Early-returns past normal pawn logic.
			if piece.get("is_super_pawn", false):
				var dir = -1 if color == "White" else 1  # forward direction for this color

				# Straight forward and straight backward — move or capture.
				for d in [Vector2(0, dir), Vector2(0, -dir)]:
					var sq = pos + d
					if not is_within_bounds(sq):
						continue
					if not board_state.has(sq):
						moves.append(sq)  # push onto an empty square
					elif board_state[sq]["color"] != color and not is_invulnerable(sq):
						moves.append(sq)  # capture a vulnerable enemy

				# Forward diagonals — capture only (no free move onto empty squares).
				for d in [Vector2(-1, dir), Vector2(1, dir)]:
					var sq = pos + d
					if not is_within_bounds(sq):
						continue
					if board_state.has(sq) and board_state[sq]["color"] != color and not is_invulnerable(sq):
						moves.append(sq)  # standard diagonal capture

				# En passant: forward diagonals only, matching the capture geometry above.
				if en_passant_target != Vector2(-1, -1):
					for d in [Vector2(-1, dir), Vector2(1, dir)]:
						if pos + d == en_passant_target:
							moves.append(en_passant_target)

				return moves
			
			var direction = -1 if color == "White" else 1
			var start_row = 6 if color == "White" else 1
			
			var forward = pos + Vector2(0, direction)
			
			# Standard forward move
			if is_valid_destination(forward, color) and not board_state.has(forward):
				moves.append(forward)
				
				# Double move from start
				if pos.y == start_row:
					var double_forward = pos + Vector2(0, direction * 2)
					if is_valid_destination(double_forward, color) and not board_state.has(double_forward) and not board_state.has(forward):
						moves.append(double_forward)
			
			# --- DIAGONAL CAPTURES & EN PASSANT ---
			var capture_directions = [Vector2(-1, direction), Vector2(1, direction)]
			for cap_dir in capture_directions:
				var target = pos + cap_dir
				if is_valid_destination(target, color):
					# Standard capture
					if board_state.has(target) and board_state[target]["color"] != color:
						moves.append(target)
					# En Passant capture (The Ghost Target)
					elif target == en_passant_target: 
						moves.append(target)
		"Rook":
			var dirs = [Vector2(0, 1), Vector2(0, -1), Vector2(1, 0), Vector2(-1, 0)]
			moves.append_array(get_sliding_moves(pos, color, dirs, phasing))
			
		"Bishop":
			var dirs = [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]
			moves.append_array(get_sliding_moves(pos, color, dirs, phasing))
			
		"Queen":
			var dirs = [
				Vector2(0, 1), Vector2(0, -1), Vector2(1, 0), Vector2(-1, 0),
				Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)
			]
			moves.append_array(get_sliding_moves(pos, color, dirs, phasing))
			
		"King":
			var king_moves = [
				Vector2(0, 1), Vector2(0, -1), Vector2(1, 0), Vector2(-1, 0),
				Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)
			]
			for km in king_moves:
				var target = pos + km
				if is_valid_destination(target, color):
					moves.append(target)
			
			# --- CASTLING POTENTIAL (Bulletproof Version) ---
			if not checking_threats:
				# Safely read memory: If the key is missing entirely, it defaults to 'false'
				if piece.get("has_moved", false) == false and not is_in_check(color):
					var y_row = pos.y
					
					# Kingside (Right)
					var right_rook_pos = Vector2(7, y_row)
					if board_state.has(right_rook_pos) and board_state[right_rook_pos].get("type") == "Rook":
						if board_state[right_rook_pos].get("has_moved", false) == false:
							if not board_state.has(Vector2(5, y_row)) and not board_state.has(Vector2(6, y_row)):
								moves.append(Vector2(6, y_row))
								
					# Queenside (Left)
					var left_rook_pos = Vector2(0, y_row)
					if board_state.has(left_rook_pos) and board_state[left_rook_pos].get("type") == "Rook":
						if board_state[left_rook_pos].get("has_moved", false) == false:
							if not board_state.has(Vector2(1, y_row)) and not board_state.has(Vector2(2, y_row)) and not board_state.has(Vector2(3, y_row)):
								moves.append(Vector2(2, y_row))
	# CAPTURE buff: any buffed piece may also step/capture one square in any
	# direction (king-style), added on top of its normal geometry.
	if modifier == "Capture":
		add_capture_king_moves(moves, pos, color)

	# SHIELD: a shielded piece may move freely but may NOT capture. We strip every
	# capturing move here — but ONLY for the piece's real move (checking_threats ==
	# false). Threat scans keep the captures intact, so a shielded piece still guards
	# squares and can still threaten, check, and checkmate the enemy King.
	if modifier == "Shield" and not checking_threats:
		var non_captures = []
		for m in moves:
			# A normal capture lands on an occupied enemy square.
			if board_state.has(m) and board_state[m]["color"] != color:
				continue
			# En passant captures onto an empty square — forbid that too.
			if piece["type"] == "Pawn" and m == en_passant_target:
				continue
			non_captures.append(m)
		moves = non_captures

	return moves

# Adds king-style one-square moves/captures (8 directions) to `moves`, skipping
# duplicates and respecting invulnerability via is_valid_destination.
func add_capture_king_moves(moves: Array, pos: Vector2, color: String) -> void:
	var around = [
		Vector2(0, 1), Vector2(0, -1), Vector2(1, 0), Vector2(-1, 0),
		Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)
	]
	for d in around:
		var t = pos + d
		if is_valid_destination(t, color) and not moves.has(t):
			moves.append(t)

# Filters a piece's raw geometric moves, discarding any that put or leave its own King in check.
func get_safe_moves(pos: Vector2) -> Array:
	var safe_moves = []
	
	if not board_state.has(pos):
		return safe_moves
		
	var raw_moves = get_legal_moves(pos)
	var moving_piece = board_state[pos]
	var my_color = moving_piece["color"]
	
	for target_pos in raw_moves:
		
		# 0. KINGS ARE NEVER CAPTURABLE. A real move may never land on an enemy King —
		# the game ends at checkmate first. (Threat scans run through get_legal_moves
		# directly, NOT here, so enemy King squares still register for check detection.)
		if board_state.has(target_pos) and board_state[target_pos]["type"] == "King":
			continue
		
		# 1. REMEMBER THE PRESENT
		var captured_piece = null
		if board_state.has(target_pos):
			captured_piece = board_state[target_pos]
			
		# --- VERIFY SAFE PASSAGE FOR CASTLING ---
		var transit_safe = true
		if moving_piece["type"] == "King" and abs(target_pos.x - pos.x) == 2:
			var direction = sign(target_pos.x - pos.x)
			var transit_square = pos + Vector2(direction, 0)
			
			# Simulate stepping onto the middle square
			board_state.erase(pos)
			board_state[transit_square] = moving_piece
			if is_in_check(my_color):
				transit_safe = false
				
			# Rewind so the main simulation can run cleanly
			board_state.erase(transit_square)
			board_state[pos] = moving_piece
			
			if not transit_safe:
				continue # Abandon this timeline; the transit square is attacked
		
		# 2. SIMULATE THE FUTURE
		board_state.erase(pos)
		board_state[target_pos] = moving_piece
		
		# 3. EVALUATE — the move is safe if our King is not in check in this future
		var king_is_safe = not is_in_check(my_color)
		
		# 4. REWIND TIME (Restore the board strictly to how it was)
		board_state.erase(target_pos)
		board_state[pos] = moving_piece
		if captured_piece != null:
			board_state[target_pos] = captured_piece
			
		# 5. KEEP THE SAFE MOVES
		if king_is_safe:
			safe_moves.append(target_pos)
			
	return safe_moves

func has_legal_moves(color: String) -> bool:
	for pos in board_state.keys():
		var piece = board_state[pos]
		if piece.has("color") and piece["color"] == color:
			if get_safe_moves(pos).size() > 0:
				return true
	return false

# Hides the static piece sprite sitting on a given BOARD COORDINATE (exact match via the
# node's "board_pos" meta, set in spawn_visual_pieces). Robust replacement for the old
# float-pixel matching, which could silently miss and leave a doubled/snapping piece.
func _hide_piece_at(board_pos: Vector2) -> void:
	for node in get_tree().get_nodes_in_group("board_piece"):
		if is_instance_valid(node) and node.get_meta("board_pos", Vector2(-99, -99)) == board_pos:
			node.visible = false

# Pixel center of a board square in the CURRENT view (respects board_flipped via _disp).
func _square_center(pos: Vector2) -> Vector2:
	return BOARD_OFFSET + _disp(pos) * TILE_SIZE + Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)

# Spawn a temporary visual-only piece sprite for animations. Ghosts are named so the
# update_visuals() sweep ignores them; the caller owns freeing them.
func _make_ghost(image_path: String, pixel: Vector2, ghost_name: String = "AnimGhost", z: int = 20) -> Node:
	var ghost = PIECE_SCENE.instantiate()
	ghost.name = ghost_name
	var gs = ghost.get_node("Sprite2D")
	gs.texture = load(image_path)
	gs.scale = Vector2.ONE * (TILE_SIZE / gs.texture.get_size().x)
	ghost.position = pixel
	ghost.z_index = z
	add_child(ghost)
	return ghost

# Reusable slide: tweens a ghost of `image_path` between squares and awaits it. The
# CALLER owns the board_state mutation and the final update_visuals(). Used by
# execute_move, the castling rook, and Cheat puppeting, so every piece on the board
# moves the SAME smooth way.
func _slide_piece(image_path: String, from_pos: Vector2, to_pos: Vector2, duration: float = 0.22) -> void:
	var ghost = _make_ghost(image_path, _square_center(from_pos), "AnimGhostSlide")
	var tw = create_tween()
	tw.tween_property(ghost, "position", _square_center(to_pos), duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	if is_instance_valid(ghost):
		ghost.queue_free()

# Physically shifts a piece in the board's memory and handles captures and check rewards.
func execute_move(from_pos: Vector2, to_pos: Vector2):
	if not board_state.has(from_pos):
		return
	# --- NETWORK: broadcast this move to the opponent BEFORE it animates/commits locally.
	# send_to_server() no-ops while replaying a remote action, so this never echoes back.
	send_to_server({"type": "MAKE_MOVE", "from": _v2arr(from_pos), "to": _v2arr(to_pos)})
		
	var piece = board_state[from_pos]
	var moving_color = piece["color"]
	var enemy_color = "Black" if moving_color == "White" else "White"
	
	# --- 0. ANIMATE THE SLIDE ---
	# Ghost sprites tween while the real nodes hide; update_visuals() rebuilds after.
	is_animating = true
	# One-frame breather so a bot move arriving after a heavy (thread-blocking) search
	# is not created and "finished" inside the same stutter, which would look like a
	# teleport instead of a slide.
	await get_tree().process_frame

	var image_name = "SuperPawn" if piece.get("is_super_pawn", false) else piece["type"]
	var image_path = "res://assets/pieces/" + piece["color"] + "_" + image_name + ".png"
	_hide_piece_at(from_pos)
	_hide_piece_at(to_pos)

	# Captured piece: its own self-freeing fade-out, independent of the slide.
	if board_state.has(to_pos):
		var victim_data = board_state[to_pos]
		var v_name = "SuperPawn" if victim_data.get("is_super_pawn", false) else victim_data["type"]
		var victim_ghost = _make_ghost("res://assets/pieces/" + victim_data["color"] + "_" + v_name + ".png", _square_center(to_pos), "AnimGhostVictim", 19)
		var vt = create_tween()
		vt.tween_property(victim_ghost, "modulate:a", 0.0, 0.15)
		vt.tween_callback(func():
			if is_instance_valid(victim_ghost):
				victim_ghost.queue_free())

	# Castling: slide the rook in parallel with the king (fire-and-forget tween; the
	# king slide below is what we await).
	var rook_ghost: Node = null
	if piece["type"] == "King" and abs(to_pos.x - from_pos.x) == 2:
		var castle_dir = sign(to_pos.x - from_pos.x)
		var rook_from_pre = Vector2(7 if castle_dir == 1 else 0, from_pos.y)
		var rook_to_pre = Vector2(to_pos.x - castle_dir, from_pos.y)
		if board_state.has(rook_from_pre):
			_hide_piece_at(rook_from_pre)
			rook_ghost = _make_ghost("res://assets/pieces/" + piece["color"] + "_Rook.png", _square_center(rook_from_pre), "AnimGhostRook")
			var rook_tween = create_tween()
			rook_tween.tween_property(rook_ghost, "position", _square_center(rook_to_pre), 0.22).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	await _slide_piece(image_path, from_pos, to_pos)
	if is_instance_valid(rook_ghost):
		rook_ghost.queue_free()
	is_animating = false

	# --- 1. SPECIAL MOVEMENT: CASTLING ---
	if piece["type"] == "King" and abs(to_pos.x - from_pos.x) == 2:
		var direction = sign(to_pos.x - from_pos.x)
		var rook_from_x = 7 if direction == 1 else 0 
		var rook_to_x = to_pos.x - direction
		
		var rook_pos = Vector2(rook_from_x, from_pos.y)
		var rook_target = Vector2(rook_to_x, from_pos.y)
		
		if board_state.has(rook_pos):
			var rook = board_state[rook_pos]
			board_state.erase(rook_pos)
			rook["has_moved"] = true
			board_state[rook_target] = rook
			print("🏰 Castling executed for ", moving_color)

	# --- 2. SPECIAL CAPTURE: EN PASSANT (pays out like any other capture) ---
	if piece["type"] == "Pawn" and to_pos == en_passant_target:
		var captured_pawn_pos = Vector2(to_pos.x, from_pos.y)
		if board_state.has(captured_pawn_pos):
			var ep_victim = board_state[captured_pawn_pos]
			player_gold[moving_color] += _capture_payout(piece, ep_victim)
			record_capture(ep_victim)
			board_state.erase(captured_pawn_pos)
			print("👻 En Passant capture executed!")

	# --- 3. PERMANENT MEMORY ---
	piece["has_moved"] = true
	
	# --- 4. STANDARD CAPTURE & ECONOMY ---
	if board_state.has(to_pos):
		var captured_piece = board_state[to_pos]
		var capture_value = _capture_payout(piece, captured_piece)
		player_gold[moving_color] += capture_value
		record_capture(captured_piece)
		print("⚔️ CAPTURE: ", moving_color, " ", piece["type"], " captured ", enemy_color, " ", captured_piece["type"], "! +$", capture_value)
		
	# --- 5. SHIFT REALITY ---
	board_state.erase(from_pos)
	board_state[to_pos] = piece
	
	# --- 6. PAWN PROMOTION INTERCEPT ---
	if piece["type"] == "Pawn":
		if (moving_color == "White" and to_pos.y == 0) or (moving_color == "Black" and to_pos.y == 7):
			# A promoted Super Pawn auto-promotes to Queen — shed the permanent upgrade,
			# no picker needed. Bot moves also skip the UI (handled in UberBot._make()).
			if piece.get("is_super_pawn", false):
				piece["type"] = "Queen"
				piece["is_super_pawn"] = false
				print("👑 Super Pawn auto-promoted to Queen at ", to_pos)
			elif vs_bot and moving_color == bot_color:
				# Bot always promotes to Queen — keep it snappy.
				piece["type"] = "Queen"
				print("👑 Bot Pawn promoted to Queen at ", to_pos)
			else:
				# Human promotion. Online: the opponent's choice arrives as a separate
				# PROMOTION_CHOSEN message (emitted onto promotion_chosen by _net_route),
				# so a remote replay just waits for it instead of showing the picker.
				# Redraw first so the un-promoted pawn sits on its square (and the captured
				# piece reads as gone) during the wait — otherwise the destination square
				# looks empty until the choice lands, most visibly on the remote client.
				update_visuals()
				if is_multiplayer and net_applying_remote:
					var chosen_remote := _net_promo_choice
					if chosen_remote == "":
						chosen_remote = await promotion_chosen
					_net_promo_choice = ""
					piece["type"] = chosen_remote
					print("👑 Opponent's Pawn promoted to ", chosen_remote, " at ", to_pos)
				else:
					# Local human promotion: show the picker and wait for a tap.
					_show_promotion_menu(moving_color)
					var chosen = await promotion_chosen
					piece["type"] = chosen
					send_to_server({"type": "PROMOTION_CHOSEN", "piece_type": chosen})
					print("👑 Pawn promoted to ", chosen, " at ", to_pos)

	# --- 7. EN PASSANT TRAIL MANAGEMENT ---
	en_passant_target = Vector2(-1, -1)
	if piece["type"] == "Pawn" and abs(to_pos.y - from_pos.y) == 2:
		var move_direction = sign(to_pos.y - from_pos.y)
		en_passant_target = from_pos + Vector2(0, move_direction)
		print("👻 En Passant trail left at: ", en_passant_target)

	# --- 8. END THE TURN: evaluate end-of-game, swap sides, refresh UI ---
	_finish_turn(moving_color)


# Builds and shows a centered modal promotion picker. The four choices (Queen, Rook,
# Bishop, Knight) are shown as TextureButtons with the promoting player's art so the
# choice is visual, not just a label. Tapping any button fires promotion_chosen and
# removes the overlay — execute_move() is awaiting that signal before it continues.
func _show_promotion_menu(color: String):
	var overlay = CanvasLayer.new()
	overlay.name = "PromotionOverlay"
	overlay.layer = 100   # on top of everything
	add_child(overlay)

	# Semi-transparent dark backdrop — dims the board so the picker pops.
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.65)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(bg)

	# Centered panel.
	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	# Offset to visually center the panel (PanelContainer anchor is top-left of the node).
	panel.position = Vector2(-220, -130)
	overlay.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var title = Label.new()
	title.text = "Promote your Pawn"
	title.add_theme_font_size_override("font_size", 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var hbox = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 16)
	vbox.add_child(hbox)

	var choices = ["Queen", "Rook", "Bishop", "Knight"]
	for piece_type in choices:
		var col = VBoxContainer.new()
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		col.add_theme_constant_override("separation", 4)
		hbox.add_child(col)

		var btn = TextureButton.new()
		btn.texture_normal = load("res://assets/pieces/" + color + "_" + piece_type + ".png")
		btn.ignore_texture_size = true
		btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		btn.custom_minimum_size = Vector2(80, 80)
		btn.size = Vector2(80, 80)
		# Capture piece_type in the closure by value via a local variable.
		var chosen_type = piece_type
		btn.pressed.connect(func():
			overlay.queue_free()
			promotion_chosen.emit(chosen_type))
		col.add_child(btn)

		var lbl = Label.new()
		lbl.text = piece_type
		lbl.add_theme_font_size_override("font_size", 16)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(lbl)

# Shared end-of-turn routine for BOTH a normal move and a revive. Evaluates whether the
# opponent is now checkmated / stalemated / in check (awarding the $2 check bonus),
# consumes the acting side's one-shot buffs, swaps the turn, and refreshes the UI.
func _finish_turn(acting_color: String):
	var enemy_color = "Black" if acting_color == "White" else "White"

	# Checkmate / stalemate / check for the side about to move.
	var enemy_in_check = is_in_check(enemy_color)
	var enemy_can_move = has_legal_moves(enemy_color)
	in_check = false
	if not enemy_can_move:
		game_over = true
		if enemy_in_check:
			winner = acting_color
			print("\n👑 MATCH OVER: CHECKMATE! ", winner, " wins.")
		else:
			is_draw = true
			print("\n🤝 MATCH OVER: STALEMATE — it's a draw.")
	elif enemy_in_check:
		in_check = true
		player_gold[acting_color] += 2
		print("⚠️ CHECK: The ", enemy_color, " King is threatened! +$2 awarded to ", acting_color, ".")

	# Consume one-shot buffs (Phase / Teleport / Capture) belonging to the acting side —
	# spent the moment their turn ends, used or wasted, so they never bleed into the reply.
	for p in board_state.keys():
		var pc = board_state[p]
		var m = pc.get("modifier", "")
		if pc.get("color", "") == acting_color and (powerup_classes.get(m, "") == "Movement" or m == "Capture"):
			print("✨ ", m, " spent by ", acting_color, " ", pc.get("type", "?"))
			pc["modifier"] = ""
			pc["modifier_duration"] = 0

	# Swap sides and reset per-turn state.
	current_turn = enemy_color
	print("⏳ Turn passed to: ", current_turn)
	used_classes_this_turn.clear()
	cheat_protected_square = Vector2(-1, -1)
	revive_pending = {}
	held_powerup = ""          # drop anything in hand across the swap
	held_slot_index = -1
	expire_modifiers(current_turn)
	ready_slots(current_turn)  # power-ups bought last turn unlock now
	selected_square = Vector2(-1, -1)

	update_visuals()
	print("💰 ECONOMY: White $", player_gold["White"], " | Black $", player_gold["Black"])
	update_gold_display()
	update_captured_display()
	update_slot_display()
	_maybe_let_bot_move()   
	# Online: when the game ends, offer a rematch in the same room (both clients reach
	# this identically — the mate/stalemate is detected the same way on each side).
	if is_multiplayer and game_over:
		_show_rematch_ui()


# Flips the owner's freshly-bought (locked) power-ups to ready. Called as control
# RETURNS to that player, guaranteeing nothing is usable the turn it was bought.
func ready_slots(owner: String):
	for slot in powerup_slots[owner]:
		if not slot["ready"]:
			slot["ready"] = true
			print("🔓 ", owner, "'s ", slot["name"], " is now ready to use.")


# ==========================================
# 5. VISUALS: DRAWING THE WORLD
# ==========================================


func draw_board():
	for x in range(8):
		for y in range(8):
			var tile = ColorRect.new()
			tile.size = Vector2(TILE_SIZE, TILE_SIZE)
			tile.position = BOARD_OFFSET + Vector2(x * TILE_SIZE, y * TILE_SIZE)
			if (x + y) % 2 == 0:
				tile.color = Color.WHITE
			else:
				tile.color = Color.DIM_GRAY
			add_child(tile)

func draw_coordinates():
	# Clear any previously drawn labels so this can be re-run when the board flips.
	for child in get_children():
		if child.is_in_group("coord_label"):
			child.queue_free()
	var files = "abcdefgh"
	var board_bottom = BOARD_OFFSET.y + 8 * TILE_SIZE
	# File letters along the bottom edge. When flipped, screen column x shows the file
	# of logical column (7 - x), so the labels read h..a left-to-right.
	for x in range(8):
		var fi = (7 - x) if board_flipped else x
		var letter = Label.new()
		letter.add_to_group("coord_label")
		letter.text = files[fi]
		letter.add_theme_font_size_override("font_size", 18)
		letter.position = Vector2(BOARD_OFFSET.x + x * TILE_SIZE + TILE_SIZE / 2.0 - 5, board_bottom + 5)
		add_child(letter)
	# Rank numbers down the left edge. Screen row y shows rank 8 - y normally, or y + 1
	# when flipped (logical row 7 - y, whose rank is 8 - (7 - y) = y + 1).
	for y in range(8):
		var rank_text = str(y + 1) if board_flipped else str(8 - y)
		var number = Label.new()
		number.add_to_group("coord_label")
		number.text = rank_text
		number.add_theme_font_size_override("font_size", 18)
		number.position = Vector2(BOARD_OFFSET.x - 20, BOARD_OFFSET.y + y * TILE_SIZE + TILE_SIZE / 2.0 - 12)
		add_child(number)

func draw_shop_ui():
	var start_x = 1120
	
	var current_y = 70 
	
	var item_spacing = 42 
	
	var shop_structure = {
		"DEFENSE": [
			{"name": "Ground", "cost": "$3", "desc": "1 Turn"},
			{"name": "Shield", "cost": "$5", "desc": "1 Turn"}
		],
		"MOVEMENT": [
			{"name": "Phase", "cost": "$6", "desc": "Instant"},
			{"name": "Teleport", "cost": "$8", "desc": "Instant"}
		],
		"ATTACK": [
			{"name": "Super Pawn", "cost": "$10", "desc": "Perm."},
			{"name": "Capture", "cost": "$7", "desc": "Instant"}
		],
		"ECONOMY": [
			{"name": "Multiply", "cost": "$2", "desc": "1 Turn"},
			{"name": "Negate", "cost": "$4", "desc": "1 Turn"}
		],
		"UBER": [
			{"name": "Cheat", "cost": "$15", "desc": "Instant"},
			{"name": "Revive", "cost": "Dyn.", "desc": "Perm."}
		]
	}
	
	var shop_title = Label.new()
	shop_title.text = "--- ÜBERCHESS SHOP ---"
	shop_title.position = Vector2(start_x - 20, current_y)
	shop_title.add_theme_font_size_override("font_size", 22) # Larger Title
	add_child(shop_title)
	
	current_y += 50 # A larger gap before the first class begins
	
	# Shared hover highlight; the empty focus box kills the lingering outline after a
	# click. Background-only — font colors (affordability/selection) are separate.
	var hover_sb = StyleBoxFlat.new()
	hover_sb.bg_color = Color(0.85, 0.85, 0.9, 0.22)
	hover_sb.set_corner_radius_all(5)
	hover_sb.content_margin_left = 6
	hover_sb.content_margin_right = 6
	var empty_focus_sb = StyleBoxEmpty.new()
	
	for category in shop_structure.keys():
		
		var header = Label.new()
		header.text = "[" + category + "]"
		header.position = Vector2(start_x, current_y)
		header.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0)) 
		header.add_theme_font_size_override("font_size", 20) # Larger Header
		add_child(header)
		current_y += item_spacing
		
		for item in shop_structure[category]:
			var item_btn = Button.new()
			item_btn.text = item["name"] + " (" + item["cost"] + ")"
			
			item_btn.position = Vector2(start_x + 15, current_y - 5) 
			item_btn.add_theme_font_size_override("font_size", 18)
			
			item_btn.flat = true 
			
			# Faint gray hover highlight (and no lingering focus outline after clicking).
			item_btn.add_theme_stylebox_override("hover", hover_sb)
			item_btn.add_theme_stylebox_override("hover_pressed", hover_sb)
			item_btn.add_theme_stylebox_override("focus", empty_focus_sb)
			
			# Parse "$5" -> 5. Revive's dynamic cost is handled via the tray, not here.
			var cost_int = 0
			if item["cost"] != "Dyn.":
				cost_int = int(item["cost"].replace("$", ""))

			# Stash the cost on the button so refresh_shop_affordability() can recompute
			# buyable/unaffordable coloring later without re-parsing the label text.
			item_btn.set_meta("cost", cost_int)
			item_btn.set_meta("item_name", item["name"])

			# Wire the button up to a function, passing it the specific item's data
			item_btn.pressed.connect(self._on_shop_item_pressed.bind(item["name"], cost_int))

			# Store the button node in our memory dictionary using the item's name as the key
			shop_buttons[item["name"]] = item_btn

			add_child(item_btn)
			current_y += item_spacing

	# Paint initial affordability colors now that every button exists.
	refresh_shop_affordability()

func spawn_visual_pieces():
	for pos in board_state.keys():
		var piece_data = board_state[pos]
		var new_piece = PIECE_SCENE.instantiate()

		# A Super Pawn keeps type "Pawn" but uses its own dedicated art.
		var image_name = "SuperPawn" if piece_data.get("is_super_pawn", false) else piece_data["type"]
		var sprite = new_piece.get_node("Sprite2D")
		sprite.texture = load("res://assets/pieces/" + piece_data["color"] + "_" + image_name + ".png")
		sprite.scale = Vector2.ONE * (TILE_SIZE / sprite.texture.get_size().x)

		var mod = piece_data.get("modifier", "")
		if MOD_TINTS.has(mod):
			sprite.modulate = MOD_TINTS[mod]

		new_piece.position = _square_center(pos)
		# Tag with the board coordinate so animations can hide the exact piece.
		new_piece.set_meta("board_pos", pos)
		new_piece.add_to_group("board_piece")
		add_child(new_piece)

func _circle_points(radius: float, segments: int = 24) -> PackedVector2Array:
	var pts = PackedVector2Array()
	for i in range(segments):
		var angle = TAU * i / segments
		pts.append(Vector2(cos(angle), sin(angle)) * radius)
	return pts


# ==========================================
# 5.5 NETWORKING: ONLINE MULTIPLAYER (WebSocket relay)
# Connection lifecycle, lobby UI, the send wrapper, and the opponent-action replayer.
# ==========================================

# Grid Vector2 <-> protocol [x, y] integer array. The relay protocol uses plain
# integer pairs; board_state keys are Vector2 with float components.
func _v2arr(v: Vector2) -> Array:
	return [int(v.x), int(v.y)]

func _arr2v(a) -> Vector2:
	return Vector2(int(a[0]), int(a[1]))

# View transform: maps a LOGICAL board coord to the on-screen coord it should render
# at — and back, since a 180° flip is its own inverse. board_state, all move logic,
# and the wire protocol always use logical coords; only drawing and click-decoding
# pass through here, so flipping the view can never desync the game.
func _disp(pos: Vector2) -> Vector2:
	if board_flipped:
		return Vector2(7 - pos.x, 7 - pos.y)
	return pos

# Single chokepoint for every outbound message. No-ops unless we're in an online
# match with an OPEN socket, AND we're not currently replaying a remote action
# (that guard is what stops an opponent's move from being echoed straight back).
func send_to_server(msg: Dictionary) -> void:
	if not is_multiplayer or net_applying_remote:
		return
	if ws == null or ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	ws.send_text(JSON.stringify(msg))

# Opens the relay connection. The actual OPEN/CLOSED transitions and all inbound
# traffic are handled in _process() below.
func _net_connect() -> void:
	ws = WebSocketPeer.new()
	var err = ws.connect_to_url(SERVER_URL)
	if err != OK:
		_net_set_status("Couldn't start the connection (error %d)." % err)
	else:
		_net_set_status("Connecting to the server…")

# Polls the socket every frame: detects OPEN/CLOSED once each, drains inbound packets,
# and kicks the inbox pump. Only active in multiplayer.
func _process(_delta):
	if not is_multiplayer or ws == null:
		return
	ws.poll()
	var st := ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _net_open_seen:
			_net_open_seen = true
			_net_set_status("Connected. Create a room, or enter a code to join.")
			_lobby_set_buttons_enabled(true)
		while ws.get_available_packet_count() > 0:
			_net_route(ws.get_packet().get_string_from_utf8())
		if not _net_pumping and not _net_inbox.is_empty():
			_pump_inbox()
	elif st == WebSocketPeer.STATE_CLOSED:
		if not _net_closed_seen:
			_net_closed_seen = true
			_net_on_closed()

# Routes one raw inbound message. Server-control and PROMOTION_CHOSEN messages are
# handled IMMEDIATELY (PROMOTION_CHOSEN must be free to unblock a move that's parked
# on `await promotion_chosen` inside the inbox pump — queueing it would deadlock).
# Chess-action messages are queued so they replay strictly in order, one fully
# completing (including animation) before the next begins.
func _net_route(raw: String) -> void:
	var msg = JSON.parse_string(raw)
	if typeof(msg) != TYPE_DICTIONARY:
		push_warning("Ignoring malformed server message: " + raw)
		return
	match str(msg.get("type", "")):
		"ROOM_CREATED":
			_net_on_room_created(str(msg.get("code", "")))
		"MATCH_START":
			_net_on_match_start(str(msg.get("your_color", "White")))
		"ERROR":
			_net_on_error(str(msg.get("message", "Unknown error")))
		"OPPONENT_DISCONNECTED":
			_net_on_opponent_left()
		"REMATCH":
			_net_on_rematch_request()
		"PROMOTION_CHOSEN":
			# Buffer AND emit: if the replay is already parked on `await promotion_chosen`
			# the emit unblocks it; if the pick arrived first, the buffer catches it.
			_net_promo_choice = str(msg.get("piece_type", "Queen"))
			promotion_chosen.emit(_net_promo_choice)
		_:
			_net_inbox.append(msg)

# Drains queued opponent actions one at a time. Each action is fully awaited (so an
# animated move finishes before the next action starts), preventing the concurrent
# board-mutation corruption that plagued early bot turns.
func _pump_inbox() -> void:
	_net_pumping = true
	while not _net_inbox.is_empty():
		var msg = _net_inbox.pop_front()
		await _apply_remote_action(msg)
	_net_pumping = false

# Finds the index of a READY slot holding `item_name` in `owner`'s row, or -1.
# Used to reconstruct the slot the opponent consumed (we get the item name over the
# wire, not the slot index).
func _find_ready_slot(owner: String, item_name: String) -> int:
	var slots: Array = powerup_slots[owner]
	for i in range(slots.size()):
		if slots[i]["name"] == item_name and slots[i]["ready"]:
			return i
	return -1

# Replays one opponent chess action by calling the SAME local function the human
# uses, with net_applying_remote=true so the call doesn't re-broadcast. When the
# opponent is acting, current_turn already equals the opponent's color on this client
# (their turn), so the existing ownership/slot/class checks all line up.
func _apply_remote_action(msg: Dictionary):
	match str(msg.get("type", "")):
		"MAKE_MOVE":
			net_applying_remote = true
			await execute_move(_arr2v(msg["from"]), _arr2v(msg["to"]))
			net_applying_remote = false
		"CHEAT_MOVE":
			var ci = _find_ready_slot(current_turn, "Cheat")
			if ci == -1:
				push_warning("Remote CHEAT_MOVE: no ready Cheat slot for " + current_turn)
				return
			held_powerup = "Cheat"
			held_slot_index = ci
			net_applying_remote = true
			await execute_cheat_move(_arr2v(msg["from"]), _arr2v(msg["to"]))
			net_applying_remote = false
		"USE_POWERUP":
			var item = str(msg.get("item", ""))
			var si = _find_ready_slot(current_turn, item)
			if si == -1:
				push_warning("Remote USE_POWERUP: no ready slot for " + item)
				return
			held_powerup = item
			held_slot_index = si
			net_applying_remote = true
			apply_powerup(_arr2v(msg["target"]))
			net_applying_remote = false
		"BUY_ITEM":
			var bitem = str(msg.get("item", ""))
			net_applying_remote = true
			_on_shop_item_pressed(bitem, int(powerup_costs.get(bitem, 0)))
			net_applying_remote = false
		"REVIVE":
			net_applying_remote = true
			_do_revive(current_turn, int(msg.get("index", -1)), _arr2v(msg["tile"]))
			net_applying_remote = false
		_:
			push_warning("Unhandled queued message type: " + str(msg.get("type", "")))

# --- SERVER MESSAGE HANDLERS ---

func _net_on_room_created(code: String) -> void:
	room_code = code
	if _lobby_code_label:
		_lobby_code_label.text = "ROOM CODE:  " + code
	_net_set_status("Share this code with your opponent. Waiting for them to join…")

func _net_on_match_start(your_color: String) -> void:
	my_side = your_color
	net_match_started = true
	# Each player views from their own side: Black rotates the board 180° (Black on the
	# bottom, White on top). Pure view change — logical coords and networking are untouched.
	board_flipped = (my_side == "Black")
	draw_coordinates()
	# Re-stack the gutter bands so the local player's bank/slots/captured sit at the
	# bottom, then redraw those rows at their new band positions.
	_layout_gutter_bands()
	update_slot_display()
	update_captured_display()
	update_gold_display()   # refreshes the shop lock for the opening turn (White to move)
	print("🌐 MATCH START — you control ", my_side)
	if _lobby:
		_lobby.queue_free()
		_lobby = null
	# Small persistent HUD note so each player knows which side they are.
	var hud = get_node_or_null("NetColorHUD")
	if hud == null:
		hud = Label.new()
		hud.name = "NetColorHUD"
		# Sits just under the TurnIndicator (y=40) and ABOVE the board's top edge
		# (the board starts at y=100), so it never overlaps the pieces. High z_index
		# keeps it clear of any overlay too.
		hud.position = Vector2(550, 72)
		hud.z_index = 50
		hud.add_theme_font_size_override("font_size", 16)
		add_child(hud)
	hud.text = "Online — you are " + my_side
	hud.modulate = Color(0.6, 0.85, 1.0)
	update_visuals()

func _net_on_error(message: String) -> void:
	_net_set_status("⚠️ " + message)
	_lobby_set_buttons_enabled(true)

func _net_on_opponent_left() -> void:
	print("🌐 Opponent disconnected.")
	if game_over:
		# Game already ended (the rematch panel may be up) - kill any pending rematch.
		rematch_remote = false
		if _rematch_status != null:
			_rematch_status.text = "Opponent left - no rematch."
		if _rematch_button != null:
			_rematch_button.disabled = true
		return
	game_over = true
	_show_net_notice("Your opponent disconnected.\nThe match has ended.")

func _net_on_closed() -> void:
	if net_match_started and not game_over:
		game_over = true
		_show_net_notice("Connection to the server was lost.")
	elif not net_match_started:
		_net_set_status("Disconnected from the server.")
		_lobby_set_buttons_enabled(false)

# --- LOBBY UI ---

func _build_lobby_ui() -> void:
	_lobby = CanvasLayer.new()
	_lobby.name = "LobbyOverlay"
	_lobby.layer = 90
	add_child(_lobby)

	var bg = ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.09, 0.94)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lobby.add_child(bg)

	var panel = VBoxContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-200, -190)
	panel.custom_minimum_size = Vector2(400, 0)
	panel.add_theme_constant_override("separation", 14)
	_lobby.add_child(panel)

	var title = Label.new()
	title.text = "ÜBERCHESS — ONLINE"
	title.add_theme_font_size_override("font_size", 30)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)

	_lobby_status = Label.new()
	_lobby_status.text = "Connecting…"
	_lobby_status.add_theme_font_size_override("font_size", 16)
	_lobby_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lobby_status.custom_minimum_size = Vector2(400, 0)
	panel.add_child(_lobby_status)

	_lobby_create_btn = Button.new()
	_lobby_create_btn.text = "Create Room"
	_lobby_create_btn.custom_minimum_size = Vector2(400, 52)
	_lobby_create_btn.add_theme_font_size_override("font_size", 20)
	_lobby_create_btn.disabled = true
	_lobby_create_btn.pressed.connect(self._on_create_room_pressed)
	panel.add_child(_lobby_create_btn)

	_lobby_code_label = Label.new()
	_lobby_code_label.text = ""
	_lobby_code_label.add_theme_font_size_override("font_size", 26)
	_lobby_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(_lobby_code_label)

	var sep = Label.new()
	sep.text = "— or join with a code —"
	sep.add_theme_font_size_override("font_size", 14)
	sep.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(sep)

	_lobby_code_input = LineEdit.new()
	_lobby_code_input.placeholder_text = "ROOM CODE"
	_lobby_code_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_code_input.max_length = 6
	_lobby_code_input.custom_minimum_size = Vector2(400, 44)
	_lobby_code_input.add_theme_font_size_override("font_size", 22)
	# Pressing Enter in the field is the same as clicking Join.
	_lobby_code_input.text_submitted.connect(func(_t): _on_join_room_pressed())
	panel.add_child(_lobby_code_input)

	_lobby_join_btn = Button.new()
	_lobby_join_btn.text = "Join Room"
	_lobby_join_btn.custom_minimum_size = Vector2(400, 52)
	_lobby_join_btn.add_theme_font_size_override("font_size", 20)
	_lobby_join_btn.disabled = true
	_lobby_join_btn.pressed.connect(self._on_join_room_pressed)
	panel.add_child(_lobby_join_btn)

	var back = Button.new()
	back.text = "← Back to Menu"
	back.custom_minimum_size = Vector2(400, 40)
	back.add_theme_font_size_override("font_size", 16)
	back.pressed.connect(self._on_main_menu_pressed)
	panel.add_child(back)

func _net_set_status(text: String) -> void:
	if _lobby_status:
		_lobby_status.text = text

func _lobby_set_buttons_enabled(on: bool) -> void:
	if _lobby_create_btn:
		_lobby_create_btn.disabled = not on
	if _lobby_join_btn:
		_lobby_join_btn.disabled = not on

func _on_create_room_pressed() -> void:
	_lobby_set_buttons_enabled(false)
	_net_set_status("Creating a room…")
	send_to_server({"type": "CREATE_ROOM"})

func _on_join_room_pressed() -> void:
	var code = _lobby_code_input.text.strip_edges().to_upper()
	if code.length() == 0:
		_net_set_status("Enter a room code first.")
		return
	_lobby_set_buttons_enabled(false)
	_net_set_status("Joining room %s…" % code)
	send_to_server({"type": "JOIN_ROOM", "code": code})

# --- REMATCH ---

# Shown to both players when an online game ends. A compact centered panel (no dimming
# backdrop, so the final position stays visible) offering Rematch or Return to Menu.
func _show_rematch_ui() -> void:
	if get_node_or_null("RematchOverlay") != null:
		return
	rematch_local = false
	rematch_remote = false
	var ov = CanvasLayer.new()
	ov.name = "RematchOverlay"
	ov.layer = 105
	add_child(ov)

	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-150, -90)
	ov.add_child(panel)

	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	_rematch_status = Label.new()
	_rematch_status.text = "Play again?"
	_rematch_status.add_theme_font_size_override("font_size", 20)
	_rematch_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rematch_status.custom_minimum_size = Vector2(280, 0)
	box.add_child(_rematch_status)

	_rematch_button = Button.new()
	_rematch_button.text = "Rematch"
	_rematch_button.custom_minimum_size = Vector2(280, 46)
	_rematch_button.add_theme_font_size_override("font_size", 18)
	_rematch_button.pressed.connect(self._on_rematch_pressed)
	box.add_child(_rematch_button)

	var menu_btn = Button.new()
	menu_btn.text = "Return to Menu"
	menu_btn.custom_minimum_size = Vector2(280, 40)
	menu_btn.add_theme_font_size_override("font_size", 16)
	menu_btn.pressed.connect(self._on_main_menu_pressed)
	box.add_child(menu_btn)

	# If the opponent already asked before this panel was built, reflect that.
	_set_rematch_status()

func _on_rematch_pressed() -> void:
	if rematch_local:
		return
	rematch_local = true
	send_to_server({"type": "REMATCH"})
	_set_rematch_status()
	if rematch_local and rematch_remote:
		_do_rematch()

func _net_on_rematch_request() -> void:
	rematch_remote = true
	_set_rematch_status()
	if rematch_local and rematch_remote:
		_do_rematch()

func _set_rematch_status() -> void:
	if _rematch_status == null:
		return
	if rematch_local and not rematch_remote:
		_rematch_status.text = "Waiting for opponent…"
		if _rematch_button:
			_rematch_button.disabled = true
	elif rematch_remote and not rematch_local:
		_rematch_status.text = "Opponent wants a rematch!"

# Both players agreed: reset to a fresh game in the SAME room, keeping colors (White to
# move). Runs identically on both clients, so the post-reset state is in sync with no
# extra coordination. Colors are kept the same for safety; swapping sides is an easy
# future tweak (just flip my_side + board_flipped on both ends here).
func _do_rematch() -> void:
	var ov = get_node_or_null("RematchOverlay")
	if ov:
		ov.queue_free()
	_rematch_status = null
	_rematch_button = null
	rematch_local = false
	rematch_remote = false

	# Reset all gameplay state to the opening position.
	player_gold = {"White": 10, "Black": 10}
	captured_pieces = {"White": [], "Black": []}
	powerup_slots = {"White": [], "Black": []}
	current_turn = "White"
	selected_square = Vector2(-1, -1)
	en_passant_target = Vector2(-1, -1)
	held_powerup = ""
	held_slot_index = -1
	used_classes_this_turn = []
	cheat_protected_square = Vector2(-1, -1)
	revive_pending = {}
	game_over = false
	winner = ""
	is_draw = false
	in_check = false
	_net_promo_choice = ""
	initialize_board()

	# Redraw everything for the fresh game.
	update_gold_display()
	update_slot_display()
	update_captured_display()
	update_visuals()
	print("🔄 Rematch accepted — board reset. White to move.")

# Full-screen notice with a single "Return to Menu" — used when the match ends
# abnormally (opponent left / connection lost).
func _show_net_notice(message: String) -> void:
	if get_node_or_null("NetNoticeOverlay") != null:
		return
	var ov = CanvasLayer.new()
	ov.name = "NetNoticeOverlay"
	ov.layer = 110
	add_child(ov)

	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.78)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(bg)

	var box = VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-180, -80)
	box.custom_minimum_size = Vector2(360, 0)
	box.add_theme_constant_override("separation", 18)
	ov.add_child(box)

	var lbl = Label.new()
	lbl.text = message
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(360, 0)
	box.add_child(lbl)

	var btn = Button.new()
	btn.text = "Return to Menu"
	btn.custom_minimum_size = Vector2(360, 48)
	btn.add_theme_font_size_override("font_size", 18)
	btn.pressed.connect(self._on_main_menu_pressed)
	box.add_child(btn)


# ==========================================
# 6. INTERACTION: MOUSE INPUT & STATE
# ==========================================

func _input(event):
	if game_over or is_animating:
		return

	if vs_bot and current_turn == bot_color:
		return

	# --- MULTIPLAYER GATE: no board input until the match starts, and only on your turn.
	# The opponent's actions arrive over the socket and are replayed automatically.
	if is_multiplayer:
		if not net_match_started:
			return
		if current_turn != my_side:
			return
		
	if event is InputEventMouseButton and event.pressed:
		# RIGHT CLICK: Drop the item and cancel the purchase / revive
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if not revive_pending.is_empty():
				print("✨ Revive canceled.")
				revive_pending = {}
				update_visuals()
			cancel_powerup()
			
		# LEFT CLICK: Proceed with normal board interaction
		elif event.button_index == MOUSE_BUTTON_LEFT:
			var grid_pos = ((event.position - BOARD_OFFSET) / TILE_SIZE).floor()
			# Decode the on-screen square back to a logical board coord (no-op unless flipped).
			grid_pos = _disp(grid_pos)
			if is_within_bounds(grid_pos):
				handle_click(grid_pos)

func cancel_powerup():
	if held_powerup != "":
		print("🚫 Put ", held_powerup, " back in its slot.")
		held_powerup = ""
		held_slot_index = -1
		selected_square = Vector2(-1, -1)
		clear_shop_highlights()
		update_slot_display()
		update_visuals()

# Cheat-move targets: the puppeted piece's raw geometry, minus any square holding
# a King (a cheat move may never capture either King).
func get_cheat_moves(pos: Vector2) -> Array:
	var out = []
	for t in get_legal_moves(pos):
		if board_state.has(t) and board_state[t]["type"] == "King":
			continue
		out.append(t)
	return out

# Two-click flow while holding Cheat: first click picks an opponent's (non-King)
# piece, second click moves it. Does NOT end the turn — the cheater then plays normally.
func handle_cheat_click(clicked_pos: Vector2):
	if selected_square == Vector2(-1, -1):
		if board_state.has(clicked_pos) \
		and board_state[clicked_pos]["color"] != current_turn \
		and board_state[clicked_pos]["type"] != "King":
			selected_square = clicked_pos
			update_visuals()
		else:
			print("🃏 Cheat: pick an opponent piece (not their King) to puppet.")
		return
	
	# A puppet piece is already selected; this click is the destination.
	var dests = get_cheat_moves(selected_square)
	if clicked_pos in dests:
		await execute_cheat_move(selected_square, clicked_pos)
	elif board_state.has(clicked_pos) \
	and board_state[clicked_pos]["color"] != current_turn \
	and board_state[clicked_pos]["type"] != "King":
		# Clicked a different opponent piece — re-target.
		selected_square = clicked_pos
		update_visuals()
	else:
		# Invalid destination — drop the selection so they can re-pick.
		selected_square = Vector2(-1, -1)
		update_visuals()

# Relocates an opponent piece as the Cheat action. No gold, no turn swap. The
# destination becomes protected from the cheater's capture for the rest of the turn.
func execute_cheat_move(from_pos: Vector2, to_pos: Vector2):
	if not board_state.has(from_pos):
		return
	# --- NETWORK: broadcast the cheat relocation before it animates/commits locally ---
	send_to_server({"type": "CHEAT_MOVE", "from": _v2arr(from_pos), "to": _v2arr(to_pos)})
	var piece = board_state[from_pos]
	
	if board_state.has(to_pos):
		var victim = board_state[to_pos]
		print("🃏 Cheat collateral: ", victim.get("color", ""), " ", victim.get("type", "?"), " removed (no gold).")
		record_capture(victim)
		board_state.erase(to_pos)

	# Animate the puppeted piece sliding to its new square (was an instant teleport).
	var slide_name = "SuperPawn" if piece.get("is_super_pawn", false) else piece["type"]
	var slide_path = "res://assets/pieces/" + piece["color"] + "_" + slide_name + ".png"
	is_animating = true
	await get_tree().process_frame
	_hide_piece_at(from_pos)
	_hide_piece_at(to_pos)
	await _slide_piece(slide_path, from_pos, to_pos)
	is_animating = false

	board_state.erase(from_pos)
	piece["has_moved"] = true
	board_state[to_pos] = piece
	cheat_protected_square = to_pos
	
	# Gold was already paid when Cheat was bought into the slot; just book the use and
	# free the slot. (No turn swap — the cheater still plays their own move.)
	used_classes_this_turn.append(powerup_classes["Cheat"])
	_consume_held_slot()
	print("🃏 CHEAT: ", current_turn, " puppeted the opponent's ", piece["type"], " from ", from_pos, " to ", to_pos)
	
	# It's still the cheater's turn — clear the cheat state; they now play their own move.
	held_powerup = ""
	selected_square = Vector2(-1, -1)
	clear_shop_highlights()
	update_gold_display()
	update_slot_display()
	update_visuals()

func handle_click(clicked_pos: Vector2):
	# REVIVE PLACEMENT MODE: a revive is waiting for a target starting square.
	if not revive_pending.is_empty():
		if clicked_pos in revive_pending["candidates"]:
			_do_revive(revive_pending["owner"], revive_pending["index"], clicked_pos)
		else:
			print("✨ Revive canceled.")
			revive_pending = {}
			update_visuals()
		return

	# SCENARIO 0: holding a power-up from the shop
	if held_powerup != "":
		if held_powerup == "Cheat":
			handle_cheat_click(clicked_pos)
		else:
			apply_powerup(clicked_pos)
		return

	# SCENARIO A: nothing selected — try to select a piece
	if selected_square == Vector2(-1, -1):
		if board_state.has(clicked_pos) and board_state[clicked_pos]["color"] == current_turn:
			var active_modifier = board_state[clicked_pos].get("modifier", "")
			if active_modifier == "Ground":
				print("⚓ This piece is Grounded and cannot move this turn.")
				return
			selected_square = clicked_pos
			if active_modifier != "":
				highlight_shop_button(active_modifier)
			update_visuals()

	# SCENARIO B: a piece is selected — try to move it
	else:
		var safe_futures = get_safe_moves(selected_square)
		if clicked_pos in safe_futures:
			var move_from = selected_square   # remember the origin before we clear it
			# Clear the selection + its move-indicator dots BEFORE the slide starts,
			# so they don't linger on screen during the animation.
			selected_square = Vector2(-1, -1)
			clear_shop_highlights()
			update_visuals()
			# execute_move is async (awaits the slide tween); await it so we don't
			# redraw mid-animation.
			await execute_move(move_from, clicked_pos)
		else:
			# Misclick: just drop the selection and redraw.
			selected_square = Vector2(-1, -1)
			clear_shop_highlights()
			update_visuals()

func update_visuals():
	# --- 1. UPDATE TURN INDICATOR UI ---
	var indicator = get_node_or_null("TurnIndicator")
	if indicator:
		if game_over:
			if is_draw:
				indicator.text = "Stalemate — Draw!"
				indicator.modulate = Color(0.75, 0.75, 0.75)
			else:
				indicator.text = "Checkmate! " + winner + " wins!"
				indicator.modulate = Color(1, 0.84, 0)
		else:
			var base = "WHITE'S TURN" if current_turn == "White" else "BLACK'S TURN"
			if in_check:
				indicator.text = base + " — Check!"
				indicator.modulate = Color(1, 0.3, 0.3)
			else:
				indicator.text = base
				indicator.modulate = Color.WHITE if current_turn == "White" else Color.BLACK
		# While placing a revive, the indicator becomes a placement prompt.
		if not revive_pending.is_empty():
			indicator.text = "Revive " + revive_pending["type"] + " — pick a square"
			indicator.modulate = Color(0.2, 0.9, 0.9)

	# --- 2. DESTROY OLD VISUALS ---
	# Pieces are caught by their Sprite2D; every highlight/dot/ring is tagged into
	# the "dynamic_overlay" group, so auto-renamed duplicates still get cleared.
	for child in get_children():
		if child.name == "TurnIndicator":
			continue
		if child.name.begins_with("AnimGhost"):
			continue  # leave in-flight animation ghosts alone
		if child.is_in_group("dynamic_overlay") or child.name.begins_with("Piece") or child.has_node("Sprite2D"):
			child.queue_free()

	# --- 3. DRAW SELECTION HIGHLIGHT (behind the pieces) ---
	if selected_square != Vector2(-1, -1):
		var highlight = ColorRect.new()
		highlight.add_to_group("dynamic_overlay")
		highlight.size = Vector2(TILE_SIZE, TILE_SIZE)
		highlight.position = BOARD_OFFSET + (_disp(selected_square) * TILE_SIZE)
		highlight.color = Color(1, 1, 0, 0.4)
		highlight.z_index = 0
		add_child(highlight)

	# --- 3.5. DRAW REVIVE CANDIDATE SQUARES (cyan, behind pieces) ---
	if not revive_pending.is_empty():
		for tile in revive_pending["candidates"]:
			var rev = ColorRect.new()
			rev.add_to_group("dynamic_overlay")
			rev.size = Vector2(TILE_SIZE, TILE_SIZE)
			rev.position = BOARD_OFFSET + (_disp(tile) * TILE_SIZE)
			rev.color = Color(0.2, 0.9, 0.9, 0.45)
			rev.z_index = 0
			add_child(rev)

	# --- 4. DRAW PIECES ---
	spawn_visual_pieces()

	# --- 4.5. DRAW SHIELD BUBBLES (translucent blue, over every shielded piece) ---
	# Drawn for ALL shielded pieces regardless of selection, so both players can
	# see what's currently protected. z_index sits above the piece sprite but the
	# low alpha lets the piece show through, reading as a force field.
	for pos in board_state.keys():
		if board_state[pos].get("modifier", "") == "Shield":
			var bubble_center = BOARD_OFFSET + (_disp(pos) * TILE_SIZE) + Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)

			var bubble = Polygon2D.new()
			bubble.add_to_group("dynamic_overlay")
			bubble.polygon = _circle_points(TILE_SIZE * 0.45)
			bubble.color = Color(0.3, 0.6, 1.0, 0.30) # transparent blue fill
			bubble.position = bubble_center
			bubble.z_index = 5
			add_child(bubble)

			var rim = Line2D.new()
			rim.add_to_group("dynamic_overlay")
			var rim_pts = _circle_points(TILE_SIZE * 0.45)
			rim_pts.append(rim_pts[0])
			rim.points = rim_pts
			rim.width = 3.0
			rim.default_color = Color(0.4, 0.7, 1.0, 0.85) # crisper blue edge
			rim.antialiased = true
			rim.position = bubble_center
			rim.z_index = 5
			add_child(rim)

	# --- 5. DRAW MOVE INDICATORS (on top of the pieces) ---
	if selected_square != Vector2(-1, -1):
		# While puppeting an enemy piece with Cheat, show its raw geometry instead.
		var move_list = get_cheat_moves(selected_square) if held_powerup == "Cheat" else get_safe_moves(selected_square)
		# Only a pawn can capture en passant, so the ghost square only reads as a
		# capture when the selected piece is itself a pawn. For any other piece it's
		# just an empty square it happens to be able to reach (a normal move dot).
		var selected_is_pawn: bool = board_state.has(selected_square) and board_state[selected_square]["type"] == "Pawn"
		for target in move_list:
			var is_capture = board_state.has(target) or (selected_is_pawn and target == en_passant_target)
			var center = BOARD_OFFSET + (_disp(target) * TILE_SIZE) + Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
			if is_capture:
				var ring = Line2D.new()
				ring.add_to_group("dynamic_overlay")
				var pts = _circle_points(TILE_SIZE * 0.42)
				pts.append(pts[0])
				ring.points = pts
				ring.width = 6.0
				ring.default_color = Color(0.9, 0.2, 0.2, 0.9)
				ring.antialiased = true
				ring.position = center
				ring.z_index = 10
				add_child(ring)
			else:
				var dot = Polygon2D.new()
				dot.add_to_group("dynamic_overlay")
				dot.polygon = _circle_points(14)
				dot.color = Color(0.2, 0.8, 0.3, 0.85)
				dot.position = center
				dot.z_index = 10
				add_child(dot)
