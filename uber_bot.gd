extends RefCounted
class_name UberBot

# UberBot — the AI opponent. plan_turn() returns an ORDERED action list for one turn:
#   [optional power-up uses, <=1 per class] + [optional buy] + [move OR revive]
# Search: iterative-deepening negamax to a time budget, alpha-beta with MVV-LVA +
# killer moves, quiescence at the leaves, make/unmake (no board copies). Eval is
# UberChess-aware (material, position, Shield/Ground/Super Pawn, gold). Randomizes
# only among truly tied moves, and only during the opening.
#
# Action shapes (game.gd executes these):
#   {"kind": "use",    "item": <String>, "target": <Vector2>}
#   {"kind": "cheat",  "from": <Vector2>, "to": <Vector2>}
#   {"kind": "buy",    "item": <String>}
#   {"kind": "revive", "index": <int>,   "tile": <Vector2>}   # terminal
#   {"kind": "move",   "from": <Vector2>, "to": <Vector2>}    # terminal

var game
var rng := RandomNumberGenerator.new()

# --- SEARCH TUNABLES ---
# MAX_THINK_MS and MAX_DEPTH are the only knobs difficulty touches; _init() overrides
# them from GameConfig's preset. Defaults equal the "Hard" tier.
var MAX_THINK_MS    := 2500   # time budget per move (ms). Iterative deepening stops
							  # when this is exceeded. 2500 ~= "up to ~2.5s think".
var MAX_DEPTH       := 6      # hard ceiling on iterative-deepening depth
const QUIESCENCE_CAP  := 6      # max extra plies the capture-only quiescence search runs
const MATE_SCORE      := 1000000.0
const OPENING_PLIES   := 6      # randomize among tied moves only this many half-moves in

# --- EVALUATION WEIGHTS (centipawn-ish; a pawn ~= 100) ---
const VAL := {"Pawn": 100, "Knight": 320, "Bishop": 330, "Rook": 500, "Queen": 900, "King": 0}
const SUPERPAWN_VALUE   := 850   # a Super Pawn is a near-Queen threat (moves both ways)
const SHIELD_BONUS      := 120   # a shielded piece is hard to remove — bank some of its value
const GROUND_BONUS      := 60    # grounded = invulnerable but frozen this turn
const GOLD_WEIGHT       := 6.0   # per $ of gold lead — enough to value saving for a Cheat
const GOLD_HOARD_BONUS  := 40    # extra for sitting on >= a Cheat's price (a real plan)
const TIE_EPSILON       := 0.5   # root moves within this score count as a true tie
# In the opening, randomize among ALL root moves within this many centipawns of the best —
# not just exact ties. Stops the bot from robotically maxing the piece-square table every
# game (e.g. always shoving both knights out first) by letting near-equal developing moves
# (knights, centre pawns, bishops) trade off. Only applies for the first OPENING_PLIES.
const OPENING_VARIETY_CP := 35.0

# --- POWER-UP VALUE THRESHOLDS (piece values: P1 N3 B3 R5 Q9) ---
const SHIELD_MIN_VALUE   := 3
const NEGATE_MIN_VALUE   := 3
const MULTIPLY_MIN_VALUE := 3
const CAPTURE_MIN_VALUE  := 3
const TELEPORT_MIN_VALUE := 3
const REVIVE_MIN_VALUE   := 5
const CHEAT_MIN_DISRUPT  := 3
const GOLD_RESERVE       := 0

# --- POWER-UP SEARCH (Step 1 of the overhaul) ---
# A power-up turn must out-score "just play the best plain move" by this many centipawns
# (judged by the same negamax lookahead) before the bot will spend the power-up. Small, so
# it won't pass up a real gain, but enough to stop frivolous use for a rounding-error edge.
const PU_SEARCH_MARGIN   := 12.0

# --- POWER-UP USE PROBABILITY (kept: power-up timing should still feel human, but these
# are high so it rarely passes up a genuinely good use) ---
const USE_PROB := {
	"Capture":   0.95,
	"Phase":     0.85,
	"Teleport":  0.80,
	"SuperPawn": 0.55,
	"Multiply":  0.95,
	"Negate":    0.85,
	"Defense":   0.90,
	"Uber":      0.70,
}
const BUY_CHANCE := 0.85

const BUY_WEIGHTS := {
	"Multiply": 5, "Ground": 4, "Negate": 4, "Shield": 4,
	"Capture": 3, "Phase": 3, "Teleport": 2, "Super Pawn": 2, "Cheat": 1,
}

# --- SEARCH STATE (reset each plan_turn) ---
var _deadline_us := 0
var _timed_out := false
var _killers := {}        # depth -> [moveA, moveB] that caused beta cutoffs (ordering aid)
var _root_color := "White"

# --- TRANSPOSITION TABLE + ZOBRIST (step 2) ---
# _tt maps a Zobrist position hash -> {depth, score, flag, move}. flag: 0=EXACT,
# 1=LOWER (fail-high), 2=UPPER (fail-low). Cleared at the start of every _best_move.
# _hash is the running Zobrist key, kept in sync by _make/_unmake (make XORs the deltas;
# unmake just restores the snapshot stored in the undo record). _zkeys lazily caches a
# random 64-bit int per piece-signature@square (and per EP square); keys stay stable for
# the bot's lifetime so equal positions always hash equally.
var _tt := {}
var _hash := 0
var _zkeys := {}
var _zobrist_side := 0

func _init(game_ref):
	game = game_ref
	rng.randomize()
	_zobrist_side = _rand64()

	# Difficulty only caps how hard the bot is allowed to think — its decision logic is
	# untouched. Read the depth/time budget from GameConfig if the autoload is present;
	# otherwise keep the Hard-tier defaults declared above.
	var cfg = Engine.get_main_loop().root.get_node_or_null("GameConfig") if Engine.get_main_loop() else null
	if cfg != null:
		MAX_DEPTH = cfg.bot_max_depth()
		MAX_THINK_MS = cfg.bot_think_ms()
		print("🤖 UberBot difficulty: ", cfg.difficulty_label(), " (depth ", MAX_DEPTH, ", ", MAX_THINK_MS, "ms)")

func _roll(p: float) -> bool:
	return rng.randf() < p

# =====================================================================
# TURN PLANNING
# =====================================================================

func plan_turn(color: String) -> Array:
	# STEP 1 OF THE POWER-UP OVERHAUL — the bot's own TACTICAL power-ups and its terminal
	# action (move OR revive) are now chosen by SEARCH, not heuristics + dice. We build a
	# small set of candidate turns, score each with the real negamax (the opponent's best
	# reply, evaluated to _candidate_depth()), and keep the one that beats "just play the
	# best plain move" by PU_SEARCH_MARGIN. So shielding a threatened rook, phase-capturing
	# a queen, or reviving a piece only happens when the lookahead says it's actually best.
	#
	# Search-driven here: Capture, Phase, Teleport, Super Pawn, Shield, Ground, Revive.
	# Still heuristic (folded into search in later steps): Cheat (Uber — a coordination
	# tool, Step 3), and the economy buffs Multiply / Negate + buying (their value is gold
	# income, which make/unmake doesn't model yet — Step 3). Opponent power-ups inside the
	# search are Step 2. Until then the search treats the opponent as playing pure chess.
	var planned := []                 # classes spoken for this turn (mirrors used_classes_this_turn)
	var cheat_action = null
	var saved_board = null
	var saved_ep = null
	var saved_cps = null

	# --- HEURISTIC CHEAT (Uber), unchanged behaviour. Cheat reshapes the board, so it is
	# decided first and everything below is planned in the relocated position. While Cheat
	# is in play the Uber class is spent, so Revive is off the table this turn (their
	# arbitration becomes search-driven in Step 3). ---
	if _ready_has(color, "Cheat") and _roll(USE_PROB["Uber"]):
		var ch = _best_cheat(color)
		if ch != null:
			saved_board = game.board_state.duplicate(true)
			saved_ep = game.en_passant_target
			saved_cps = game.cheat_protected_square
			var moved_piece = game.board_state[ch["from"]]
			game.board_state.erase(ch["to"])
			game.board_state.erase(ch["from"])
			game.board_state[ch["to"]] = moved_piece
			game.cheat_protected_square = ch["to"]
			cheat_action = {"kind": "cheat", "from": ch["from"], "to": ch["to"]}
			planned.append("Uber")

	# --- DEEP SEARCH: the plain best move in the (possibly cheated) position. ---
	var base = _best_move(color)
	if base == null:
		# No legal move (game already over, or a cheat with no follow-up). Drop the cheat
		# and let game.gd's safety net handle the (terminal) position.
		if saved_board != null:
			game.board_state = saved_board
			game.en_passant_target = saved_ep
			game.cheat_protected_square = saved_cps
		return []

	# --- POWER-UP CANDIDATE SEARCH: choose the best (tactical buff? + terminal) turn. ---
	var chosen = _choose_primary(color, base, planned)
	for c in chosen["classes"]:
		if c not in planned:
			planned.append(c)

	# --- ASSEMBLE: pre-move actions first (cheat, tactical use, economy uses, buy), then the
	# terminal move/revive last — the terminal action is what ends the turn. ---
	var pre := []
	if cheat_action != null:
		pre.append(cheat_action)
	for a in chosen["pre"]:
		pre.append(a)
	if not chosen["reviving"]:
		_layer_economy(color, pre, chosen["move"], planned)
		var buy = _plan_buy(color)
		if buy != null:
			pre.append(buy)
	pre.append(chosen["terminal"])

	# Restore the real board if we cheated (game.gd re-applies the cheat for real on execute).
	if saved_board != null:
		game.board_state = saved_board
		game.en_passant_target = saved_ep
		game.cheat_protected_square = saved_cps

	return pre

# Depth used to score power-up candidates. A notch below the main search so the extra
# branching stays affordable, but still scales with difficulty.
func _candidate_depth() -> int:
	return clampi(MAX_DEPTH - 2, 2, 6)

# Builds and SEARCH-SCORES the bot's candidate turns, returning the best as:
#   {"pre": [<use actions>], "terminal": <move|revive action>, "classes": [...],
#    "move": {from,to}|null, "reviving": bool}
# The reference is just playing the plain best move; a power-up turn must beat it by
# PU_SEARCH_MARGIN to win. Scoring gets its own fresh clock — the deep search above may
# have eaten most of the main budget, and without a reset every candidate would insta-time-out.
func _choose_primary(color: String, base: Dictionary, planned: Array) -> Dictionary:
	_deadline_us = Time.get_ticks_usec() + MAX_THINK_MS * 1000
	_timed_out = false
	var cdepth = _candidate_depth()

	var best_score = _score_turn(color, [{"kind": "move", "from": base["from"], "to": base["to"]}], cdepth)
	var best = {
		"pre": [], "terminal": {"kind": "move", "from": base["from"], "to": base["to"]},
		"classes": [], "move": {"from": base["from"], "to": base["to"]}, "reviving": false,
	}

	for cand in _gen_powerup_candidates(color, base, planned):
		if _timed_out:
			break
		var s = _score_turn(color, cand["score_actions"], cdepth)
		if _timed_out:
			break
		if s > best_score + PU_SEARCH_MARGIN:
			best_score = s
			best = {
				"pre": cand["pre"], "terminal": cand["terminal"], "classes": cand["classes"],
				"move": cand.get("move", null), "reviving": cand.get("reviving", false),
			}
	return best

# Proposes candidate power-up turns. Each generator (kept from the old heuristic layer) is
# now just a PROPOSER of plausible targets; SEARCH decides whether any of them is worth it.
# "score_actions" is the internal action list _score_turn applies; "pre"/"terminal" are the
# game.gd output actions. For instant offensive buffs (Capture/Phase/Teleport) the scored
# turn is just _make(from->to): the resulting position is identical whether or not the
# modifier is set (the modifier only unlocked the geometry, and is consumed at turn end).
func _gen_powerup_candidates(color: String, base: Dictionary, planned: Array) -> Array:
	var out := []
	var bf = base["from"]
	var bt = base["to"]

	# OFFENSIVE: Capture / Phase reach a capture normal geometry can't; Teleport escapes.
	if _ready_has(color, "Capture") and not _class_used("Attack", planned):
		var oc = _best_capture_with_buff(color, "Capture")
		if oc != null:
			out.append(_offensive_candidate("Capture", "Attack", oc))
	if _ready_has(color, "Phase") and not _class_used("Movement", planned):
		var op = _best_capture_with_buff(color, "Phase")
		if op != null:
			out.append(_offensive_candidate("Phase", "Movement", op))
	if _ready_has(color, "Teleport") and not _class_used("Movement", planned):
		var oe = _best_teleport(color)
		if oe != null:
			out.append(_offensive_candidate("Teleport", "Movement", oe))

	# SUPER PAWN (Attack): upgrade a pawn, then play the plain best move. Never the mover —
	# its move geometry would change under it (e.g. a planned double-push becomes illegal).
	if _ready_has(color, "Super Pawn") and not _class_used("Attack", planned):
		var sp = _pick_superpawn_target(color, [bf])
		if sp != Vector2(-1, -1):
			out.append({
				"score_actions": [{"kind": "superpawn", "target": sp}, {"kind": "move", "from": bf, "to": bt}],
				"pre": [{"kind": "use", "item": "Super Pawn", "target": sp}],
				"terminal": {"kind": "move", "from": bf, "to": bt},
				"classes": ["Attack"], "move": {"from": bf, "to": bt}, "reviving": false,
			})

	# DEFENSE (Shield / Ground): protect a genuinely threatened piece (never the mover),
	# then play the plain best move. Only the top couple of threatened pieces are proposed.
	if not _class_used("Defense", planned):
		var dcands = _threatened_targets(color, SHIELD_MIN_VALUE, [bf])
		dcands.sort_custom(func(a, b): return a["val"] > b["val"])
		for i in range(mini(2, dcands.size())):
			var p = dcands[i]["pos"]
			if _ready_has(color, "Shield"):
				out.append(_defense_candidate("Shield", p, bf, bt))
			if _ready_has(color, "Ground"):
				out.append(_defense_candidate("Ground", p, bf, bt))

	# REVIVE (Uber, terminal): each affordable fallen piece worth bringing back, on a safe
	# starting square. Only if the Uber class is still free (no Cheat this turn).
	if not _class_used("Uber", planned):
		for rv in _revive_candidates(color):
			out.append({
				"score_actions": [{"kind": "revive", "index": rv["index"], "tile": rv["tile"], "color": color}],
				"pre": [],
				"terminal": {"kind": "revive", "index": rv["index"], "tile": rv["tile"]},
				"classes": ["Uber"], "move": null, "reviving": true,
			})

	return out

func _offensive_candidate(item: String, cls: String, mv: Dictionary) -> Dictionary:
	return {
		"score_actions": [{"kind": "move", "from": mv["from"], "to": mv["to"]}],
		"pre": [{"kind": "use", "item": item, "target": mv["from"]}],
		"terminal": {"kind": "move", "from": mv["from"], "to": mv["to"]},
		"classes": [cls], "move": {"from": mv["from"], "to": mv["to"]}, "reviving": false,
	}

func _defense_candidate(item: String, target: Vector2, bf: Vector2, bt: Vector2) -> Dictionary:
	return {
		"score_actions": [{"kind": "modifier", "item": item, "target": target}, {"kind": "move", "from": bf, "to": bt}],
		"pre": [{"kind": "use", "item": item, "target": target}],
		"terminal": {"kind": "move", "from": bf, "to": bt},
		"classes": ["Defense"], "move": {"from": bf, "to": bt}, "reviving": false,
	}

# Heuristic ECONOMY layer (Multiply / Negate), appended to `pre` BEFORE the terminal move.
# Their payoff is gold income, which make/unmake doesn't model yet, so they stay heuristic
# until Step 3. Anchored to the search-chosen move so they reason about the right position.
func _layer_economy(color: String, pre: Array, move, planned: Array) -> void:
	if move == null:
		return
	var mover_from = move["from"]
	var mover_to = move["to"]

	# Did the chosen turn already buff the mover (Capture/Phase/Teleport)? If so we can't
	# also Multiply it — one modifier per piece. Also note any Shield/Ground target so we
	# don't try to Negate the same piece (likewise one modifier per piece).
	var mover_buffed := false
	var defense_target = null
	for a in pre:
		if a.get("kind", "") == "use" and a.get("target", null) == mover_from:
			mover_buffed = true
		if a.get("kind", "") == "use" and a.get("item", "") in ["Shield", "Ground"]:
			defense_target = a["target"]

	# MULTIPLY (Economy): on the mover when it's taking something worthwhile.
	if not _class_used("Economy", planned) and not mover_buffed \
	and game.board_state.has(mover_to) \
	and _piece_value(game.board_state[mover_to]) >= MULTIPLY_MIN_VALUE \
	and _ready_has(color, "Multiply") and _roll(USE_PROB["Multiply"]):
		pre.append({"kind": "use", "item": "Multiply", "target": mover_from})
		planned.append("Economy")
		return   # one Economy use per turn

	# NEGATE (Economy, defensive): judged on the board AS IT WILL LOOK after the move, so we
	# don't shield a piece whose only attacker is the one we just captured. Skipped if the
	# move gives check (the opponent must answer it and can't capture anyway).
	if not _class_used("Economy", planned) and _ready_has(color, "Negate") and _roll(USE_PROB["Negate"]):
		var undo = _make({"from": mover_from, "to": mover_to})
		var gives_check = game.is_in_check(_other(color))
		var ncand = null
		if not gives_check:
			var exclude = [mover_to]
			if defense_target != null:
				exclude.append(defense_target)
			ncand = _pick_weighted(_threatened_targets(color, NEGATE_MIN_VALUE, exclude))
		_unmake(undo)
		if ncand != null:
			pre.append({"kind": "use", "item": "Negate", "target": ncand["pos"]})
			planned.append("Economy")

# =====================================================================
# POWER-UP TURN SIMULATION (Step 1): apply / score / revert a candidate turn
# =====================================================================

# Applies a candidate turn, evaluates the OPPONENT's best reply with an isolated search
# (fresh TT + re-seeded hash, so power-up/gold state can't pollute the main table or
# collide on the hash), then reverts. Returns the value to `color` (root perspective).
func _score_turn(color: String, actions: Array, cdepth: int) -> float:
	var saved_hash = _hash
	var saved_tt = _tt
	_tt = {}
	var undo = _apply_turn(actions)
	_hash = _compute_hash(_other(color))
	var s = -_negamax(cdepth - 1, -INF, INF, _other(color))
	_revert_turn(undo)
	_tt = saved_tt
	_hash = saved_hash
	return s

# Applies an internal action list (modifier / super-pawn uses, then a terminal move or
# revive) to game state, returning an undo stack reverted by _revert_turn. Only the kinds
# emitted by _gen_powerup_candidates appear here. The hash is re-seeded by the caller after
# this, so these helpers don't touch _hash themselves (only _make/_unmake do, harmlessly).
func _apply_turn(actions: Array) -> Array:
	var undo := []
	for a in actions:
		match a["kind"]:
			"modifier":
				var pos = a["target"]
				var pc = game.board_state[pos]
				undo.push_back({"kind": "modifier", "pos": pos,
					"prev_mod": pc.get("modifier", ""), "prev_dur": pc.get("modifier_duration", 0)})
				pc["modifier"] = a["item"]
				pc["modifier_duration"] = int(game.powerup_durations.get(a["item"], 1))
			"superpawn":
				var pos2 = a["target"]
				var pc2 = game.board_state[pos2]
				undo.push_back({"kind": "superpawn", "pos": pos2, "prev_sp": pc2.get("is_super_pawn", false)})
				pc2["is_super_pawn"] = true
			"move":
				undo.push_back({"kind": "move", "undo": _make({"from": a["from"], "to": a["to"]})})
			"revive":
				var rcolor = a["color"]
				var idx = a["index"]
				var tile = a["tile"]
				var entry = game.captured_pieces[rcolor][idx]
				var ptype = entry["type"]
				var cost = int(game.piece_rules[ptype]["revive_cost"])
				undo.push_back({"kind": "revive", "color": rcolor, "idx": idx, "tile": tile,
					"entry": entry, "cost": cost, "prev_ep": game.en_passant_target})
				game.board_state[tile] = {"type": ptype, "color": rcolor, "modifier": "",
					"modifier_duration": 0, "is_super_pawn": false, "has_moved": false, "is_revived": true}
				game.player_gold[rcolor] -= cost
				game.captured_pieces[rcolor].remove_at(idx)
				game.en_passant_target = Vector2(-1, -1)
	return undo

func _revert_turn(undo: Array) -> void:
	for i in range(undo.size() - 1, -1, -1):
		var u = undo[i]
		match u["kind"]:
			"modifier":
				var pc = game.board_state[u["pos"]]
				pc["modifier"] = u["prev_mod"]
				pc["modifier_duration"] = u["prev_dur"]
			"superpawn":
				var pc2 = game.board_state[u["pos"]]
				pc2["is_super_pawn"] = u["prev_sp"]
			"move":
				_unmake(u["undo"])
			"revive":
				game.board_state.erase(u["tile"])
				game.player_gold[u["color"]] += u["cost"]
				game.captured_pieces[u["color"]].insert(u["idx"], u["entry"])
				game.en_passant_target = u["prev_ep"]

# Every affordable fallen piece worth reviving (value >= REVIVE_MIN_VALUE) paired with a
# safe, empty starting square. Replaces the old single-weighted-pick _best_revive: here we
# enumerate so SEARCH can compare each revive against playing on.
func _revive_candidates(color: String) -> Array:
	var tray = game.captured_pieces[color]
	var out := []
	for i in range(tray.size()):
		var ptype = tray[i]["type"]
		var val = int(game.piece_rules[ptype]["value"])
		if val < REVIVE_MIN_VALUE:
			continue
		var cost = int(game.piece_rules[ptype]["revive_cost"])
		if game.player_gold[color] < cost:
			continue
		var safe_tile = Vector2(-1, -1)
		for tile in game.starting_positions[color][ptype]:
			if game.board_state.has(tile):
				continue
			if _revive_square_safe(color, ptype, tile):
				safe_tile = tile
				break
		if safe_tile == Vector2(-1, -1):
			continue
		out.append({"index": i, "tile": safe_tile, "val": val})
	return out

# =====================================================================
# SEARCH: iterative deepening + alpha-beta + quiescence (make/unmake)
# =====================================================================

func _best_move(color: String):
	_root_color = color
	_deadline_us = Time.get_ticks_usec() + MAX_THINK_MS * 1000
	_timed_out = false
	_killers.clear()
	_tt.clear()
	_hash = _compute_hash(color)

	var root_moves = _ordered_moves(color, 0)
	if root_moves.is_empty():
		return null

	var best_move = root_moves[0]
	var best_scored := []        # {move, score} for every root move at the last completed depth
	var best_top := -INF         # the true best score at that depth (uses TIE_EPSILON, stays exact)

	# Iterative deepening: depth 1, 2, 3 ... until the clock runs out. Each completed
	# depth refines best_move; a depth aborted mid-way is discarded (partial), so we
	# always return the best fully-searched result.
	var depth := 1
	while depth <= MAX_DEPTH:
		var d_best_score := -INF
		var d_best_move = root_moves[0]
		var d_scored := []
		var aborted := false

		# Search the previous iteration's best move first — huge ordering win for the TT.
		_prioritize(root_moves, best_move)

		for m in root_moves:
			var undo = _make(m)
			# FULL WINDOW at the root (not a narrowed alpha-beta window). This is essential
			# for exact per-move scores: a narrowed window cuts non-best moves off at ~alpha
			# and returns only an upper bound, so a queen-hanging move could score the SAME as
			# a genuinely-good one. That would pollute the opening-variety pool below and let
			# the random pick grab a blunder. A full window gives every root move its EXACT
			# score; internal alpha-beta still prunes inside each subtree, and the TT caches
			# across siblings/iterations.
			var score = -_negamax(depth - 1, -INF, INF, _other(color))
			_unmake(undo)
			if _timed_out:
				aborted = true
				break
			d_scored.append({"move": m, "score": score})
			if score > d_best_score + TIE_EPSILON:
				d_best_score = score
				d_best_move = m

		if not aborted:
			best_move = d_best_move
			best_scored = d_scored
			best_top = d_best_score
		if _timed_out:
			break
		depth += 1

	# OPENING VARIETY: for the first OPENING_PLIES, pick at random among every root move
	# within OPENING_VARIETY_CP of the best — so near-equal developing moves (knights, centre
	# pawns, bishops) actually trade off instead of the PST's single max winning every game.
	# best_move stays the exact best for all later play and for search ordering.
	if _ply_count() < OPENING_PLIES and not best_scored.is_empty():
		var pool := []
		for e in best_scored:
			if e["score"] >= best_top - OPENING_VARIETY_CP:
				pool.append(e["move"])
		if pool.size() > 1:
			return pool[rng.randi() % pool.size()]
	return best_move

func _negamax(depth: int, alpha: float, beta: float, color: String) -> float:
	if _check_time():
		return 0.0
	if depth <= 0:
		return _quiescence(alpha, beta, color, 0)

	# --- Transposition table probe ---
	var alpha_orig := alpha
	var tt_move = null
	if _tt.has(_hash):
		var e = _tt[_hash]
		if e["depth"] >= depth:
			var f = e["flag"]
			if f == 0:
				return e["score"]                       # EXACT score, reuse directly
			elif f == 1 and e["score"] >= beta:
				return e["score"]                       # stored LOWER bound still cuts
			elif f == 2 and e["score"] <= alpha:
				return e["score"]                       # stored UPPER bound still cuts
		tt_move = e["move"]                              # too shallow to cut, but great for ordering

	var moves = _ordered_moves(color, depth)
	if moves.is_empty():
		if game.is_in_check(color):
			return -MATE_SCORE - depth   # prefer faster mates
		return 0.0                       # stalemate

	# Search the TT's remembered best move first — usually the strongest reply here.
	if tt_move != null:
		_prioritize(moves, tt_move)

	var best := -INF
	var best_move = null
	for m in moves:
		var undo = _make(m)
		var score = -_negamax(depth - 1, -beta, -alpha, _other(color))
		_unmake(undo)
		if _timed_out:
			return 0.0
		if score > best:
			best = score
			best_move = m
		if best > alpha:
			alpha = best
		if alpha >= beta:
			_remember_killer(depth, m)
			break

	# --- Transposition table store ---
	var flag := 0                       # EXACT (alpha < best < beta)
	if best <= alpha_orig:
		flag = 2                        # UPPER bound (failed low)
	elif best >= beta:
		flag = 1                        # LOWER bound (failed high)
	_tt[_hash] = {"depth": depth, "score": best, "flag": flag, "move": best_move}
	return best

# Quiescence: at the depth limit, keep searching CAPTURES ONLY until the position is
# quiet. Stops the search from stopping mid-trade and badly misjudging material.
func _quiescence(alpha: float, beta: float, color: String, qdepth: int) -> float:
	if _check_time():
		return 0.0
	var stand_pat = _evaluate(color)
	if qdepth >= QUIESCENCE_CAP:
		return stand_pat
	if stand_pat >= beta:
		return beta
	if stand_pat > alpha:
		alpha = stand_pat

	for m in _capture_moves(color):
		var undo = _make(m)
		var score = -_quiescence(-beta, -alpha, _other(color), qdepth + 1)
		_unmake(undo)
		if _timed_out:
			return 0.0
		if score >= beta:
			return beta
		if score > alpha:
			alpha = score
	return alpha

func _check_time() -> bool:
	if _timed_out:
		return true
	if Time.get_ticks_usec() >= _deadline_us:
		_timed_out = true
	return _timed_out

# =====================================================================
# MOVE GENERATION + ORDERING
# =====================================================================

# All legal (king-safe) moves for `color`, ordered for good alpha-beta pruning:
# winning captures (MVV-LVA) first, then killer moves, then quiet moves.
func _ordered_moves(color: String, depth: int) -> Array:
	var caps := []
	var quiet := []
	for pos in game.board_state.keys():
		var pc = game.board_state[pos]
		if pc["color"] != color:
			continue
		if pc.get("modifier", "") == "Ground":
			continue   # grounded pieces can't move this turn
		for dest in game.get_safe_moves(pos):
			var mv = {"from": pos, "to": dest}
			if game.board_state.has(dest):
				# MVV-LVA: value victim high, attacker low, so the most profitable captures
				# are searched first (pawn-takes-queen before queen-takes-pawn).
				mv["order"] = _raw_value(game.board_state[dest]) * 10 - _raw_value(pc)
				caps.append(mv)
			else:
				quiet.append(mv)
	caps.sort_custom(func(a, b): return a["order"] > b["order"])

	# Promote killer moves (quiet moves that caused cutoffs at this depth) to the front.
	if _killers.has(depth):
		var ks = _killers[depth]
		quiet.sort_custom(func(a, b):
			return _is_killer(a, ks) and not _is_killer(b, ks))

	return caps + quiet

# Capture-only move list for quiescence, MVV-LVA ordered.
func _capture_moves(color: String) -> Array:
	var caps := []
	for pos in game.board_state.keys():
		var pc = game.board_state[pos]
		if pc["color"] != color:
			continue
		if pc.get("modifier", "") == "Ground":
			continue
		for dest in game.get_safe_moves(pos):
			if game.board_state.has(dest):
				caps.append({"from": pos, "to": dest, "order": _raw_value(game.board_state[dest]) * 10 - _raw_value(pc)})
	caps.sort_custom(func(a, b): return a["order"] > b["order"])
	return caps

func _prioritize(moves: Array, first) -> void:
	# Move `first` (last iteration's best) to the front, in place.
	for i in range(moves.size()):
		if moves[i]["from"] == first["from"] and moves[i]["to"] == first["to"]:
			var m = moves[i]
			moves.remove_at(i)
			moves.insert(0, m)
			return

func _remember_killer(depth: int, m: Dictionary) -> void:
	# Only quiet moves make good killers (captures are already ordered well).
	if game.board_state.has(m["to"]):
		return
	if not _killers.has(depth):
		_killers[depth] = []
	var ks: Array = _killers[depth]
	for k in ks:
		if k["from"] == m["from"] and k["to"] == m["to"]:
			return
	ks.push_front({"from": m["from"], "to": m["to"]})
	if ks.size() > 2:
		ks.pop_back()

func _is_killer(m: Dictionary, ks: Array) -> bool:
	for k in ks:
		if k["from"] == m["from"] and k["to"] == m["to"]:
			return true
	return false

# =====================================================================
# MAKE / UNMAKE  (mutates board in place; unmake perfectly reverses make)
# =====================================================================

# Applies a move and returns an `undo` record carrying everything needed to reverse it.
# Handles capture, en passant, castling (rook shift), promotion, and the EP trail.
func _make(m: Dictionary) -> Dictionary:
	var bs = game.board_state
	var from_pos: Vector2 = m["from"]
	var to_pos: Vector2 = m["to"]
	var piece = bs[from_pos]

	var undo = {
		"from": from_pos, "to": to_pos,
		"piece_ref": piece,
		"prev_has_moved": piece.get("has_moved", false),
		"prev_type": piece["type"],
		"prev_ep": game.en_passant_target,
		"prev_hash": _hash,
		"captured": null, "captured_at": Vector2(-1, -1),
		"ep_captured": null, "ep_at": Vector2(-1, -1),
		"rook_from": Vector2(-1, -1), "rook_to": Vector2(-1, -1), "rook_prev_moved": false,
		"promoted": false,
	}

	var moving_type = piece["type"]
	var moving_color = piece["color"]

	# Zobrist: lift the mover off its origin square (pre-promotion signature).
	_hash ^= _z_piece(from_pos, piece)

	# En passant capture (target is the empty EP square).
	if moving_type == "Pawn" and to_pos == game.en_passant_target and not bs.has(to_pos):
		var cap_sq = Vector2(to_pos.x, from_pos.y)
		if bs.has(cap_sq):
			undo["ep_captured"] = bs[cap_sq]
			undo["ep_at"] = cap_sq
			_hash ^= _z_piece(cap_sq, bs[cap_sq])
			bs.erase(cap_sq)

	# Castling: shift the rook.
	if moving_type == "King" and abs(to_pos.x - from_pos.x) == 2:
		var rank = to_pos.y
		if to_pos.x > from_pos.x:
			var rk = Vector2(7, rank)
			if bs.has(rk):
				var rook = bs[rk]
				undo["rook_from"] = rk
				undo["rook_to"] = Vector2(5, rank)
				undo["rook_prev_moved"] = rook.get("has_moved", false)
				_hash ^= _z_piece(rk, rook)
				bs.erase(rk)
				rook["has_moved"] = true
				bs[Vector2(5, rank)] = rook
				_hash ^= _z_piece(Vector2(5, rank), rook)
		else:
			var rk2 = Vector2(0, rank)
			if bs.has(rk2):
				var rook2 = bs[rk2]
				undo["rook_from"] = rk2
				undo["rook_to"] = Vector2(3, rank)
				undo["rook_prev_moved"] = rook2.get("has_moved", false)
				_hash ^= _z_piece(rk2, rook2)
				bs.erase(rk2)
				rook2["has_moved"] = true
				bs[Vector2(3, rank)] = rook2
				_hash ^= _z_piece(Vector2(3, rank), rook2)

	# Normal capture.
	if bs.has(to_pos):
		undo["captured"] = bs[to_pos]
		undo["captured_at"] = to_pos
		_hash ^= _z_piece(to_pos, bs[to_pos])

	# Move the piece.
	bs.erase(from_pos)
	piece["has_moved"] = true
	bs[to_pos] = piece

	# Promotion (to Queen, matching the engine's auto-promote).
	if moving_type == "Pawn" and ((moving_color == "White" and to_pos.y == 0) or (moving_color == "Black" and to_pos.y == 7)):
		piece["type"] = "Queen"
		undo["promoted"] = true

	# Zobrist: set the mover down on its destination (post-promotion signature).
	_hash ^= _z_piece(to_pos, piece)

	# New EP trail on a double pawn push. Zobrist: swap the old EP key for the new one.
	_hash ^= _z_ep(game.en_passant_target)
	game.en_passant_target = Vector2(-1, -1)
	if moving_type == "Pawn" and abs(to_pos.y - from_pos.y) == 2:
		var dir = sign(to_pos.y - from_pos.y)
		game.en_passant_target = from_pos + Vector2(0, dir)
	_hash ^= _z_ep(game.en_passant_target)

	# Zobrist: side to move flips every ply.
	_hash ^= _zobrist_side

	return undo

func _unmake(undo: Dictionary) -> void:
	var bs = game.board_state
	var piece = undo["piece_ref"]
	_hash = undo["prev_hash"]   # restore the Zobrist key in one shot — no reverse XORs needed

	# Reverse promotion and the piece's move + has_moved flag.
	if undo["promoted"]:
		piece["type"] = undo["prev_type"]
	bs.erase(undo["to"])
	piece["has_moved"] = undo["prev_has_moved"]
	bs[undo["from"]] = piece

	# Restore a normal capture.
	if undo["captured"] != null:
		bs[undo["captured_at"]] = undo["captured"]

	# Restore an en passant capture.
	if undo["ep_captured"] != null:
		bs[undo["ep_at"]] = undo["ep_captured"]

	# Reverse castling rook shift.
	if undo["rook_to"] != Vector2(-1, -1):
		var rook = bs[undo["rook_to"]]
		bs.erase(undo["rook_to"])
		rook["has_moved"] = undo["rook_prev_moved"]
		bs[undo["rook_from"]] = rook

	game.en_passant_target = undo["prev_ep"]

# =====================================================================
# EVALUATION  (UberChess-aware; positive = good for `color`)
# =====================================================================

func _evaluate(color: String) -> float:
	var enemy = _other(color)
	var score := 0.0

	for pos in game.board_state.keys():
		var pc = game.board_state[pos]
		var sgn := 1.0 if pc["color"] == color else -1.0
		var v := float(_eval_value(pc))

		# Positional value from piece-square tables. This replaces BOTH the old
		# center/pawn-push proxies and the per-leaf mobility scan (which called full
		# legal-move generation for every piece on every leaf and was throttling depth).
		v += _pst_bonus(pos, pc)

		# Power-up state: a protected piece is worth more because it's hard to remove.
		var mod = pc.get("modifier", "")
		if mod == "Shield":
			v += SHIELD_BONUS
		elif mod == "Ground":
			v += GROUND_BONUS

		score += sgn * v

	# Economy: gold lead matters, and sitting on a Cheat's worth of gold is a real plan.
	var my_gold = game.player_gold[color]
	var opp_gold = game.player_gold[enemy]
	score += GOLD_WEIGHT * (my_gold - opp_gold)
	var cheat_price = int(game.powerup_costs.get("Cheat", 15))
	if my_gold >= cheat_price:
		score += GOLD_HOARD_BONUS
	if opp_gold >= cheat_price:
		score -= GOLD_HOARD_BONUS

	return score

# Value used inside search material counting (includes Super Pawn premium).
func _eval_value(pc: Dictionary) -> int:
	if pc.get("is_super_pawn", false):
		return SUPERPAWN_VALUE
	return VAL[pc["type"]]

# Raw value for move ordering.
func _raw_value(pc: Dictionary) -> int:
	if pc.get("is_super_pawn", false):
		return SUPERPAWN_VALUE
	return VAL[pc["type"]]

# Piece-square tables (centipawn-ish), written from White's perspective with row 0 = y=0
# (the rank White promotes on) down to row 7 = y=7 (White's home rank). Black mirrors
# vertically via row = 7 - y. Encodes development, centralization, rook-on-7th, and a
# middlegame king that prefers staying tucked/castled. O(1) per piece — no move generation.
const _PST := {
	"Pawn": [
		  0,  0,  0,  0,  0,  0,  0,  0,
		 50, 50, 50, 50, 50, 50, 50, 50,
		 10, 10, 20, 30, 30, 20, 10, 10,
		  5,  5, 10, 25, 25, 10,  5,  5,
		  0,  0,  0, 20, 20,  0,  0,  0,
		  5, -5,-10,  0,  0,-10, -5,  5,
		  5, 10, 10,-20,-20, 10, 10,  5,
		  0,  0,  0,  0,  0,  0,  0,  0,
	],
	"Knight": [
		-50,-40,-30,-30,-30,-30,-40,-50,
		-40,-20,  0,  0,  0,  0,-20,-40,
		-30,  0, 10, 15, 15, 10,  0,-30,
		-30,  5, 15, 20, 20, 15,  5,-30,
		-30,  0, 15, 20, 20, 15,  0,-30,
		-30,  5, 10, 15, 15, 10,  5,-30,
		-40,-20,  0,  5,  5,  0,-20,-40,
		-50,-40,-30,-30,-30,-30,-40,-50,
	],
	"Bishop": [
		-20,-10,-10,-10,-10,-10,-10,-20,
		-10,  0,  0,  0,  0,  0,  0,-10,
		-10,  0,  5, 10, 10,  5,  0,-10,
		-10,  5,  5, 10, 10,  5,  5,-10,
		-10,  0, 10, 10, 10, 10,  0,-10,
		-10, 10, 10, 10, 10, 10, 10,-10,
		-10,  5,  0,  0,  0,  0,  5,-10,
		-20,-10,-10,-10,-10,-10,-10,-20,
	],
	"Rook": [
		  0,  0,  0,  0,  0,  0,  0,  0,
		  5, 10, 10, 10, 10, 10, 10,  5,
		 -5,  0,  0,  0,  0,  0,  0, -5,
		 -5,  0,  0,  0,  0,  0,  0, -5,
		 -5,  0,  0,  0,  0,  0,  0, -5,
		 -5,  0,  0,  0,  0,  0,  0, -5,
		 -5,  0,  0,  0,  0,  0,  0, -5,
		  0,  0,  5,  5,  5,  5,  0,  0,
	],
	"Queen": [
		-20,-10,-10, -5, -5,-10,-10,-20,
		-10,  0,  0,  0,  0,  0,  0,-10,
		-10,  0,  5,  5,  5,  5,  0,-10,
		 -5,  0,  5,  5,  5,  5,  0, -5,
		  0,  0,  5,  5,  5,  5,  0, -5,
		-10,  5,  5,  5,  5,  5,  0,-10,
		-10,  0,  5,  0,  0,  0,  0,-10,
		-20,-10,-10, -5, -5,-10,-10,-20,
	],
	"King": [
		-30,-40,-40,-50,-50,-40,-40,-30,
		-30,-40,-40,-50,-50,-40,-40,-30,
		-30,-40,-40,-50,-50,-40,-40,-30,
		-30,-40,-40,-50,-50,-40,-40,-30,
		-20,-30,-30,-40,-40,-30,-30,-20,
		-10,-20,-20,-20,-20,-20,-20,-10,
		 20, 20,  0,  0,  0,  0, 20, 20,
		 20, 30, 10,  0,  0, 10, 30, 20,
	],
}

# Positional bonus for a piece on its square, from that piece's own colour's perspective
# (Black reads the table mirrored). Super pawns fall through to the Pawn table, which is
# fine — their big material premium is already handled in _eval_value.
func _pst_bonus(pos: Vector2, pc: Dictionary) -> float:
	var table = _PST.get(pc["type"], null)
	if table == null:
		return 0.0
	var row := int(pos.y) if pc["color"] == "White" else (7 - int(pos.y))
	return float(table[row * 8 + int(pos.x)])

# =====================================================================
# ZOBRIST HASHING  (keys cached lazily; equal positions always hash equally)
# =====================================================================

func _rand64() -> int:
	# GDScript ints are 64-bit; stitch two 32-bit draws into one 64-bit key.
	return (rng.randi() << 32) ^ rng.randi()

func _z_piece(pos: Vector2, pc: Dictionary) -> int:
	# A piece's signature includes modifier + super-pawn state so a Shielded or Super piece
	# never collides with a plain one on the same square.
	var sig := "%d,%d|%s|%s|%s|%s" % [int(pos.x), int(pos.y), pc["color"], pc["type"], pc.get("modifier", ""), str(pc.get("is_super_pawn", false))]
	if not _zkeys.has(sig):
		_zkeys[sig] = _rand64()
	return _zkeys[sig]

func _z_ep(sq: Vector2) -> int:
	if sq == Vector2(-1, -1):
		return 0
	var sig := "ep|%d,%d" % [int(sq.x), int(sq.y)]
	if not _zkeys.has(sig):
		_zkeys[sig] = _rand64()
	return _zkeys[sig]

# Full-board hash, used once at the top of _best_move to seed _hash before the search.
func _compute_hash(side_to_move: String) -> int:
	var h := 0
	for pos in game.board_state.keys():
		h ^= _z_piece(pos, game.board_state[pos])
	h ^= _z_ep(game.en_passant_target)
	if side_to_move == "Black":
		h ^= _zobrist_side
	return h

# Rough count of moves played so far (for opening-only variety). Pieces that have moved
# from their start squares ~= how far into the game we are.
func _ply_count() -> int:
	var moved := 0
	for pos in game.board_state.keys():
		if game.board_state[pos].get("has_moved", false):
			moved += 1
	return moved

# =====================================================================
# POWER-UP TARGETING HELPERS
# =====================================================================

func _class_used(cls: String, planned: Array) -> bool:
	return cls in game.used_classes_this_turn or cls in planned

func _slot_count(color: String) -> int:
	return game.powerup_slots[color].size()

func _has_in_slots(color: String, item: String) -> bool:
	for s in game.powerup_slots[color]:
		if s["name"] == item:
			return true
	return false

func _ready_has(color: String, item: String) -> bool:
	for s in game.powerup_slots[color]:
		if s["name"] == item and s["ready"]:
			return true
	return false

func _piece_value(pc: Dictionary) -> int:
	if pc.get("is_super_pawn", false):
		return 8
	return int(game.piece_rules[pc["type"]]["value"])

func _is_attacked(pos: Vector2, attacker: String) -> bool:
	for p in game.board_state.keys():
		if game.board_state[p]["color"] != attacker:
			continue
		if pos in game.get_legal_moves(p, true):
			return true
	return false

func _threatened_targets(color: String, min_val: int, exclude: Array) -> Array:
	var enemy = _other(color)
	var out = []
	for p in game.board_state.keys():
		if p in exclude:
			continue
		var pc = game.board_state[p]
		if pc["color"] != color or pc["type"] == "King":
			continue
		if pc.get("is_super_pawn", false) or pc.get("modifier", "") != "":
			continue
		var val = _piece_value(pc)
		if val >= min_val and _is_attacked(p, enemy):
			out.append({"pos": p, "val": val})
	return out

func _pick_weighted(cands: Array):
	if cands.is_empty():
		return null
	var total = 0.0
	for c in cands:
		total += float(c["val"])
	if total <= 0.0:
		return cands[rng.randi() % cands.size()]
	var r = rng.randf() * total
	for c in cands:
		r -= float(c["val"])
		if r <= 0.0:
			return c
	return cands[cands.size() - 1]

func _best_capture_with_buff(color: String, buff_name: String):
	var best = null
	var best_victim = CAPTURE_MIN_VALUE - 1
	for p in game.board_state.keys():
		var pc = game.board_state[p]
		if pc["color"] != color or pc["type"] == "King":
			continue
		if pc.get("is_super_pawn", false) or pc.get("modifier", "") != "":
			continue
		var plain = game.get_safe_moves(p)
		pc["modifier"] = buff_name
		var buffed = game.get_safe_moves(p)
		pc["modifier"] = ""
		for dest in buffed:
			if dest in plain or not game.board_state.has(dest):
				continue
			var victim = game.board_state[dest]
			if victim["color"] == color or victim["type"] == "King":
				continue
			var vval = _piece_value(victim)
			if vval <= best_victim:
				continue
			if _is_attacked_after(p, dest, _other(color)):
				continue
			best_victim = vval
			best = {"from": p, "to": dest, "victim": vval}
	return best

func _best_teleport(color: String):
	var cands = _threatened_targets(color, TELEPORT_MIN_VALUE, [])
	if cands.is_empty():
		return null
	var pick = _pick_weighted(cands)
	var p = pick["pos"]
	var pc = game.board_state[p]
	pc["modifier"] = "Teleport"
	var dests = game.get_safe_moves(p)
	pc["modifier"] = ""
	if dests.is_empty():
		return null
	dests.shuffle()
	for d in dests:
		if not _is_attacked_after(p, d, _other(color)):
			return {"from": p, "to": d, "gain": pick["val"]}
	return null

func _pick_superpawn_target(color: String, exclude: Array) -> Vector2:
	var cands = []
	for p in game.board_state.keys():
		if p in exclude:
			continue
		var pc = game.board_state[p]
		if pc["color"] != color or pc["type"] != "Pawn":
			continue
		if pc.get("is_super_pawn", false) or pc.get("modifier", "") != "":
			continue
		var adv = (6 - int(p.y)) if color == "White" else (int(p.y) - 1)
		cands.append({"pos": p, "val": adv + 1})
	var pick = _pick_weighted(cands)
	if pick == null:
		return Vector2(-1, -1)
	return pick["pos"]

func _best_cheat(color: String):
	var enemy = _other(color)
	var attackers = []
	var others = []
	for p in game.board_state.keys():
		var pc = game.board_state[p]
		if pc["color"] != enemy or pc["type"] == "King":
			continue
		var threatens_value = false
		for m in game.get_legal_moves(p, true):
			if game.board_state.has(m) and game.board_state[m]["color"] == color \
			and _piece_value(game.board_state[m]) >= CHEAT_MIN_DISRUPT:
				threatens_value = true
				break
		if threatens_value:
			attackers.append(p)
		else:
			others.append(p)
	var pool = attackers if not attackers.is_empty() else others
	if pool.is_empty():
		return null
	pool.shuffle()
	var from_pos = pool[0]
	var dests = game.get_cheat_moves(from_pos)
	if dests.is_empty():
		return null
	dests.shuffle()
	var chosen = dests[0]
	for d in dests:
		if not game.board_state.has(d):
			chosen = d
			break
	return {"from": from_pos, "to": chosen}

# True if a freshly revived `ptype` on `tile` would NOT be capturable by the enemy. The
# piece is placed briefly so pawn captures and slider x-rays see a real target (an empty
# square wouldn't register a pawn's diagonal), then removed. `tile` is always empty here.
func _revive_square_safe(color: String, ptype: String, tile: Vector2) -> bool:
	game.board_state[tile] = {"type": ptype, "color": color, "modifier": "", "modifier_duration": 0, "is_super_pawn": false, "has_moved": false}
	var attacked = _is_attacked(tile, _other(color))
	game.board_state.erase(tile)
	return not attacked

func _plan_buy(color: String):
	if _slot_count(color) >= game.MAX_SLOTS:
		return null
	if not _roll(BUY_CHANCE):
		return null
	var affordable = []
	for item in BUY_WEIGHTS.keys():
		if _has_in_slots(color, item):
			continue
		var cost = int(game.powerup_costs[item])
		if game.player_gold[color] - cost >= GOLD_RESERVE:
			affordable.append({"item": item, "val": BUY_WEIGHTS[item]})
	var pick = _pick_weighted(affordable)
	if pick == null:
		return null
	return {"kind": "buy", "item": pick["item"]}

# Uses make/unmake so it stays cheap even though it's called from power-up planning.
func _is_attacked_after(from_pos: Vector2, to_pos: Vector2, attacker: String) -> bool:
	var undo = _make({"from": from_pos, "to": to_pos})
	var res = _is_attacked(to_pos, attacker)
	_unmake(undo)
	return res

func _other(color: String) -> String:
	return "Black" if color == "White" else "White"
