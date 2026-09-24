extends RefCounted
class_name UberBot

# UberBot — the SEARCH ENGINE half of the AI opponent. It owns everything that runs
# PER NODE inside the search and the position-scoring services built on top of it:
# iterative-deepening negamax to a time budget, alpha-beta with MVV-LVA + killer moves,
# quiescence at the leaves, make/unmake (no board copies), UberChess-aware eval
# (material, position, Shield/Ground/Super Pawn, gold), the opponent-power-up branching
# inside _negamax, and the candidate-turn scorer (score_turn / _apply_turn / _revert_turn).
#
# The PER-TURN policy half — plan_turn, power-up candidate generation, target pickers,
# buy/economy heuristics and their tuning tables — lives in UberbotStrategy.gd, which owns
# an UberBot instance and drives it. The seam is per-turn (policy) vs per-node (search):
# anything called thousands of times inside the search stays here so it never pays a
# cross-object call; anything called a handful of times per move lives in the strategy.
# game.gd instantiates UberbotStrategy, not UberBot directly.
#
# BOARD-OWNERSHIP CONTRACT (across the strategy<->engine boundary): every method here that
# mutates game.board_state / en_passant_target / _hash / _tt restores them before it
# returns (make is paired by unmake; score_turn snapshots and restores TT+hash+opp slots).
# The strategy may call these freely knowing the board is left exactly as it was found.
#
# Action shapes (game.gd executes these):
#   {"kind": "use",    "item": <String>, "target": <Vector2>}
#   {"kind": "cheat",  "from": <Vector2>, "to": <Vector2>}
#   {"kind": "buy",    "item": <String>}
#   {"kind": "tapin",  "index": <int>,   "square": <Vector2>}  # terminal
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
# STEP 2: minimum remaining depth before we bother branching on opponent power-ups inside
# _negamax. At depth 1 or in quiescence the cost outweighs the signal — pure chess suffices
# there. Was temporarily raised to 4 while the search was still calling game.get_legal_moves
# per node (capped at ~2-3 ply, so branching near the root just collapsed it further).
# RESTORED to 2 now that the native move generator is wired in (_native_legal_moves):
# the king-capture loss in the post-movegen Bot match (Phase onto the king, depth 2 reached
# with this gate still at 4) showed the awareness needs to fire at the depths the bot
# actually reaches, even if that costs a ply elsewhere. Revisit only if profiling shows the
# branching itself — not per-node movegen — is now the bottleneck.
const OPPONENT_PU_MIN_DEPTH := 2

# --- EVALUATION WEIGHTS (centipawn-ish; a pawn ~= 100) ---
const VAL := {"Pawn": 100, "Knight": 320, "Bishop": 330, "Rook": 500, "Queen": 900, "King": 0}
const SUPERPAWN_VALUE   := 850   # a Super Pawn is a near-Queen threat (moves both ways)
const SHIELD_BONUS      := 120   # a shielded piece is hard to remove — bank some of its value
const GROUND_BONUS      := 60    # grounded = invulnerable but frozen this turn
const GOLD_WEIGHT       := 6.0   # per $ of gold lead — enough to value saving for a Cheat
# Gold has DIMINISHING value: the first GOLD_WORKING_RESERVE dollars are worth full
# GOLD_WEIGHT (you need a working float on hand to actually use/buy power-ups), but every
# dollar PAST that is a dead-weight hoard worth only GOLD_EXCESS_SCALE as much — money you
# aren't spending isn't winning you the game. This REPLACED the old flat GOLD_HOARD_BONUS,
# which paid the bot a fixed +40 just for SITTING on >= a Cheat's price; combined with the
# even-or-ahead taper of 1.0 that bonus actively rewarded hoarding whenever the bot wasn't
# losing, which is the main reason it never spent. Now the marginal value of the 16th+ dollar
# collapses, so any move/use that banks material or income easily out-scores clutching the pile.
# Tune: raise GOLD_WORKING_RESERVE to let it save a bigger war-chest; lower GOLD_EXCESS_SCALE
# to make excess gold even more worthless (spend harder).
const GOLD_WORKING_RESERVE := 15   # $ worth full value (a Cheat, or a couple of buys in hand)
const GOLD_EXCESS_SCALE    := 0.3  # value multiplier on every $ past the working reserve
# Gold is only worth what you eventually SPEND it on. A side that is losing on material should
# be converting gold into board presence (subs / power-ups), not banking it — a hoard you
# never spend and then get mated with is worth zero. So each side's gold value is tapered down
# the further BEHIND on material that side is: full value when even-or-ahead, scaling toward
# GOLD_LOSING_SCALE once it is GOLD_DESPERATION_MARGIN centipawns (~a minor piece) behind. This
# kills the pathological "clutch $22 while being checkmated" behaviour without touching how the
# bot values gold when it is even or winning (taper = 1.0 there, i.e. identical to before).
# NOTE: material is a function of the hashed board, so scaling gold by it adds no TT-invisible
# state — equal positions still evaluate equally. Tune: lower GOLD_DESPERATION_MARGIN to make
# the bot start liquidating sooner; lower GOLD_LOSING_SCALE to make a losing bot spend harder.
const GOLD_DESPERATION_MARGIN := 300.0   # cp behind before gold value is fully tapered
const GOLD_LOSING_SCALE       := 0.25    # gold value floor for a hopelessly-behind side
const TIE_EPSILON       := 0.5   # root moves within this score count as a true tie
# In the opening, randomize among ALL root moves within this many centipawns of the best —
# not just exact ties. Stops the bot from robotically maxing the piece-square table every
# game (e.g. always shoving both knights out first) by letting near-equal developing moves
# (knights, centre pawns, bishops) trade off. Only applies for the first OPENING_PLIES.
const OPENING_VARIETY_CP := 35.0

# --- POWER-UP VALUE THRESHOLDS (shared) ---
# Only the two thresholds the engine itself needs live here — they gate the opponent's
# in-search power-up branching (_gen_opp_pu_branches). The strategy reads them via
# UberBot.CAPTURE_MIN_VALUE / UberBot.TELEPORT_MIN_VALUE so the bot models the opponent
# with the same bar it uses for its own offensive power-ups. All the strategy-only
# thresholds (Shield/Negate/Multiply/Tap-In/Cheat min values, gold reserve) moved to
# UberbotStrategy.gd alongside the policy that uses them.
const CAPTURE_MIN_VALUE  := 3
const TELEPORT_MIN_VALUE := 3

# --- SEARCH STATE (reset each plan_turn) ---
var _deadline_us := 0
var _timed_out := false
var _killers := {}        # depth -> [moveA, moveB] that caused beta cutoffs (ordering aid)
var _root_color := "White"

# --- STEP 2: OPPONENT POWER-UP AWARENESS ---
# Snapshot of what the opponent can do THIS turn, taken once at the top of plan_turn and
# held fixed for the whole search. Two parts:
#
#   EVAL LAYER (existing): _opp_def_ready / _opp_def_uses feed _shield_awareness() inside
#   _evaluate() so the leaf eval already discounts captures the opponent can Shield away.
#
#   SEARCH LAYER (new Step 2): _opp_pu_slots is a dict of ready power-up names the human
#   has available. _negamax reads it at every MIN node and, when depth >= OPPONENT_PU_MIN_DEPTH,
#   generates a small extra branch per relevant power-up — so the bot sees threats like
#   "if I move here the human Phases through my Knight and takes my Rook" before committing.
#   Branching is behind the depth gate to keep the tree explosion affordable: at shallow
#   plies (horizon, quiescence) the opponent plays pure chess as before.
var _opp_def_ready := false      # opponent has a ready Shield OR Ground slot
var _opp_def_uses := 0           # how many Defense uses the opponent still has this turn (0/1)
# Set of power-up names the opponent has ready this turn (used by _negamax branching).
# Keys are power-up name strings; value is always true (acts as a Set).
# Phase / Capture / Teleport → geometry-extending threats; Ground / Shield → defensive freeze/block.
# Cheat / Multiply / Negate / Super Pawn deliberately excluded — see plan walkthrough.
var _opp_pu_slots := {}          # e.g. {"Phase": true, "Shield": true}
# How much of a shieldable piece's value to treat as "might not be capturable" when the
# opponent has a defensive slot ready. 0.0 = ignore (old behaviour), 1.0 = assume always
# shielded. 0.5 plays naturally: the bot is wary of shieldable captures without becoming
# timid. Tune this first if the bot is too cautious (lower) or still walks into shields (raise).
const SHIELD_THREAT_DISCOUNT := 0.5
# Bonus when the bot threatens 2+ shieldable enemy pieces but the opponent has only one
# defensive use — the shield can save one, the bot collects the other. This is the
# "double-threat beats shield" reward. Scaled by the SMALLER of the two threatened values
# (the piece they'll let go) so it tracks what the bot actually wins.
const DOUBLE_THREAT_WEIGHT := 0.6

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

# =====================================================================
# SCORING SERVICES  (public API driven by UberbotStrategy)
# =====================================================================
# The strategy generates candidate turns and asks the engine to score them. These methods
# are the boundary: best_move() (the plain deep search), score_turn() (apply a candidate
# turn, search the opponent's reply, revert), candidate_depth(), snapshot_opp_caps() (sets
# the engine's opponent-awareness for the upcoming search), and the scoring-budget pair
# below. Everything else in this file is engine-internal (underscored).

# Start a fresh think budget for a round of candidate scoring. The deep search may have
# eaten most of the main budget; without this reset every candidate would insta-time-out.
func begin_scoring_budget() -> void:
	_deadline_us = Time.get_ticks_usec() + MAX_THINK_MS * 1000
	_timed_out = false

# Has the current search/scoring budget been exhausted? Read by the strategy's candidate loop.
func timed_out() -> bool:
	return _timed_out

# Depth used to score power-up candidates. A notch below the main search so the extra
# branching stays affordable, but still scales with difficulty.
func candidate_depth() -> int:
	return clampi(MAX_DEPTH - 2, 2, 6)

# =====================================================================
# POWER-UP TURN SIMULATION (Step 1): apply / score / revert a candidate turn
# =====================================================================

# Applies a candidate turn, evaluates the OPPONENT's best reply with an isolated search
# (fresh TT + re-seeded hash, so power-up/gold state can't pollute the main table or
# collide on the hash), then reverts. Returns the value to `color` (root perspective).
#
# IMPORTANT: _opp_pu_slots is cleared for the duration of this call. The Step 2 opponent
# power-up branching inside _negamax is expensive (extra board scans per node) and only
# meaningful in the full _best_move search. The candidate comparison pass here is shallow
# and time-budgeted; letting Step 2 run inside it causes every candidate to time out
# before it can beat the baseline, which is what makes the bot stop using power-ups at all.
func score_turn(color: String, actions: Array, cdepth: int) -> float:
	var saved_hash = _hash
	var saved_tt = _tt
	var saved_opp_pu_slots = _opp_pu_slots   # Step 2: disable branching during candidate scoring
	_tt = {}
	_opp_pu_slots = {}
	# Slice-4-lite: credit the gold INCOME this turn's captures pay (Multiply-boosted if the
	# mover is Multiplied). Computed on the intact board BEFORE _apply_turn moves anything.
	var income = _turn_income_cp(actions)
	var undo = _apply_turn(actions)
	_hash = _compute_hash(_other(color))
	var s = -_negamax(cdepth - 1, -INF, INF, _other(color), 1)
	_revert_turn(undo)
	_tt = saved_tt
	_hash = saved_hash
	_opp_pu_slots = saved_opp_pu_slots       # restore so _best_move still sees the full slots
	return s + income

# Gold INCOME (centipawn-valued) the bot's OWN actions generate this turn — the capture
# reward the game pays out, which _make does NOT model (it only relocates material). Without
# this the search only ever watched gold go DOWN (tap-in/buy spends), so it had no reason to
# capture-for-gold or to Multiply. Added as a one-shot root bonus in score_turn: no Zobrist
# work, opponent stays income-blind (the GDD's slice-4-lite). A Multiply modifier on the
# mover boosts its reward per the shop's payout rules. Computed on the pre-apply board so the
# captured victims are still present. (EP captures are skipped — rare and only a pawn.)
func _turn_income_cp(actions: Array) -> float:
	var multiplied := {}
	for a in actions:
		if a["kind"] == "modifier" and a.get("item", "") == "Multiply":
			multiplied[a["target"]] = true
	var income := 0.0
	for a in actions:
		if a["kind"] != "move":
			continue
		var to_pos = a["to"]
		if not game.board_state.has(to_pos) or not game.board_state.has(a["from"]):
			continue
		var victim = game.board_state[to_pos]
		if victim["color"] == game.board_state[a["from"]]["color"]:
			continue   # own piece on the target (shouldn't happen) — not income
		if multiplied.has(a["from"]):
			income += _multiply_reward(victim)
		else:
			income += float(_piece_value(victim))
	return GOLD_WEIGHT * income

# Gold paid when the capturer is Multiplied: normal Pawn quadruples to $4, Super Pawn -> $16,
# everything else doubles. Mirrors the economy section's boost formula. Base reward is
# _piece_value (P1 N3 B3 R5 Q9, Super Pawn $8).
func _multiply_reward(pc: Dictionary) -> float:
	if pc.get("is_super_pawn", false):
		return 16.0
	if pc["type"] == "Pawn":
		return 4.0
	return float(_piece_value(pc)) * 2.0

# Applies an internal action list (modifier / super-pawn uses, then a terminal move or
# tap-in) to game state, returning an undo stack reverted by _revert_turn. Only the kinds
# emitted by the strategy's candidate generator appear here. The hash is re-seeded by the caller after
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
			"tapin":
				# A substitution is a two-sided edit: the bench piece lands on `square` and
				# the piece that was there goes to the back of the same bench. The undo
				# entry carries BOTH, because the outgoing piece is appended at the end of
				# the bench rather than at `idx` — reverting has to unpick that.
				var tcolor = a["color"]
				var idx = a["bench_index"]
				var square = a["square"]
				var entry = game.bench[tcolor][idx]
				var ptype = entry["type"]
				var outgoing = game.board_state[square]
				var cost = game.tapin_cost(ptype, outgoing["type"])
				undo.push_back({"kind": "tapin", "color": tcolor, "idx": idx, "square": square,
					"entry": entry, "outgoing": outgoing, "cost": cost,
					"prev_ep": game.en_passant_target})
				game.board_state[square] = {"type": ptype, "color": tcolor, "modifier": "",
					"modifier_duration": 0, "is_super_pawn": entry.get("is_super_pawn", false),
					"has_moved": true}
				game.player_gold[tcolor] -= cost
				game.subs_left[tcolor] -= 1
				game.bench[tcolor].remove_at(idx)
				game.bench[tcolor].append({"type": outgoing["type"],
					"is_super_pawn": outgoing.get("is_super_pawn", false)})
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
			"tapin":
				# Unwind in the mirror order: drop the appended outgoing entry off the end
				# of the bench FIRST, then reinsert the incoming one at its old index, so
				# every later bench index lines up exactly as it did before the swap.
				var b: Array = game.bench[u["color"]]
				b.remove_at(b.size() - 1)
				b.insert(u["idx"], u["entry"])
				game.board_state[u["square"]] = u["outgoing"]
				game.player_gold[u["color"]] += u["cost"]
				game.subs_left[u["color"]] += 1
				game.en_passant_target = u["prev_ep"]

# =====================================================================
# SEARCH: iterative deepening + alpha-beta + quiescence (make/unmake)
# =====================================================================

func best_move(color: String):
	_root_color = color
	_deadline_us = Time.get_ticks_usec() + MAX_THINK_MS * 1000
	_timed_out = false
	_killers.clear()
	_tt.clear()
	_hash = _compute_hash(color)

	var root_moves = _ordered_moves(color, 0)
	if root_moves.is_empty():
		return null

	# TIMING DIAGNOSTIC: how long does _ordered_moves alone take at the root?
	var t_movegen = Time.get_ticks_usec()
	_ordered_moves(color, 0)
	var t_movegen_ms = (Time.get_ticks_usec() - t_movegen) / 1000.0
	print("🔬 root move gen: ", root_moves.size(), " moves in ", int(t_movegen_ms), "ms")

	var best_move = root_moves[0]
	var best_scored := []        # {move, score} for every root move at the last completed depth
	var best_top := -INF         # the true best score at that depth (uses TIE_EPSILON, stays exact)

	# Iterative deepening: depth 1, 2, 3 ... until the clock runs out. Each completed
	# depth refines best_move; a depth aborted mid-way is discarded (partial), so we
	# always return the best fully-searched result.
	var depth := 1
	var completed_depth := 0   # DIAGNOSTIC: deepest depth fully searched within the budget
	while depth <= MAX_DEPTH:
		var d_best_score := -INF
		var d_best_move = root_moves[0]
		var d_scored := []
		var aborted := false
		var t_depth_start = Time.get_ticks_usec()

		# Search the previous iteration's best move first — huge ordering win for the TT.
		_prioritize(root_moves, best_move)

		for m in root_moves:
			var undo = _make(m)
			var score = -_negamax(depth - 1, -INF, INF, _other(color), 1)
			_unmake(undo)
			if _timed_out:
				aborted = true
				break
			d_scored.append({"move": m, "score": score})
			if score > d_best_score + TIE_EPSILON:
				d_best_score = score
				d_best_move = m

		var t_depth_ms = (Time.get_ticks_usec() - t_depth_start) / 1000.0
		if not aborted:
			best_move = d_best_move
			best_scored = d_scored
			best_top = d_best_score
			completed_depth = depth
			print("🔬 depth ", depth, " completed in ", int(t_depth_ms), "ms, score ", d_best_score)
		else:
			print("🔬 depth ", depth, " ABORTED after ", int(t_depth_ms), "ms")
		if _timed_out:
			break
		depth += 1

	# DIAGNOSTIC: report the deepest depth actually completed and the elapsed time. If this
	# prints a number well below MAX_DEPTH on Über, the bot is timing out before it can see
	# far enough — that's a budget/speed problem, not a logic bug. Remove once diagnosed.
	var elapsed_ms := (Time.get_ticks_usec() - (_deadline_us - MAX_THINK_MS * 1000)) / 1000.0
	print("🤖 search: completed depth ", completed_depth, " / ", MAX_DEPTH, "  (", int(elapsed_ms), "ms, score ", best_top, ")")

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

func _negamax(depth: int, alpha: float, beta: float, color: String, ply: int) -> float:
	if _check_time():
		return 0.0

	# KING GONE = TERMINAL LOSS. If `color` has no King, its King was captured by the move
	# that led into this node — `color` has already lost. Score it by distance from the root
	# (sooner loss = worse), the same convention the mate branch below uses, so the capturing
	# side strictly prefers the quickest kill. This is what makes king-capture a real win/loss
	# inside the search, and it stops us ever evaluating a kingless position (which would
	# scramble _evaluate / _find_king). Parity with game.gd's instant king-capture win.
	if _find_king(color) == Vector2(-1, -1):
		return -(MATE_SCORE - ply)

	if depth <= 0:
		return _quiescence(alpha, beta, color, 0)

	# --- Transposition table probe ---
	var alpha_orig := alpha
	var tt_move = null
	if _tt.has(_hash):
		var e = _tt[_hash]
		# Mate scores are relative to ply-from-root, so the SAME position reached at a
		# different ply would carry a wrong mate distance. Only trust a stored entry for an
		# early cutoff when its score is NOT in mate range; otherwise fall through and just
		# use its move for ordering. (Non-mate scores are position-absolute and safe to reuse.)
		var is_mate_score := absf(e["score"]) >= MATE_SCORE - 1000.0
		if e["depth"] >= depth and not is_mate_score:
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
		if _king_attacked(color):
			# Mate. Score it by DISTANCE FROM THE ROOT (ply), not remaining search depth, so a
			# mate found closer to the root always beats a slower one. -(MATE_SCORE - ply):
			# being mated is bad (negative), and a mate that lands sooner (smaller ply)
			# subtracts less, leaving a MORE extreme negative — so after negation the mating
			# side strictly prefers the quickest mate. This is the fix for "the bot saw a mate
			# but took the slow road."
			return -(MATE_SCORE - ply)
		return 0.0                       # stalemate

	# Search the TT's remembered best move first — usually the strongest reply here.
	if tt_move != null:
		_prioritize(moves, tt_move)

	var best := -INF
	var best_move = null
	for m in moves:
		var undo = _make(m)
		var score = -_negamax(depth - 1, -beta, -alpha, _other(color), ply + 1)
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

	# STEP 2: opponent power-up branching.
	# At MIN nodes (human's turn), if the opponent has relevant power-ups ready and we're
	# deep enough to reason about them, generate a small set of extra child positions that
	# model the human using one power-up before their move. We min over these alongside the
	# pure-chess moves above — so the bot won't walk into a Phase threat it couldn't see.
	#
	# TT note: we deliberately skip the TT for power-up branches (no tt_move lookup, no
	# store at the end of this block). The Zobrist hash doesn't encode slot/modifier state
	# changes from an opponent's in-search power-up use, so a cached result from a node
	# without the buff applied could collide with one that has it. Skipping the TT here is
	# safe: these branches are few and shallow, so the overhead is negligible. Full hash
	# coverage of power-up state is a Step 3 concern (noted in the GDD).
	if depth >= OPPONENT_PU_MIN_DEPTH and not _opp_pu_slots.is_empty() and not _timed_out:
		var pu_branches = _gen_opp_pu_branches(color)
		for branch in pu_branches:
			if _timed_out:
				break
			var pu_undo = _apply_opp_pu(branch)
			# Re-generate moves in the modified position. For Phase/Capture the modifier
			# unlocks new geometry; for Teleport the piece is on a new square; for
			# Shield/Ground the piece is now invulnerable / frozen. In all cases the
			# move list can differ from `moves`, so we re-generate rather than reuse.
			var pu_moves = _ordered_moves(color, depth)
			for m in pu_moves:
				if _timed_out:
					break
				var undo = _make(m)
				var score = -_negamax(depth - 1, -beta, -alpha, _other(color), ply + 1)
				_unmake(undo)
				if _timed_out:
					break
				# MIN node: the opponent will choose whichever (move + optional power-up)
				# combination hurts the bot most, so we track the LOWEST score seen.
				# In negamax framing this is the score that maximises the opponent's
				# perspective, which minimises ours — hence we update `best` if score < best
				# (negamax negates before returning, so a lower `best` here = better for opp).
				if score < best:
					best = score
					best_move = m
				# NOTE: no alpha/beta update inside the power-up branches — the outer loop
				# already set alpha from the pure-chess pass. The power-up branches can only
				# lower `best` further (they find WORSE positions for the bot). If best already
				# dropped below alpha_orig the TT store below will flag it as UPPER bound
				# correctly. We do break on beta for the outer alpha (can't be cut differently).
				if best <= -beta:
					break
			_revert_opp_pu(pu_undo)

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
	# KING GONE = TERMINAL LOSS (see _negamax). Quiescence has no ply counter, so score it
	# flat — the exact mate distance doesn't matter at the quiescence horizon, only that a
	# captured King is a decisive loss for the side to move.
	if _find_king(color) == Vector2(-1, -1):
		return -MATE_SCORE
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

# --- FAST KING-SAFETY ---
# The original approach called game.get_legal_moves for every enemy piece inside every
# _safe_moves call — O(own_moves × enemy_pieces) game.get_legal_moves calls per node.
# At depth 1 that's ~5000 calls just for move generation, which is why the bot stalls at
# depth 1 even with a 3-second budget.
#
# New approach: _build_attack_set() calls game.get_legal_moves ONCE per enemy piece and
# returns a Dictionary of all attacked squares (O(1) lookup). _ordered_moves builds the
# set once at the start of the node, then _safe_moves_fast uses it for every legality
# test. Per-node cost drops from O(own_moves × enemy_pieces) to O(enemy_pieces + own_moves).
# _king_attacked is kept for the castling transit check and for places outside move gen.

# -----------------------------------------------------------------------
# NATIVE KING-SAFETY  (zero calls to game.get_legal_moves inside search)
# -----------------------------------------------------------------------
# _build_attack_set was calling game.get_legal_moves for every enemy piece
# on every node, which costs 10-50ms per node and caps search at depth 1-2.
#
# Replacement: _king_attacked_fast() checks whether the king on `king_pos`
# is attacked by any enemy piece using raw geometry computed directly here.
# Rules match game.gd's checking_threats=true path exactly:
#   - Phase / Teleport modifiers ignored (normal geometry only)
#   - Shield / Ground invulnerability ignored (threat scans ignore it)
#   - Super Pawn geometry included
#   - En passant NOT checked (can't give check via EP in standard chess)
# No Dictionary allocation, no external calls. O(board_size) pure arithmetic.

# The eight slider directions (rook + bishop combined for Queen).
const _ROOK_DIRS   = [Vector2(1,0), Vector2(-1,0), Vector2(0,1), Vector2(0,-1)]
const _BISHOP_DIRS = [Vector2(1,1), Vector2(1,-1), Vector2(-1,1), Vector2(-1,-1)]
const _ALL_DIRS    = [Vector2(1,0), Vector2(-1,0), Vector2(0,1), Vector2(0,-1),
					  Vector2(1,1), Vector2(1,-1), Vector2(-1,1), Vector2(-1,-1)]
const _KNIGHT_JUMPS = [Vector2(1,-2), Vector2(2,-1), Vector2(2,1), Vector2(1,2),
					  Vector2(-1,2), Vector2(-2,1), Vector2(-2,-1), Vector2(-1,-2)]

func _king_attacked_fast(king_pos: Vector2, enemy: String) -> bool:
	var bs = game.board_state

	# --- Sliders: Rook / Queen on ranks+files, Bishop / Queen on diagonals ---
	for d in _ALL_DIRS:
		var sq = king_pos + d
		var is_diag = (d.x != 0 and d.y != 0)
		while sq.x >= 0 and sq.x <= 7 and sq.y >= 0 and sq.y <= 7:
			if bs.has(sq):
				var pc = bs[sq]
				if pc.get("color", "") == enemy:
					var t = pc.get("type", "")
					if t == "Queen":
						return true
					if not is_diag and t == "Rook":
						return true
					if is_diag and t == "Bishop":
						return true
				break   # friendly piece blocks the ray
			sq += d

	# --- Knights ---
	for d in [Vector2(2,1),Vector2(2,-1),Vector2(-2,1),Vector2(-2,-1),
			  Vector2(1,2),Vector2(1,-2),Vector2(-1,2),Vector2(-1,-2)]:
		var sq = king_pos + d
		if sq.x >= 0 and sq.x <= 7 and sq.y >= 0 and sq.y <= 7 and bs.has(sq):
			var pc = bs[sq]
			if pc.get("color", "") == enemy and pc.get("type", "") == "Knight":
				return true

	# --- Pawns (normal and Super Pawn) ---
	# Enemy pawn attacks differ by color: White pawns attack upward (y-1 from king),
	# Black pawns attack downward (y+1 from king). Super Pawns also attack backward,
	# so a Super Pawn can attack from EITHER diagonal relative to the king.
	var pawn_forward_dy = -1 if enemy == "White" else 1   # direction enemy pawns move
	for dx in [1, -1]:
		# Standard forward-diagonal pawn threat
		var sq = king_pos + Vector2(dx, pawn_forward_dy)
		if sq.x >= 0 and sq.x <= 7 and sq.y >= 0 and sq.y <= 7 and bs.has(sq):
			var pc = bs[sq]
			if pc.get("color", "") == enemy and (pc.get("type", "") == "Pawn" or pc.get("is_super_pawn", false)):
				return true
		# Super Pawn backward-diagonal threat (attacks in BOTH diagonal directions)
		var sq2 = king_pos + Vector2(dx, -pawn_forward_dy)
		if sq2.x >= 0 and sq2.x <= 7 and sq2.y >= 0 and sq2.y <= 7 and bs.has(sq2):
			var pc2 = bs[sq2]
			if pc2.get("color", "") == enemy and pc2.get("is_super_pawn", false):
				return true

	# --- Enemy King (adjacent squares) ---
	for d in _ALL_DIRS:
		var sq = king_pos + d
		if sq.x >= 0 and sq.x <= 7 and sq.y >= 0 and sq.y <= 7 and bs.has(sq):
			var pc = bs[sq]
			if pc.get("color", "") == enemy and pc.get("type", "") == "King":
				return true

	return false

# Find the king position for `color` in board_state. Returns Vector2(-1,-1) if not found.
func _find_king(color: String) -> Vector2:
	for pos in game.board_state:
		var pc = game.board_state[pos]
		if pc.get("type", "") == "King" and pc.get("color", "") == color:
			return pos
	return Vector2(-1, -1)

# SLICE 3 KEYSTONE — a king carrying a Shield or Ground modifier cannot be captured. The
# search consults this wherever it would generate a king capture, so a "Shield/Ground my
# king" defense scores as SAFE (~material) instead of the -MATE it scores undefended — which
# is exactly what lets the bot CHOOSE to defend rather than walk into a power-up king-capture.
# DORMANT until the rest of Slice 3 lands (strategy king-defense candidates + the game.gd rule
# that lets defensive power-ups target the king): no king carries these modifiers in normal
# play today, so this is a no-op and regression-free. Mirror this rule in game.gd's capture
# resolution so vs-Bot can't desync (a protected king the engine thinks is safe must really
# be uncapturable in execute_move).
func _king_protected(king_pc: Dictionary) -> bool:
	var m = king_pc.get("modifier", "")
	return m == "Shield" or m == "Ground"

# ============================================================================
# NATIVE MOVE GENERATOR — replaces game.get_legal_moves in the per-node hot path.
# ----------------------------------------------------------------------------
# Reads game.board_state directly and reproduces game.get_legal_moves(pos, false)
# EXACTLY: same geometry and the same Teleport / Phase / Capture / Shield /
# Super Pawn / castling / en-passant / invulnerability handling. The search used
# to call game.get_legal_moves once per piece per node; that cross-object call
# (with its own array allocations) is what capped the bot at ~2 ply. This is the
# same move _king_attacked_fast made for the safety test, now applied to
# generation itself.
#
# PARITY IS NON-NEGOTIABLE. This was fuzz-verified against a faithful port of
# game.gd across ~3.9M piece-positions (every modifier, super pawns, en passant,
# cheat-protection, castling) with zero divergences. If you ever change a
# movement rule in game.gd, mirror it here or the search will explore moves the
# real game rejects (or miss legal ones) and desync vs-Bot.
# ============================================================================

func _native_invuln(sq: Vector2) -> bool:
	if sq == game.cheat_protected_square:
		return true
	var bs = game.board_state
	if bs.has(sq):
		var m = bs[sq].get("modifier", "")
		return m == "Ground" or m == "Shield"
	return false

func _native_valid_dest(target: Vector2, my_color: String) -> bool:
	if target.x < 0 or target.x > 7 or target.y < 0 or target.y > 7:
		return false
	var bs = game.board_state
	if bs.has(target):
		if bs[target]["color"] == my_color:
			return false
		if _native_invuln(target):
			return false
	return true

# Mirror of game.get_sliding_moves: walk each direction until edge / friend / enemy.
# Phase tunnels through exactly ONE blocker per direction; can't land on a friendly
# and can't capture an invulnerable.
func _native_slide(out: Array, start_pos: Vector2, my_color: String, dirs: Array, phase: bool) -> void:
	var bs = game.board_state
	for dir in dirs:
		var cur = start_pos + dir
		var phased = 0
		while cur.x >= 0 and cur.x <= 7 and cur.y >= 0 and cur.y <= 7:
			if not bs.has(cur):
				out.append(cur)
			else:
				if bs[cur]["color"] != my_color and not _native_invuln(cur):
					out.append(cur)
				if phase and phased < 1:
					phased += 1
				else:
					break
			cur += dir

# Exact "is the king's square attacked?" test used ONLY for the castling guard, so
# native castling matches game.get_legal_moves (which gates castling on game.is_in_check).
# This is NOT _king_attacked_fast: that one approximates super-pawn threats (counts the
# backward diagonal, misses straight captures) and ignores the Capture buff, which would
# make castling generation diverge from the real game. This mirrors game's threat geometry
# exactly: an invulnerable king square is never a legal capture target, so it is never "in
# check"; super pawns threaten forward diagonals + straight (fwd/back) only; a Capture-buffed
# piece adds king-style adjacency EXCEPT super pawns (they early-return past the Capture block).
func _attacked_for_castle(kp: Vector2, enemy: String) -> bool:
	var bs = game.board_state
	if _native_invuln(kp):
		return false
	# Sliders
	for d in _ALL_DIRS:
		var sq = kp + d
		var is_diag = (d.x != 0 and d.y != 0)
		while sq.x >= 0 and sq.x <= 7 and sq.y >= 0 and sq.y <= 7:
			if bs.has(sq):
				var pc = bs[sq]
				if pc.get("color", "") == enemy:
					var t = pc.get("type", "")
					if t == "Queen":
						return true
					if not is_diag and t == "Rook":
						return true
					if is_diag and t == "Bishop":
						return true
				break
			sq += d
	# Knights
	for d in _KNIGHT_JUMPS:
		var sq = kp + d
		if sq.x >= 0 and sq.x <= 7 and sq.y >= 0 and sq.y <= 7 and bs.has(sq):
			var pc = bs[sq]
			if pc.get("color", "") == enemy and pc.get("type", "") == "Knight":
				return true
	# Pawns: dd is the enemy's forward direction.
	var dd = -1 if enemy == "White" else 1
	for off in [Vector2(-1, dd), Vector2(1, dd)]:           # forward diagonals: any pawn
		var sq = kp - off
		if sq.x >= 0 and sq.x <= 7 and sq.y >= 0 and sq.y <= 7 and bs.has(sq):
			var pc = bs[sq]
			if pc.get("color", "") == enemy and pc.get("type", "") == "Pawn":
				return true
	for off in [Vector2(0, dd), Vector2(0, -dd)]:           # straight fwd/back: super pawn only
		var sq = kp - off
		if sq.x >= 0 and sq.x <= 7 and sq.y >= 0 and sq.y <= 7 and bs.has(sq):
			var pc = bs[sq]
			if pc.get("color", "") == enemy and pc.get("is_super_pawn", false):
				return true
	# Enemy king adjacency
	for d in _ALL_DIRS:
		var sq = kp + d
		if sq.x >= 0 and sq.x <= 7 and sq.y >= 0 and sq.y <= 7 and bs.has(sq):
			var pc = bs[sq]
			if pc.get("color", "") == enemy and pc.get("type", "") == "King":
				return true
	# Capture-buff king-style adjacency — NOT super pawns (they early-return past the Capture block)
	for d in _ALL_DIRS:
		var sq = kp + d
		if sq.x >= 0 and sq.x <= 7 and sq.y >= 0 and sq.y <= 7 and bs.has(sq):
			var pc = bs[sq]
			if pc.get("color", "") == enemy and pc.get("modifier", "") == "Capture" and not pc.get("is_super_pawn", false):
				return true
	return false

# Native equivalent of game.get_legal_moves(pos, false) — the raw geometric+modifier
# move list (NOT yet king-safety filtered; the caller does that via make + _king_attacked_fast,
# exactly as it did with the game.gd list).
func _native_legal_moves(pos: Vector2) -> Array:
	var bs = game.board_state
	if not bs.has(pos):
		return []
	var piece = bs[pos]
	if not piece.has("color") or not piece.has("type"):
		return []
	var color = piece["color"]
	var modifier = piece.get("modifier", "")
	var moves := []

	# TELEPORT: any empty square on the board (checked before geometry, like game.gd).
	if modifier == "Teleport":
		for x in range(8):
			for y in range(8):
				var sq = Vector2(x, y)
				if not bs.has(sq):
					moves.append(sq)
		return moves

	var phasing = modifier == "Phase"
	var ptype = piece["type"]

	match ptype:
		"Knight":
			for j in _KNIGHT_JUMPS:
				var tg = pos + j
				if _native_valid_dest(tg, color):
					moves.append(tg)

		"Pawn":
			if piece.get("is_super_pawn", false):
				var sdir = -1 if color == "White" else 1
				# Straight forward/backward — move or capture.
				for d in [Vector2(0, sdir), Vector2(0, -sdir)]:
					var sq = pos + d
					if sq.y < 0 or sq.y > 7:
						continue
					if not bs.has(sq):
						moves.append(sq)
					elif bs[sq]["color"] != color and not _native_invuln(sq):
						moves.append(sq)
				# First-move double push (forward only).
				if not piece.get("has_moved", false):
					var one = pos + Vector2(0, sdir)
					var two = pos + Vector2(0, sdir * 2)
					if two.y >= 0 and two.y <= 7 and not bs.has(one) and not bs.has(two):
						moves.append(two)
				# Forward diagonals — capture only.
				for d in [Vector2(-1, sdir), Vector2(1, sdir)]:
					var sq = pos + d
					if sq.x < 0 or sq.x > 7 or sq.y < 0 or sq.y > 7:
						continue
					if bs.has(sq) and bs[sq]["color"] != color and not _native_invuln(sq):
						moves.append(sq)
				# En passant — forward diagonals.
				if game.en_passant_target != Vector2(-1, -1):
					for d in [Vector2(-1, sdir), Vector2(1, sdir)]:
						if pos + d == game.en_passant_target:
							moves.append(game.en_passant_target)
				return moves   # super pawn early-returns past Capture/Shield post-processing

			var direction = -1 if color == "White" else 1
			var start_row = 6 if color == "White" else 1
			var forward = pos + Vector2(0, direction)
			if _native_valid_dest(forward, color) and not bs.has(forward):
				moves.append(forward)
				if int(pos.y) == start_row:
					var dbl = pos + Vector2(0, direction * 2)
					if _native_valid_dest(dbl, color) and not bs.has(dbl) and not bs.has(forward):
						moves.append(dbl)
			for cap_dir in [Vector2(-1, direction), Vector2(1, direction)]:
				var tg = pos + cap_dir
				if _native_valid_dest(tg, color):
					if bs.has(tg) and bs[tg]["color"] != color:
						moves.append(tg)
					elif tg == game.en_passant_target:
						moves.append(tg)

		"Rook":
			_native_slide(moves, pos, color, [Vector2(0,1), Vector2(0,-1), Vector2(1,0), Vector2(-1,0)], phasing)
		"Bishop":
			_native_slide(moves, pos, color, [Vector2(1,1), Vector2(1,-1), Vector2(-1,1), Vector2(-1,-1)], phasing)
		"Queen":
			_native_slide(moves, pos, color, _ALL_DIRS, phasing)

		"King":
			for km in _ALL_DIRS:
				var tg = pos + km
				if _native_valid_dest(tg, color):
					moves.append(tg)
			# Castling (real move only). Mirrors game.gd: unmoved king, not in check, unmoved
			# rook on the back rank, empty squares between. Uses the exact castling-attack test.
			if not piece.get("has_moved", false) and not _attacked_for_castle(pos, _other(color)):
				var yr = pos.y
				var rr = Vector2(7, yr)
				if bs.has(rr) and bs[rr].get("type") == "Rook" and not bs[rr].get("has_moved", false):
					if not bs.has(Vector2(5, yr)) and not bs.has(Vector2(6, yr)):
						moves.append(Vector2(6, yr))
				var lr = Vector2(0, yr)
				if bs.has(lr) and bs[lr].get("type") == "Rook" and not bs[lr].get("has_moved", false):
					if not bs.has(Vector2(1, yr)) and not bs.has(Vector2(2, yr)) and not bs.has(Vector2(3, yr)):
						moves.append(Vector2(2, yr))

	# CAPTURE buff: king-style one-square moves on top (skip dups). Super pawns never reach
	# here (they returned above), matching game.gd.
	if modifier == "Capture":
		for d in _ALL_DIRS:
			var tg = pos + d
			if _native_valid_dest(tg, color) and not moves.has(tg):
				moves.append(tg)

	# SHIELD: strip all captures (real move only).
	if modifier == "Shield":
		var nc := []
		for m in moves:
			if bs.has(m) and bs[m]["color"] != color:
				continue
			if ptype == "Pawn" and m == game.en_passant_target:
				continue
			nc.append(m)
		moves = nc

	return moves

# Legacy wrappers — keep these so callers outside move generation still work.
# These still call game.get_legal_moves but are only hit for castling transit
# and mate/stalemate detection (rare, not per-move-candidate).
func _build_attack_set(attacker_color: String) -> Dictionary:
	var attacked := {}
	var bs = game.board_state
	for pos in bs:
		var pc = bs[pos]
		if pc.get("color", "") != attacker_color:
			continue
		for sq in game.get_legal_moves(pos, true):
			attacked[sq] = true
	return attacked

func _king_in_attack_set(color: String, attack_set: Dictionary) -> bool:
	var bs = game.board_state
	for pos in bs:
		var pc = bs[pos]
		if pc.get("type", "") == "King" and pc.get("color", "") == color:
			return attack_set.has(pos)
	return false

# Is `color`'s king currently attacked? Used for check detection outside move generation
# (mate/stalemate test after _negamax returns empty moves). Now uses native geometry.
func _king_attacked(color: String) -> bool:
	var king_pos = _find_king(color)
	if king_pos == Vector2(-1, -1):
		return false
	return _king_attacked_fast(king_pos, _other(color))

# King-safe moves for `pos`. After each _make, checks king safety using native geometry —
# zero calls to game.get_legal_moves for the safety test. This is the hot path.
func _safe_moves_fast(pos: Vector2, _unused) -> Array:
	var bs = game.board_state
	if not bs.has(pos):
		return []
	var piece = bs[pos]
	var my_color = piece.get("color", "")
	var enemy = _other(my_color)
	var out := []

	for target in _native_legal_moves(pos):
		# CAPTURING THE ENEMY KING WINS OUTRIGHT — always generated, never filtered by our
		# own king-safety (whoever takes a King first wins, even while in check). The actual
		# win/loss is scored at the kingless-node check in _negamax/_quiescence. Mirrors
		# game.gd, where landing on a King ends the match immediately.
		if bs.has(target) and bs[target].get("type", "") == "King":
			if bs[target].get("color", "") != my_color and not _king_protected(bs[target]):
				out.append(target)
			continue

		# Castling transit: king must not pass through an attacked square.
		if piece.get("type", "") == "King" and absf(target.x - pos.x) == 2:
			var step = signf(target.x - pos.x)
			var transit = pos + Vector2(step, 0)
			bs.erase(pos)
			bs[transit] = piece
			var transit_attacked = _king_attacked_fast(transit, enemy)
			bs.erase(transit)
			bs[pos] = piece
			if transit_attacked:
				continue

		# King-safety: make the move, check with native geometry, unmake.
		var undo = _make({"from": pos, "to": target})
		var king_pos = _find_king(my_color)
		var safe = king_pos != Vector2(-1, -1) and not _king_attacked_fast(king_pos, enemy)
		_unmake(undo)
		if safe:
			out.append(target)

	return out

# Legacy _safe_moves kept for callers outside move generation (policy safety checks etc.)
func _safe_moves(pos: Vector2) -> Array:
	var bs = game.board_state
	if not bs.has(pos):
		return []
	var piece = bs[pos]
	var my_color = piece.get("color", "")
	var out := []
	for target in _native_legal_moves(pos):
		# King capture wins outright — generate it, don't filter (parity with _safe_moves_fast).
		if bs.has(target) and bs[target].get("type", "") == "King":
			if bs[target].get("color", "") != my_color and not _king_protected(bs[target]):
				out.append(target)
			continue
		if piece.get("type", "") == "King" and absf(target.x - pos.x) == 2:
			var step = signf(target.x - pos.x)
			var transit = pos + Vector2(step, 0)
			bs.erase(pos)
			bs[transit] = piece
			var transit_attacked = _king_attacked(my_color)
			bs.erase(transit)
			bs[pos] = piece
			if transit_attacked:
				continue
		var undo = _make({"from": pos, "to": target})
		var safe = not _king_attacked(my_color)
		_unmake(undo)
		if safe:
			out.append(target)
	return out

# All legal (king-safe) moves for `color`, ordered for good alpha-beta pruning:
# winning captures (MVV-LVA) first, then killer moves, then quiet moves.
# Builds the enemy attack set ONCE at the start, then uses _safe_moves_fast for each piece
# so game.get_legal_moves is called O(pieces) times instead of O(pieces × moves).
func _ordered_moves(color: String, depth: int) -> Array:
	var caps := []
	var quiet := []
	var enemy = _other(color)
	# Build the pre-move enemy attack set once for this node.
	# _safe_moves_fast rebuilds it after each _make (post-move position), but the
	# pre-move set is used only for the castling transit check inside _safe_moves_fast.
	for pos in game.board_state.keys():
		var pc = game.board_state[pos]
		if pc["color"] != color:
			continue
		if pc.get("modifier", "") == "Ground":
			continue   # grounded pieces can't move this turn
		for dest in _safe_moves_fast(pos, {}):
			var mv = {"from": pos, "to": dest}
			if game.board_state.has(dest):
				if game.board_state[dest].get("type", "") == "King":
					mv["order"] = 1_000_000_000   # winning capture — search it first
				else:
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
		for dest in _safe_moves_fast(pos, {}):
			if game.board_state.has(dest):
				var ord := 1_000_000_000 if game.board_state[dest].get("type", "") == "King" \
					else _raw_value(game.board_state[dest]) * 10 - _raw_value(pc)
				caps.append({"from": pos, "to": dest, "order": ord})
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
	var my_mat := 0.0    # raw material per side (drives the material-aware gold taper below)
	var opp_mat := 0.0

	for pos in game.board_state.keys():
		var pc = game.board_state[pos]
		var sgn := 1.0 if pc["color"] == color else -1.0
		var v := float(_eval_value(pc))
		if pc["color"] == color:
			my_mat += v
		else:
			opp_mat += v

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

	# Economy: gold lead matters, and sitting on a Cheat's worth of gold is a real plan —
	# BUT only to the extent you'll get to spend it. Taper each side's gold value by how far
	# behind on material that side is (see GOLD_DESPERATION_MARGIN / GOLD_LOSING_SCALE), so a
	# losing side stops valuing an un-spendable hoard and the search prefers cashing it into
	# subs / power-ups. Even-or-ahead: scale = 1.0, identical to the old behaviour.
	var my_gold = game.player_gold[color]
	var opp_gold = game.player_gold[enemy]
	var my_scale = lerpf(1.0, GOLD_LOSING_SCALE, clampf((opp_mat - my_mat) / GOLD_DESPERATION_MARGIN, 0.0, 1.0))
	var opp_scale = lerpf(1.0, GOLD_LOSING_SCALE, clampf((my_mat - opp_mat) / GOLD_DESPERATION_MARGIN, 0.0, 1.0))
	score += _gold_value(my_gold, my_scale) - _gold_value(opp_gold, opp_scale)

	# STEP 2: opponent defensive-power-up awareness. Only runs when the opponent actually
	# has a Shield/Ground ready — otherwise this is skipped and the bot evaluates exactly as
	# before. Discounts a capture the opponent would likely shield away, and rewards
	# threatening more shieldable pieces than one defensive use can cover.
	if _opp_def_ready:
		score += _shield_awareness(color)

	return score

# Diminishing centipawn value of a gold pile. The first GOLD_WORKING_RESERVE dollars are
# worth full GOLD_WEIGHT (you need cash on hand to use/buy power-ups); every dollar past the
# reserve is a dead-weight hoard valued at GOLD_EXCESS_SCALE. `mat_scale` is the existing
# material-aware taper (a losing side's gold is worth less still). Symmetric for both sides.
func _gold_value(gold: int, mat_scale: float) -> float:
	var working := float(mini(gold, GOLD_WORKING_RESERVE))
	var excess := float(maxi(0, gold - GOLD_WORKING_RESERVE))
	return GOLD_WEIGHT * mat_scale * (working + GOLD_EXCESS_SCALE * excess)

# Looks at every enemy piece the side-to-move (`color`) is currently attacking that the
# opponent could legally Shield/Ground. The opponent will spend their one defensive use on
# the most valuable such piece, so:
#   - DISCOUNT that piece: the bot shouldn't bank its full value as won material.
#   - REWARD the next one(s): a second shieldable threat is material the single shield
#     can't save (the "double-threat beats shield" idea), tracked by the smaller value.
# Returns a signed adjustment from `color`'s perspective. O(attacked pieces) — cheap.
func _shield_awareness(color: String) -> float:
	var enemy = _other(color)
	var threatened := []
	for p in game.board_state.keys():
		var pc = game.board_state[p]
		if pc["color"] != enemy or not _is_shieldable(pc):
			continue
		if _is_attacked(p, color):
			threatened.append(float(_eval_value(pc)))
	if threatened.is_empty():
		return 0.0
	threatened.sort()
	threatened.reverse()   # highest first

	var adj := 0.0
	# The opponent shields their most valuable threatened piece: discount it.
	adj -= SHIELD_THREAT_DISCOUNT * threatened[0]
	# Any further threatened shieldable pieces are beyond their defensive coverage. Reward
	# the bot for the extra threat (use the second piece's value — what it actually collects).
	if threatened.size() > _opp_def_uses:
		adj += DOUBLE_THREAT_WEIGHT * threatened[_opp_def_uses]
	return adj

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

# STEP 2: record what the opponent can do defensively this turn. Called once per plan_turn.
# The opponent's Defense class is free at the start of the bot's turn (their used-classes
# tracker is for THEIR turns), so a single ready Shield/Ground = one defensive use available.
# Also builds _opp_pu_slots for the _negamax branching layer — the full set of power-ups
# the opponent has ready that can extend geometry or create new threats inside the search.
func snapshot_opp_caps(color: String) -> void:
	var enemy = _other(color)
	_opp_def_ready = _ready_has(enemy, "Shield") or _ready_has(enemy, "Ground")
	_opp_def_uses = 1 if _opp_def_ready else 0
	# Build the search-branching slot set. Only power-ups whose in-search effect is
	# modelable with the existing make/unmake + modifier system are included here.
	# Cheat, Multiply, Negate, Super Pawn remain excluded — see plan notes in Section 6.
	_opp_pu_slots = {}
	for pu in ["Phase", "Capture", "Teleport", "Shield", "Ground"]:
		if _ready_has(enemy, pu):
			_opp_pu_slots[pu] = true

# STEP 2 — SEARCH BRANCHING HELPERS
# ---------------------------------------------------------------------------
# Called from _negamax at every MIN node (human's turn) when:
#   a) depth >= OPPONENT_PU_MIN_DEPTH, AND
#   b) _opp_pu_slots is non-empty (opponent has at least one relevant power-up ready).
#
# Returns a list of {pu, target} dicts — at most ONE candidate per power-up type, chosen
# by the same targeting heuristics the bot uses for its own power-ups. The caller applies
# each candidate, generates the resulting legal moves, recurses, and reverts, then takes
# the MIN across the pure-chess branch and all power-up branches.
#
# Fan-out budget: ≤ 5 extra children per MIN node (one per power-up type), each
# constrained to the single best target for that type, so the tree stays manageable.
func _gen_opp_pu_branches(opp_color: String) -> Array:
	var bot_color = _other(opp_color)
	var branches := []

	# --- PHASE / CAPTURE: does the power-up give the human access to a bot piece they
	# can't reach with normal geometry? Only branch if the gain clears a worthwhile bar
	# (same CAPTURE_MIN_VALUE threshold the bot uses for its own offensive candidates).
	for pu in ["Phase", "Capture"]:
		if not _opp_pu_slots.has(pu):
			continue
		var best_target = null
		var best_val := float(CAPTURE_MIN_VALUE - 1)
		for p in game.board_state.keys():
			var pc = game.board_state[p]
			if pc["color"] != opp_color or pc["type"] == "King":
				continue
			if pc.get("is_super_pawn", false) or pc.get("modifier", "") != "":
				continue
			var plain_dests = _native_legal_moves(p)
			pc["modifier"] = pu
			var buffed_dests = _native_legal_moves(p)
			pc["modifier"] = ""
			for dest in buffed_dests:
				if dest in plain_dests:
					continue   # reachable without the buff — no new threat
				if not game.board_state.has(dest):
					continue   # empty square, not a capture threat
				var victim = game.board_state[dest]
				if victim["color"] != bot_color:
					continue
				if victim["type"] == "King" and _king_protected(victim):
					continue   # bot's king is Shield/Ground protected — not capturable
				# Slice 1 made the King a REAL capturable piece, and Phase/Capture geometry
				# reaches it THROUGH blockers. A king capture wins outright, so it dominates
				# every material target — force this branch (MATE_SCORE) so the search sees
				# "leaving my king phase-reachable loses" instead of treating the king as
				# untouchable (the pre-king-capture assumption that left the bot blind).
				var vval = MATE_SCORE if victim["type"] == "King" else float(_eval_value(victim))
				if vval > best_val:
					best_val = vval
					best_target = {"pu": pu, "piece": p, "dest": dest}
		if best_target != null:
			branches.append(best_target)

	# --- TELEPORT: does a threatening opponent piece become MORE dangerous from a different
	# square? We pick the opponent piece that most threatens a high-value bot piece in its
	# current position and propose relocating it to any square it currently can't reach
	# that attacks an even-higher-value bot piece. Simple proxy: "does the teleport square
	# attack a bot piece worth >= TELEPORT_MIN_VALUE that the piece doesn't already attack?"
	if _opp_pu_slots.has("Teleport"):
		var best_tele = null
		var best_gain := float(TELEPORT_MIN_VALUE - 1)
		for p in game.board_state.keys():
			var pc = game.board_state[p]
			if pc["color"] != opp_color or pc["type"] == "King":
				continue
			if pc.get("is_super_pawn", false) or pc.get("modifier", "") != "":
				continue
			# Try a Teleport modifier to get the set of all empty squares it could reach.
			pc["modifier"] = "Teleport"
			var all_dests = _native_legal_moves(p)
			pc["modifier"] = ""
			for dest in all_dests:
				if game.board_state.has(dest):
					continue   # teleport requires empty square
				# Check if, after teleporting here, the piece attacks a worthwhile bot piece.
				# Temporarily place it, scan its threats, remove it again.
				var tmp = pc.duplicate()
				tmp["modifier"] = ""
				game.board_state[dest] = tmp
				var bs_backup = game.board_state.get(p)  # still there (teleport, not a move)
				game.board_state.erase(p)
				# NATIVE — tmp's modifier is stripped to "" above, so _native_legal_moves(dest)
				# is an exact match for game.get_legal_moves(dest, true) here (checking_threats
				# only changes behaviour for Teleport/Phase/Shield modifiers and castling, none
				# of which apply to a bare piece). Keeps this branch off game.get_legal_moves
				# entirely, matching the rest of the search.
				var new_threats = _native_legal_moves(dest)
				game.board_state.erase(dest)
				game.board_state[p] = bs_backup
				for t in new_threats:
					if not game.board_state.has(t):
						continue
					var vic = game.board_state[t]
					if vic["color"] != bot_color:
						continue
					if vic["type"] == "King" and _king_protected(vic):
						continue   # protected king can't be captured
					# Same as Phase/Capture: a Teleport that lands a piece attacking the bot's
					# King is a game-ending threat — force it as MATE-priority, never skip it.
					var gain = MATE_SCORE if vic["type"] == "King" else float(_eval_value(vic))
					if gain > best_gain:
						best_gain = gain
						best_tele = {"pu": "Teleport", "piece": p, "dest": dest}
		if best_tele != null:
			branches.append(best_tele)

	# --- SHIELD / GROUND: does the opponent protect the piece the bot is most likely to
	# capture? Pick whichever bot-attacked enemy piece has the highest value (the one the
	# bot wants most), since that's the rational shield target.
	for pu in ["Shield", "Ground"]:
		if not _opp_pu_slots.has(pu):
			continue
		var best_def = null
		var best_def_val = VAL["Knight"] - 1   # don't branch on trivial pawn shields
		for p in game.board_state.keys():
			var pc = game.board_state[p]
			if pc["color"] != opp_color or pc["type"] == "King":
				continue
			if pc.get("is_super_pawn", false) or pc.get("modifier", "") != "":
				continue
			if not _is_attacked(p, bot_color):
				continue
			var v = _eval_value(pc)
			if v > best_def_val:
				best_def_val = v
				best_def = {"pu": pu, "piece": p, "dest": Vector2(-1, -1)}
		if best_def != null:
			branches.append(best_def)

	return branches

# Apply an opponent power-up branch before generating moves for that MIN node.
# Returns an undo record for _revert_opp_pu. The "dest" field is only meaningful
# for geometry-extending buffs (Phase/Capture/Teleport) — for modifier-only buffs
# (Shield/Ground) "piece" carries the target square and "dest" is Vector2(-1,-1).
# NOTE: for Teleport the piece physically moves (we simulate the full relocation here so
# move generation in _negamax sees the piece on its new square). For Phase/Capture the
# modifier is applied to the existing square — the buff unlocks geometry that the
# subsequent move generation will discover naturally.
func _apply_opp_pu(branch: Dictionary) -> Dictionary:
	var pu: String = branch["pu"]
	var piece_sq: Vector2 = branch["piece"]
	var dest_sq: Vector2 = branch.get("dest", Vector2(-1, -1))

	if pu == "Teleport":
		# Physically relocate the piece so move generation sees it on the new square.
		var pc = game.board_state[piece_sq]
		var captured_at_dest = game.board_state.get(dest_sq, null)
		game.board_state.erase(piece_sq)
		game.board_state[dest_sq] = pc
		return {
			"pu": pu, "piece": piece_sq, "dest": dest_sq,
			"displaced": captured_at_dest,
			"prev_modifier": pc.get("modifier", ""),
			"prev_duration": pc.get("modifier_duration", 0),
		}
	else:
		# Phase / Capture / Shield / Ground: apply modifier to piece in place.
		var pc = game.board_state[piece_sq]
		var prev_mod = pc.get("modifier", "")
		var prev_dur = pc.get("modifier_duration", 0)
		pc["modifier"] = pu
		pc["modifier_duration"] = int(game.powerup_durations.get(pu, 1))
		return {
			"pu": pu, "piece": piece_sq, "dest": dest_sq,
			"displaced": null,
			"prev_modifier": prev_mod,
			"prev_duration": prev_dur,
		}

func _revert_opp_pu(undo: Dictionary) -> void:
	var pu: String = undo["pu"]
	var piece_sq: Vector2 = undo["piece"]
	var dest_sq: Vector2 = undo["dest"]

	if pu == "Teleport":
		# Move piece back to its original square.
		var pc = game.board_state[dest_sq]
		pc["modifier"] = undo["prev_modifier"]
		pc["modifier_duration"] = undo["prev_duration"]
		game.board_state.erase(dest_sq)
		game.board_state[piece_sq] = pc
		if undo["displaced"] != null:
			game.board_state[dest_sq] = undo["displaced"]
	else:
		# Restore modifier fields on the piece.
		var pc = game.board_state[piece_sq]
		pc["modifier"] = undo["prev_modifier"]
		pc["modifier_duration"] = undo["prev_duration"]

# Would `pc` be a worthwhile, legal target for an opponent defensive buff? Shield/Ground
# can't go on the King, can't stack on a piece that already carries a modifier, and aren't
# worth spending on a trivial piece (mirror of UberbotStrategy.SHIELD_MIN_VALUE).
func _is_shieldable(pc: Dictionary) -> bool:
	if pc["type"] == "King":
		return false
	if pc.get("is_super_pawn", false) or pc.get("modifier", "") != "":
		return false
	return _eval_value(pc) >= VAL["Knight"]   # Knight-or-better; not worth a slot on a pawn

func _piece_value(pc: Dictionary) -> int:
	if pc.get("is_super_pawn", false):
		return 8
	return int(game.piece_rules[pc["type"]]["value"])

func _is_attacked(pos: Vector2, attacker: String) -> bool:
	# NATIVE — was O(board pieces) calls to game.get_legal_moves per call, and this
	# function is invoked from _shield_awareness() inside _evaluate(), i.e. at EVERY
	# leaf node of the search whenever the opponent has a ready Shield/Ground slot
	# (_opp_def_ready). That made it the dominant hot-path cost surviving the
	# _native_legal_moves migration — eval runs far more often than move generation,
	# so this alone was enough to re-collapse search depth in exactly that common case.
	# _attacked_for_castle already IS a general "is this square attacked by `enemy`"
	# native scan (sliders/knights/pawns/super-pawns/king/Capture-buff, invulnerability-
	# aware) — reuse it directly instead of duplicating the geometry.
	return _attacked_for_castle(pos, attacker)

# Uses make/unmake so it stays cheap even though it's called from power-up planning.
func _is_attacked_after(from_pos: Vector2, to_pos: Vector2, attacker: String) -> bool:
	var undo = _make({"from": from_pos, "to": to_pos})
	var res = _is_attacked(to_pos, attacker)
	_unmake(undo)
	return res

func _other(color: String) -> String:
	return "Black" if color == "White" else "White"
