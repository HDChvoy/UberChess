extends RefCounted
class_name UberbotStrategy

# UberbotStrategy — the PER-TURN policy half of the AI opponent. It assembles the ordered
# action list for one turn and drives the two things that actually make the decisions:
#
#   UberbotPowerupPolicy (UberbotPowerupPolicy.gd) — the HARDCODED power-up rule book.
#       Decides which power-up to use, on what, and what to buy. Read that file to change
#       how the bot behaves with its kit; it is written to be read top to bottom.
#   UberBot (uber_bot.gd) — the SEARCH ENGINE. Picks the plain best move, and holds the
#       VETO over the rule book's proposals.
#   UberbotOpenings (UberbotOpenings.gd) — the opening book.
#
# WHAT CHANGED, AND WHY
#   Power-up choice used to be a search problem: the strategy generated candidate turns,
#   engine.score_turn ranked them, and a tier/margin/backstop system nudged the bot into
#   spending. It produced decisions no player could follow — most visibly a $4 Negate on a
#   $1 pawn with a $3 Ground ready in the next slot. The search only speaks centipawns, so
#   it could not see that trade at all, and Negate never reached the search anyway.
#
#   Now the rule book DECIDES and the search only VETOES. _choose_primary walks the
#   proposals in the rule book's own hardcoded precedence, and throws one out only when
#   playing it would score more than policy.veto_tolerance() centipawns below the plain
#   best move. Rules pick; the search stops disasters. That is the whole contract.
#
#   Deleted with the old system: SPEND_TIERS, PU_SEARCH_MARGIN, MARGIN_COST_COEF,
#   FORCED_USE_*, MAX_TARGETS_PER_TYPE, USE_PROB, BUY_WEIGHTS, FULL_SLOTS_BONUS and every
#   *_MIN_VALUE threshold. Their jobs are now done by one number — the policy's
#   `aggression` dial — plus the two absolute rules in section 2 of that file.
#
# BOARD-OWNERSHIP CONTRACT: when this file mutates game.board_state directly (the Cheat
# block in plan_turn), it pairs every mutation with its restore. The engine and the policy
# guarantee the same for every call made into them. The board is always left as it was found.

var game
var engine: UberBot
var policy: UberbotPowerupPolicy
var openings: UberbotOpenings

# --- OPENING BOOK ---
# The search alone plays the same few openings every game: the piece-square table rarely
# rates more than two or three opening moves closely enough for the root-variety jitter to
# pick between them. UberbotOpenings.gd replaces the first few plies with hard-coded theory
# instead — 9 different first moves as White, up to 10 replies to 1.e4 as Black, 96 named
# lines in total. Set false to disable and go back to pure search from move one.
const USE_OPENING_BOOK := true

# While a book move is playing the bot skips the power-up rules (nothing needs shielding on
# move two, and it makes the opening instant) but still BUYS, so it builds its kit during
# the opening. Cheat is skipped outright while in book: relocating a piece would put the
# board in a position no book line contains, dropping both sides out of theory immediately.
const BOOK_ALLOWS_BUY := true

# Hard cap on proposals actually scored per turn. Each veto check runs a full negamax to
# engine.candidate_depth(), so an unbounded walk just times out partway and the tail is
# dropped in silence. The rule book emits its proposals best-first, so a low cap costs
# variety, never correctness.
const MAX_PROPOSALS_SCORED := 8

# CEILING ON THE DEPTH OF A VETO SCORE, independent of the difficulty's search depth.
#
# engine.candidate_depth() is MAX_DEPTH - 2, clamped to 6 — so Hard scores candidates at 4 and
# Über at 6. Against a veto budget clamped to VETO_BUDGET_CEIL_MS (900ms) a single depth-6
# negamax can consume the entire pass, and the first `Time.get_ticks_usec() >= veto_deadline_us`
# check then breaks the loop with "(veto budget spent — N proposals left unscored)". The
# observable result at the top two difficulties was ONE proposal considered per turn: if the
# rule book's best pick was vetoed, nothing below it ever got a hearing and the bot played the
# plain move with a full rack. That reads exactly like a bot that refuses to use its kit.
#
# The veto exists to catch BLUNDERS — hanging a piece, walking into a fork — and 4 plies finds
# those. Depth past that buys positional nuance the veto is explicitly not asking for (the rule
# book already decided the use is sensible; see _choose_primary's contract). Trading it for
# three or four more proposals scored inside the same budget is the right side of that deal.
#
# Deliberately capped HERE and not in uber_bot.gd: candidate_depth() is also the engine's own
# knob and the search is FROZEN on strength. This changes the veto pass only.
const VETO_MAX_DEPTH := 4

# WALL-CLOCK CEILING ON THE WHOLE OF plan_turn, in milliseconds.
#
# engine.begin_scoring_budget() hands _choose_primary a FRESH full MAX_THINK_MS on top of the
# one engine.best_move() just spent, so plan_turn's natural worst case is ~2x MAX_THINK_MS.
# game.gd budgets the bot's ENTIRE turn to GameConfig.BOT_TURN_SECONDS and schedules every
# action against a single origin timestamp, so an overrun does not just make the bot slow —
# every _wait_until falls through to one process_frame and the whole turn's actions fire
# back-to-back in a single frame. The pacing collapses on exactly the turns the bot thinks
# hardest, which are the ones the player is most curious about.
#
# So planning is bounded from the top. The clock is stamped on entry to plan_turn and the
# veto pass stops at the mark, which means a slow deep search shortens the VETO rather than
# overrunning the turn. GameConfig owns the number (bot_plan_budget_ms) so it cannot drift
# from the pacing value game.gd is using.
const PLAN_BUDGET_FALLBACK_MS := 3300

# Never let the veto pass be squeezed below this. Under it the pass would score one candidate
# at most and the rule book would effectively run unchecked, which is worse than a slightly
# late turn — a blunder is permanent, a 200ms overrun is not.
const VETO_BUDGET_FLOOR_MS := 250

# ...and never let it run long even when the search finished early. Past this the extra
# candidates are the ones the rule book already ranked last.
const VETO_BUDGET_CEIL_MS := 900

var _plan_budget_ms := PLAN_BUDGET_FALLBACK_MS
var _plan_start_us := 0

# Fallback difficulty → aggression mapping, used only when GameConfig has no
# bot_powerup_aggression() accessor yet. GDD 8.6: difficulty should scale FLAMBOYANCE, not
# only depth — an Easy bot that spends recklessly is more fun than one that plays shallow
# chess quietly, so the cheap tiers get the loud settings.
const DIFFICULTY_AGGRESSION := {
	"Easy":   "reckless",
	"Normal": "liberal",
	"Hard":   "measured",
	"Uber":   "measured",
}

func _init(game_ref):
	game = game_ref
	engine = UberBot.new(game_ref)                          # the strategy owns the search engine
	policy = UberbotPowerupPolicy.new(game_ref, engine)     # ...and the rule book
	if USE_OPENING_BOOK:
		openings = UberbotOpenings.new()                    # builds its position index once, here
	_load_aggression()

# Reads the power-up dial from GameConfig. Prefers an explicit bot_powerup_aggression()
# accessor; falls back to the difficulty label; falls back to the policy's own default.
# Written defensively so the bot still runs against a GameConfig that has neither.
func _load_aggression() -> void:
	var cfg = Engine.get_main_loop().root.get_node_or_null("GameConfig") if Engine.get_main_loop() else null
	if cfg == null:
		return
	if cfg.has_method("bot_powerup_aggression"):
		policy.set_aggression(float(cfg.bot_powerup_aggression()))
	elif cfg.has_method("difficulty_label"):
		var label := String(cfg.difficulty_label())
		policy.set_preset(String(DIFFICULTY_AGGRESSION.get(label, "measured")))
	if cfg.has_method("bot_plan_budget_ms"):
		_plan_budget_ms = int(cfg.bot_plan_budget_ms())
	print("🎛️ power-up policy: ", policy.preset_label, " (aggression ",
		"%.2f" % policy.aggression, ", gold floor $", policy.gold_floor(),
		", veto ", int(policy.veto_tolerance()), "cp, plan budget ", _plan_budget_ms, "ms)")

# Trivial color flip, duplicated from the engine so the per-turn policy doesn't reach across
# the boundary for a one-liner. Cannot drift (there are only two colors).
func _other(color: String) -> String:
	return "Black" if color == "White" else "White"


# =====================================================================
# TURN PLANNING
# =====================================================================

func plan_turn(color: String) -> Array:
	# Stamped here, not in _choose_primary: the deep search and the Cheat probe below are
	# part of the same budget, so a slow search has to come out of the veto pass and not out
	# of game.gd's visible pacing.
	_plan_start_us = Time.get_ticks_usec()
	var planned := []            # classes spoken for this turn (mirrors used_classes_this_turn)
	var cheat_action = null
	var saved_board = null
	var saved_ep = null
	var saved_cps = null

	# Read the opponent's defensive capability ONCE, before any search runs. Held fixed for
	# the whole turn so the eval can factor it in cheaply at every leaf.
	engine.snapshot_opp_caps(color)

	# --- OPENING BOOK, consulted before anything else. Returns null the moment the position
	# leaves theory (including any position an Überchess power-up created), so everything
	# below is untouched for the rest of the game. ---
	var book_action = _book_turn(color)
	if book_action != null:
		return book_action

	# --- CHEAT (Uber). Cheat reshapes the board, so it is decided first and everything below
	# is planned in the relocated position. While Cheat is in play the Uber class is spent, so
	# Tap-In is off the table this turn. ---
	var ch = policy.plan_cheat(color)
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
	var base = engine.best_move(color)
	if base == null:
		# No legal move (game already over, or a cheat with no follow-up). Drop the cheat and
		# let game.gd's safety net handle the (terminal) position.
		if saved_board != null:
			game.board_state = saved_board
			game.en_passant_target = saved_ep
			game.cheat_protected_square = saved_cps
		return []

	# --- THE RULE BOOK DECIDES, THE SEARCH VETOES. ---
	var chosen = _choose_primary(color, base, planned)
	for c in chosen["classes"]:
		if c not in planned:
			planned.append(c)

	# --- ASSEMBLE: pre-move actions first (cheat, power-up uses, buy), then the terminal
	# move/tap-in last — the terminal action is what ends the turn. ---
	var pre := []
	if cheat_action != null:
		pre.append(cheat_action)
	for a in chosen["pre"]:
		pre.append(a)
	if not chosen["reviving"]:
		# A tap-in already spent gold on the substitution; buying on top of it double-dips the bank.
		#
		# SLOTS FREED THIS TURN. Every accepted "use" consumes its slot when game.gd's
		# apply_powerup lands (_consume_held_slot), and a Cheat consumes one inside
		# execute_cheat_move — but all of that happens during EXECUTION, seconds after planning.
		# The rack the shop can see right now still holds them, so without this count plan_buy
		# reads a full rack and declines on exactly the turns the bot is emptying it. That put a
		# hard ceiling on how fast the kit could turn over, and it stacked with the gold floor:
		# the bot ended up permanently holding the two cheapest items it ever bought.
		# `pre` at this point holds exactly the slot-consuming actions: the optional cheat, then
		# chosen["pre"], which is one "use" per accepted proposal. The terminal move has not been
		# appended yet. So its size IS the number of slots about to come free.
		var buy = policy.plan_buy(color, pre.size())
		if buy != null:
			pre.append(buy)
	pre.append(chosen["terminal"])

	# Restore the real board if we cheated (game.gd re-applies the cheat for real on execute).
	if saved_board != null:
		game.board_state = saved_board
		game.en_passant_target = saved_ep
		game.cheat_protected_square = saved_cps

	return pre

# Assembles a full turn around an opening-book move, or returns null if the position is
# off-book (the normal case after the first handful of moves, and immediately once a
# power-up has reshaped the board). Deliberately does NOT run best_move or the rule book:
# in book the move is already decided, so the whole think is skipped.
func _book_turn(color: String):
	if not USE_OPENING_BOOK or openings == null:
		return null
	var bk = openings.book_move(game, color)
	if bk == null:
		return null
	var pre := []
	if BOOK_ALLOWS_BUY:
		var buy = policy.plan_buy(color)
		if buy != null:
			pre.append(buy)
	pre.append({"kind": "move", "from": bk["from"], "to": bk["to"]})
	print("📖 book: ", bk["name"], "  ", bk["from"], " -> ", bk["to"])
	return pre


# =====================================================================
# THE RULES/VETO LOOP
# =====================================================================
# Walks the rule book's proposals in ITS precedence order and accepts each one the search
# does not veto, at most one per power-up class. Returns:
#   {"pre": [<game.gd use actions>], "terminal": <move|tapin action>, "classes": [...],
#    "move": {from,to}|null, "reviving": bool}
#
# The reference is playing the plain best move. Unlike the old system a proposal does NOT
# have to BEAT it — it only has to avoid losing more than policy.veto_tolerance()
# centipawns to it. That inversion is the point: the rule book already decided the use is
# sensible, so the search's only job is to catch the case where it hangs something.
func _choose_primary(color: String, base: Dictionary, planned: Array) -> Dictionary:
	engine.begin_scoring_budget()
	var cdepth: int = mini(engine.candidate_depth(), VETO_MAX_DEPTH)

	var move := {"from": base["from"], "to": base["to"]}
	var plain_score = engine.score_turn(color, [{"kind": "move", "from": move["from"], "to": move["to"]}], cdepth)
	var tolerance: float = policy.veto_tolerance()

	var accepted_pre := []        # game.gd "use" actions, in execution order
	var accepted_engine := []     # engine-side actions, applied before the terminal move
	var accepted_classes := []
	var handled := []             # squares a higher-ranked rule already claimed
	var move_locked := false      # a proposal has already replaced the base move
	var reasons := []
	var vetoed := 0
	var considered := 0

	var proposals: Array = policy.propose(color, base, planned)
	# Whatever the deep search left of the turn's planning budget, clamped. Under the floor
	# we deliberately overrun the pacing a little rather than let the rule book run unchecked.
	var spent_ms := (Time.get_ticks_usec() - _plan_start_us) / 1000
	var veto_ms := clampi(_plan_budget_ms - int(spent_ms), VETO_BUDGET_FLOOR_MS, VETO_BUDGET_CEIL_MS)
	var veto_deadline_us := Time.get_ticks_usec() + veto_ms * 1000
	for prop in proposals:
		if considered >= MAX_PROPOSALS_SCORED or engine.timed_out():
			break
		if Time.get_ticks_usec() >= veto_deadline_us:
			reasons.append("(veto budget spent — %d proposals left unscored)" % (proposals.size() - considered))
			break
		var cls := String(prop["class"])
		if cls in accepted_classes or cls in planned:
			continue
		# One rule per piece. This is what stops the bot Grounding a rook and then also
		# Negating it — the higher-ranked rule already solved that square.
		if prop["target"] in handled:
			continue
		if prop["move_override"] != null and move_locked:
			continue
		# Some rules only make sense while a specific piece is the one moving — Multiply pays
		# nothing unless its target is the capturer, and Negate's "is it doomed" test was run
		# on the board after the ORIGINAL move. If an earlier proposal swapped the terminal
		# move, those are stale and get dropped rather than silently misfiring.
		if prop["assumes_mover"] != null and prop["assumes_mover"] != move["from"]:
			continue

		# Build the trial turn: everything accepted so far, plus this proposal.
		var trial_move: Dictionary = prop["move_override"] if prop["move_override"] != null else move
		var trial := []
		trial.append_array(accepted_engine)
		trial.append_array(prop["engine_actions"])
		if not prop["reviving"]:
			trial.append({"kind": "move", "from": trial_move["from"], "to": trial_move["to"]})

		# A proposal that changes neither the board nor the move (Negate — its payoff is gold
		# denial, which the evaluation cannot see at all) would score EXACTLY the plain move
		# every time, so the veto is mathematically incapable of rejecting it. Scoring it
		# anyway burns one of MAX_PROPOSALS_SCORED and a full negamax to learn nothing.
		if prop["engine_actions"].is_empty() and prop["move_override"] == null and not prop["reviving"]:
			accepted_classes.append(cls)
			if prop["use"] != null:
				accepted_pre.append(prop["use"])
			handled.append(prop["target"])
			reasons.append("%s — %s" % [prop["item"], prop["rule"]])
			continue

		considered += 1
		var s = engine.score_turn(color, trial, cdepth)
		if engine.timed_out():
			break
		# NEUTRALISE THE EVALUATION'S OWN MODIFIER BONUSES before comparing. _evaluate pays a
		# flat SHIELD_BONUS (120) / GROUND_BONUS (60) for carrying the buff, and the search
		# cannot model expiry, so every Defense trial starts ~1-2 tolerance-widths ahead of
		# the plain move and the veto waves it through on the bonus alone. That matters most
		# for Shield, which STRIPS the carrier's own captures — shielding a defender silently
		# removes the recapture that was holding a square. Subtracting the bonus makes the
		# veto measure the actual positional change, which is what it is for.
		var measured: float = s - _eval_bonus(trial)
		if measured < plain_score - tolerance:
			vetoed += 1
			reasons.append("VETOED %s (%.0fcp below plain)" % [prop["item"], plain_score - measured])
			continue

		# --- accepted ---
		accepted_classes.append(cls)
		if prop["use"] != null:
			accepted_pre.append(prop["use"])
		accepted_engine.append_array(prop["engine_actions"])
		handled.append(prop["target"])
		reasons.append("%s — %s" % [
			(prop["item"] if String(prop["item"]) != "" else "Tap-In"), prop["rule"]])

		if prop["reviving"]:
			# A tap-in IS the terminal action: it ends the turn, so nothing else can follow.
			_log_turn(color, proposals.size(), considered, vetoed, reasons)
			return {"pre": accepted_pre, "terminal": prop["terminal"],
				"classes": accepted_classes, "move": null, "reviving": true}

		if prop["move_override"] != null:
			move = trial_move
			move_locked = true
			# The new mover must not then be buffed by a later rule — Ground would immobilise
			# the very piece we just decided to move.
			handled.append(move["from"])

	_log_turn(color, proposals.size(), considered, vetoed, reasons)
	return {
		"pre": accepted_pre,
		"terminal": {"kind": "move", "from": move["from"], "to": move["to"]},
		"classes": accepted_classes,
		"move": {"from": move["from"], "to": move["to"]},
		"reviving": false,
	}

# The flat bonuses _evaluate hands out purely for CARRYING a Defense modifier. Subtracted
# from a trial score so the veto compares real positions rather than bookkeeping. Super
# Pawn's premium is deliberately NOT included: that upgrade is permanent and the extra
# value is genuine, not an artefact of the search being unable to see expiry.
func _eval_bonus(actions: Array) -> float:
	var b := 0.0
	for a in actions:
		if String(a.get("kind", "")) != "modifier":
			continue
		match String(a.get("item", "")):
			"Shield": b += float(UberBot.SHIELD_BONUS)
			"Ground": b += float(UberBot.GROUND_BONUS)
	return b

# ONE BLOCK PER TURN that explains the decision in the rule book's own words. If the bot
# does something you don't like, this says which rule said to and whether the search argued.
func _log_turn(color: String, proposed: int, scored: int, vetoed: int, reasons: Array) -> void:
	var ready := []
	for s in game.powerup_slots[color]:
		if s["ready"]:
			ready.append(s["name"])
	print("🎲 [", policy.preset_label, " $", game.player_gold[color], "] ready=", ready,
		"  proposed=", proposed, " scored=", scored, " vetoed=", vetoed)
	if reasons.is_empty():
		print("     └─ no rule fired — playing the plain best move")
	else:
		for r in reasons:
			print("     └─ ", r)
