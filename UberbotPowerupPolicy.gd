extends RefCounted
class_name UberbotPowerupPolicy

# =====================================================================
# UberbotPowerupPolicy — the bot's HARDCODED power-up rule book.
# =====================================================================
#
# WHY THIS FILE EXISTS
#   The power-up policy used to be spread across three mechanisms that could not see
#   each other: a search-scored candidate list (Shield/Ground/Capture/Phase/Teleport/
#   Super Pawn/Multiply), a dice-rolled heuristic layer (Negate), and a weighted-random
#   shop (buying). The search only knows centipawns, so it had no way to notice that a
#   $4 Negate denying $1 of pawn income is a guaranteed loss, and the Negate path never
#   consulted the search at all. The observed failure: Negate on a pawn attacked by a
#   pawn, with a $3 Ground sitting ready in the next slot that would have made that pawn
#   uncapturable outright.
#
#   So power-up decisions are now WRITTEN DOWN, in one file, in plain rules you can read
#   top to bottom. The search no longer chooses — it only gets a VETO (see
#   UberbotStrategy._choose_primary): if the rule's turn scores more than
#   veto_tolerance() centipawns below the plain best move, it is thrown out and the next
#   rule is tried. Rules pick; the search stops disasters. Nothing else.
#
# THE DIAL
#   `aggression` (0.0 .. 2.0) is the one number that moves everything. Every rule states
#   its bar as a piece value at BASELINE, and bar() divides that bar by the dial. Raising
#   the dial lowers every bar at once, so the bot uses its kit on smaller and smaller
#   provocations; lowering it makes the bot hold everything for the queen. It also scales
#   the roll probabilities, the veto tolerance, and how much gold the shop keeps in
#   reserve. See PRESETS for the four named settings.
#
# UNITS — READ THIS BEFORE EDITING A THRESHOLD
#   Two different scales are in play and mixing them is how the original bug happened.
#     GOLD SCALE      engine._piece_value() and game.piece_rules — P1 N3 B3 R5 Q9,
#                     Super Pawn 8. This is what the shop charges in and what capture
#                     income pays out in. Power-up prices are in these units.
#     CENTIPAWN SCALE UberBot.VAL and every score the search returns — P100 N320 B330
#                     R500 Q900. This is MATERIAL, not money.
#   Every bar in this file is GOLD SCALE. veto_tolerance() is the only centipawn number
#   here, and it is named for it.
#
# BOARD-OWNERSHIP CONTRACT
#   Same as UberbotStrategy: any direct mutation of game.board_state is paired with its
#   restore before the function returns. The probes below (modifier swaps to test buffed
#   geometry, phantom pieces for capture-safety probes) all restore in the same function.

var game
var engine: UberBot
var rng := RandomNumberGenerator.new()

# _hanging_pieces is O(pieces²) — it asks every enemy piece for its move list to price the
# cheapest attacker — and four separate rules want the same answer each turn. Memoised per
# call-signature. MUST be cleared whenever the board changes underneath it, which is why
# _rule_negate clears it on both sides of its make/unmake probe.
var _hang_cache: Dictionary = {}


# =====================================================================
# 1. THE DIAL
# =====================================================================

# The four named settings. GameConfig maps difficulty onto these (see 8.6 in the GDD:
# "difficulty should scale flamboyance, not only depth"). Tune the numbers, not the names.
#
#   hoarder   — barely touches its kit. Only a queen is worth a slot. Plays like the old
#               pre-spend-tier bot, kept because it is the honest "off" position.
#   measured  — the tuned baseline. Defends knights and up, takes free material, buys
#               with a real gold reserve. This is what Hard/Uber should feel like.
#   liberal   — defends bishops and up, spends on smaller edges, will buff prophylactically
#               when nothing is under threat. Visibly "uses its stuff".
#   reckless  — fires on almost anything that passes the two absolute rules below. Loud,
#               frequently suboptimal, and the most fun to watch. Good for Easy/Normal.
const PRESETS := {
	"hoarder":  0.40,
	"measured": 1.00,
	"liberal":  1.45,
	"reckless": 2.00,
}
const AGGRESSION_MIN := 0.05
const AGGRESSION_MAX := 2.00

var aggression: float = 1.0
var preset_label: String = "measured"

func set_aggression(value: float) -> void:
	aggression = clampf(value, AGGRESSION_MIN, AGGRESSION_MAX)
	preset_label = _nearest_preset(aggression)

func set_preset(name: String) -> void:
	var key := name.to_lower()
	if PRESETS.has(key):
		aggression = float(PRESETS[key])
		preset_label = key
	else:
		push_warning("UberbotPowerupPolicy: unknown preset '%s' — falling back to measured." % name)
		aggression = 1.0
		preset_label = "measured"

func _nearest_preset(value: float) -> String:
	var best := "measured"
	var best_gap := INF
	for k in PRESETS.keys():
		var gap: float = absf(float(PRESETS[k]) - value)
		if gap < best_gap:
			best_gap = gap
			best = k
	return best

# THE CORE OF THE DIAL. Every rule below states its bar as "the piece value at baseline
# that justifies this power-up", and runs it through here. Dividing means a HIGHER dial
# produces a LOWER bar, i.e. more uses. A bar of 3 (knight-or-better) becomes 7.5 at
# hoarder, 3.0 at measured, 2.07 at liberal and 1.5 at reckless — so pawns only ever
# qualify at the top of the range, and only for rules the absolute rules below allow.
func bar(baseline_value: float) -> float:
	return baseline_value / maxf(aggression, AGGRESSION_MIN)

# Dice, scaled. The rolls exist so the bot does not look mechanical — the same position
# twice should not always produce the identical power-up. At reckless most rolls saturate
# to 1.0 and the bot becomes deterministic in the other direction.
func _roll(base_prob: float) -> bool:
	return rng.randf() < clampf(base_prob * aggression, 0.0, 1.0)

# How far below the plain best move a rule's turn may score before the search vetoes it.
# CENTIPAWNS. A hung knight is 320, so even at the top of the range the veto still catches
# real blunders — it just tolerates giving up a pawn's worth of position to use the kit.
const VETO_TOLERANCE_AT_ZERO := 25.0
const VETO_TOLERANCE_AT_MAX  := 300.0

func veto_tolerance() -> float:
	return lerpf(VETO_TOLERANCE_AT_ZERO, VETO_TOLERANCE_AT_MAX,
		clampf(aggression, 0.0, AGGRESSION_MAX) / AGGRESSION_MAX)

# Gold the shop must leave in the bank after any purchase. The old _plan_buy had
# GOLD_RESERVE = 0 and bought on a weighted dice roll until the bank was empty.
#
# CALIBRATION NOTE: both sides start at $10 and a Ground is $3, so this floor directly
# controls how fast the bot builds its opening kit. At measured it lands on $5 — low enough
# that it still fills two slots off the starting bank. Do not raise it: the observed failure
# was the bot UNDER-using its kit, not over-buying, and a high floor jams the rack shut in
# the opening, which is the same bug wearing a different hat.
#
# THE OLD RATIONALE FOR THIS NUMBER WAS WRONG AND IS WORTH RECORDING. It read "enough that
# the bot can always afford the cheapest defensive item in an emergency". THERE IS NO SUCH
# THING AS AN EMERGENCY PURCHASE IN THIS GAME: game.gd files every bought power-up as
# ready=false, and only _unlock_powerups() flips it, as control RETURNS to the owner. Gold
# held back cannot answer a threat on the turn that threat exists — by the time the purchase
# is usable the threat has resolved. The floor's only real job is to stop the bot emptying
# the bank on one expensive item, so it is now scaled by how full the rack already is
# (effective_gold_floor): with an empty rack there is nothing to protect, and holding cash
# to defend a rack that contains nothing is strictly worse than owning a Ground.
const GOLD_FLOOR_AT_ZERO := 10
const GOLD_FLOOR_AT_MAX  := 0

func gold_floor() -> int:
	return int(round(lerpf(float(GOLD_FLOOR_AT_ZERO), float(GOLD_FLOOR_AT_MAX),
		clampf(aggression, 0.0, AGGRESSION_MAX) / AGGRESSION_MAX)))

# The floor the SHOP actually applies, scaled by rack occupancy. `freeing` is how many slots
# this turn's already-accepted power-up uses will hand back before the buy executes.
#
# WHY THIS EXISTS: at measured the flat floor is $5, both sides start at $10, and the two
# cheapest useful items are Ground ($3) and Multiply ($2). The bot bought exactly those,
# landed on exactly $5, and could then not buy anything again until it captured something —
# so it spent whole games holding two items whose trigger conditions are both conjunctive and
# rare. That is the FREQUENCY half of "the bot barely uses its power-ups": it was not
# declining to fire, it had nothing loaded to fire. Scaling with occupancy means an empty
# rack refills at full speed and a full one still keeps a reserve.
func effective_gold_floor(color: String, freeing: int = 0) -> int:
	var filled: int = maxi(engine._slot_count(color) - freeing, 0)
	return int(round(float(gold_floor()) * float(filled) / float(game.MAX_SLOTS)))


# =====================================================================
# 2. THE TWO ABSOLUTE RULES — the dial cannot override these
# =====================================================================
#
# RULE A — A GOLD-PAYOFF POWER-UP MUST OUT-EARN ITS OWN PRICE.
#   Negate and Multiply pay out in GOLD and nothing else, which makes them directly
#   comparable to their shop price. Negate on a piece whose capture pays the opponent
#   less than Negate costs is a guaranteed loss at every aggression level, in every
#   position, forever. That is the rule the old code was missing.
#
#   Defensive and offensive buffs are deliberately NOT subject to this. Their payoff is
#   MATERIAL, which is worth vastly more than its gold price — a $5 Shield saving a
#   320-centipawn knight is a bargain even though the knight is only "3" in gold. Judging
#   Shield by Rule A would jam the rack shut, which is the opposite failure.
#
# RULE B — THE CHEAPEST POWER-UP THAT FULLY SOLVES THE PROBLEM WINS.
#   Ground ($3) makes a piece uncapturable. Shield ($5) makes it uncapturable and lets it
#   move. Teleport ($8) removes it from the square entirely. For "my rook is attacked" all
#   three work, so the bot spends the Ground. It climbs the ladder only when the cheap
#   option fails the requirement. Implemented by emitting save proposals in ascending cost
#   order and having the caller take the first one that survives the veto.

# Rule A, in one function. `gold_at_stake` is what the opponent would actually collect
# (Negate) or what the bot would actually gain (Multiply) — not the piece's material value.
func _pays_for_itself(item: String, gold_at_stake: int) -> bool:
	return gold_at_stake > int(game.powerup_costs.get(item, 0))


# =====================================================================
# 3. HARDCODED PRECEDENCE — which rule wins when several fire
# =====================================================================
# Read this as the bot's priorities, in order. These are deliberately fixed constants and
# NOT scaled by the dial: the dial decides how often a rule fires, never which rule
# outranks which. Within a rank, higher value-at-stake wins, then lower cost.
const RANK_SAVE_PIECE   := 100.0   # something of ours is hanging and a slot can save it
const RANK_WIN_MATERIAL :=  90.0   # a buff unlocks a safe capture we cannot otherwise make
const RANK_FORCING      :=  85.0   # a buff unlocks a CHECK that buys a turn we need
const RANK_MULTIPLY     :=  70.0   # we are already capturing — get paid double for it
const RANK_SUPERPAWN    :=  55.0   # invest in an advanced pawn
const RANK_TAPIN        :=  50.0   # sub a benched piece on for one that's on the field
const RANK_NEGATE       :=  40.0   # the piece is doomed anyway — deny the payout
const RANK_CHEAT        :=  30.0   # disrupt

# Advancement (ranks pushed) a pawn needs before Super Pawn is worth $10 at baseline.
const SUPERPAWN_BASELINE_ADVANCE := 3
# Piece value an enemy must be threatening before Cheat is worth $15 at baseline.
const CHEAT_BASELINE_DISRUPT := 5
# Tap-in has two shapes and therefore two bars.
# UPGRADE: how much VALUE the swap must gain before spending a sub on it at baseline.
# A whole rook of gain, so the bot never burns a scarce sub rotating a bishop for a knight.
const TAPIN_UPGRADE_BASELINE := 5
# RESCUE: how much the piece coming OFF must be worth before pulling a hanging piece to
# the bench is worth a sub and a tempo. Knight-or-better; a hanging pawn can just die.
const TAPIN_RESCUE_BASELINE := 3
# Hard cap on how many swaps the tap-in rule may put in front of the veto pass. The pass
# scores a handful of proposals under a wall clock shared with every other rule, so an
# unbounded bench would silently starve Defense and Attack of their turn. Five is wide
# enough for "the best rescue and a couple of upgrades" and no wider.
const TAPIN_MAX_PROPOSALS := 5
# Defensive bar at baseline: knight-or-better is worth a slot, a pawn is not.
const DEFENSE_BASELINE_VALUE := 3
# Offensive bar at baseline: unlocking a capture worth a knight or more.
const OFFENSE_BASELINE_VALUE := 3
# Bar for spending the $8 Teleport to walk a hanging piece clear. Declared HERE rather than
# read from UberBot.TELEPORT_MIN_VALUE so that every bar this file uses is visible in this
# block — retuning the escape rule should never mean going hunting in the search engine.
# (The engine keeps its own copy for modelling what the OPPONENT might teleport; the two are
# independent by design and do not have to agree.)
const ESCAPE_BASELINE_VALUE := 3
# =====================================================================
# WHY THERE IS NO PROPHYLACTIC DEFENSE RULE
# =====================================================================
# There used to be one — "nothing is threatened and the bank is fat, so buff the best piece
# anyway". It is deleted, and it should never come back, because it is not a tuning mistake.
# It is unsound under this game's duration model, and the proof is three lines:
#
#   1. Ground and Shield last exactly one cycle. game.powerup_durations is 1 for both, and
#      game.expire_modifiers runs as control RETURNS to the owner — so a buff applied on our
#      turn N covers the opponent's single reply and is gone at the start of turn N+1.
#   2. A Defense buff is therefore worth exactly one thing: "the opponent cannot capture this
#      piece on their VERY NEXT MOVE." It has no other effect and no other duration.
#   3. A prophylactic buff is by definition one placed when nothing can capture the piece on
#      the next move. So it prevents nothing, then expires.
#
# If the opponent CAN take the piece next move, it is in the threats list and the SAVE rule
# owns it. If they cannot, the buff is dead money. There is no third case, so the rule covered
# exactly and only the worthless one.
#
# THE PLAYTEST THAT KILLED IT: the bot Shielded its queen on d8 with nothing attacking d8 at
# all. The genuine threat was a white pawn on e6 wanting to play e7 and only THEN hit the
# queen — two moves. The Shield expired after the first one. It defended against nothing, and
# it could not have defended against the thing that was actually coming.
#
# The quiet-board impulse was right; it was aimed at the wrong shelf. The only power-up whose
# value OUTLIVES the reply is Super Pawn, which sets a permanent intrinsic flag rather than a
# timed modifier (game.apply_powerup: is_super_pawn = true, no duration). So that is where a
# bored, wealthy bot now puts its money — see QUIET_SUPERPAWN_RELAXATION.

# How far the Super Pawn advancement bar relaxes when nothing is under threat. The upgrade is
# permanent, so unlike a Defense buff it keeps paying long after the turn it was bought on —
# which makes "quiet board, full bank" a genuinely good moment to take it, not a desperate one.
# Dividing by 1.5 turns the measured bar of 3 ranks into 2.
const QUIET_SUPERPAWN_RELAXATION := 1.5
# ...and a quiet investment still requires this much in the bank afterwards, so the bot cannot
# spend itself defenceless out of boredom.
const QUIET_MIN_GOLD := 10

# Ranks a pawn must have pushed before Super Pawn is worth the slot. ONE function so the shop
# and the rule cannot disagree: if _buy_weights held the strict bar while _rule_superpawn used
# the relaxed one, the bot would refuse to BUY the item in exactly the situation the relaxation
# exists to cover, and the quiet-board outlet would be closed by a threshold mismatch.
func superpawn_bar(quiet: bool) -> float:
	var b := bar(float(SUPERPAWN_BASELINE_ADVANCE))
	return (b / QUIET_SUPERPAWN_RELAXATION) if quiet else b

# Base roll probabilities, before the dial scales them.
const P_SAVE       := 0.95
const P_OFFENSE    := 0.90
const P_MULTIPLY   := 0.95
const P_SUPERPAWN  := 0.60
const P_NEGATE     := 0.90
const P_CHEAT      := 0.45
const P_TAPIN      := 0.70
const P_BUY        := 0.75


func _init(game_ref, engine_ref: UberBot):
	game = game_ref
	engine = engine_ref
	rng.randomize()

func _other(color: String) -> String:
	return "Black" if color == "White" else "White"


# =====================================================================
# 4. THE ENTRY POINT
# =====================================================================
# Returns power-up proposals for this turn, best-first. The caller walks the list,
# accepts at most one per power-up CLASS, and veto-checks each acceptance against the
# plain best move. A proposal is a dictionary:
#
#   item            power-up name ("" for tap-in)
#   class           Defense / Agility / Attack / Economy / Uber
#   rule            plain-English reason, printed in the turn's debug line
#   rank            hardcoded precedence (see section 3)
#   cost            shop price in gold, for logging and Rule B ordering
#   target          the square the rule is about, Vector2(-1,-1) when not applicable
#   use             the game.gd action to execute, or null (tap-in carries it in terminal)
#   engine_actions  engine-side actions applied BEFORE the terminal move when scoring
#   move_override   {from,to} that REPLACES the base move, or null
#   terminal        a terminal action that ENDS the turn (tap-in only), or null
#   reviving        true only for tap-in — the flag name is legacy, the meaning is
#                   "this proposal IS the whole turn"
#
func propose(color: String, base, planned: Array) -> Array:
	_hang_cache.clear()
	var out := []
	var has_move: bool = base != null

	# The piece the bot already intends to move is off-limits for buffs: a modifier can
	# change its geometry under the search's chosen move, and Defense buffs would either
	# immobilise it (Ground) or forbid the capture it was going for (Shield).
	var mover: Vector2 = base["from"] if has_move else Vector2(-1, -1)
	var exclude := [mover] if has_move else []

	# WHAT IS ACTUALLY IN DANGER — judged AFTER our own move, against replies the opponent can
	# legally play. Every defensive rule below reads this one list instead of asking the board
	# itself, because asking the board answers the wrong question. See _threats_after_move.
	var threats: Array = _threats_after_move(color, base, exclude)
	var forcing: bool = _move_gives_check(color, base)

	if not engine._class_used("Defense", planned):
		out.append_array(_rule_save(color, threats))
	if not engine._class_used("Agility", planned):
		out.append_array(_rule_escape(color, threats))
	if has_move:
		out.append_array(_rule_win_material(color, planned))
		out.append_array(_rule_multiply(color, base, planned))
	# Buying a free turn with a check is only worth a slot when there is something to protect
	# AND the move we are already playing is not forcing on its own.
	if has_move and not forcing and not threats.is_empty():
		out.append_array(_rule_deliver_check(color, planned, threats))
	# A quiet board is where the permanent upgrade earns its keep — and the ONLY place any
	# power-up is worth buying "just because", since Super Pawn is the only one that outlives
	# the reply. See "WHY THERE IS NO PROPHYLACTIC DEFENSE RULE" for what used to sit here.
	var quiet: bool = threats.is_empty() and game.player_gold[color] >= QUIET_MIN_GOLD
	if has_move and not engine._class_used("Attack", planned):
		out.append_array(_rule_superpawn(color, exclude, quiet))
	if has_move and not engine._class_used("Economy", planned):
		out.append_array(_rule_negate(color, base, exclude))
	if not engine._class_used("Uber", planned):
		out.append_array(_rule_tapin(color))

	# Sort by hardcoded precedence, then by what is at stake, then cheapest first (Rule B).
	out.sort_custom(func(a, b):
		if a["rank"] != b["rank"]:
			return a["rank"] > b["rank"]
		if a["stake"] != b["stake"]:
			return a["stake"] > b["stake"]
		return a["cost"] < b["cost"])
	return out


# =====================================================================
# 5. THE RULES
# =====================================================================

# --- THREAT MODEL: WHAT IS IN DANGER *AFTER* WE MOVE -----------------
#
# THE BUG THIS EXISTS TO FIX, from a real game. The bot played Bb3, giving check. On the same
# turn it spent a $5 Shield on its OTHER bishop, on c1, because a black pawn on d2 was
# geometrically able to take it. But black was in check: ...dxc1 does not answer the check, so
# it was never a legal reply. The Shield defended against a move that could not be played, and
# expired before the pawn was ever free to play it. Five dollars for nothing.
#
# The rules were asking the board the wrong question in two separate ways:
#
#   1. WRONG POSITION. _hanging_pieces ran on the CURRENT board — before the move the bot had
#      already decided to make. A threat the move answers, walks away from, blocks or captures
#      was still counted as live.
#   2. WRONG MOVE LIST. _enemy_capture_map asks get_legal_moves(p, false), which is raw
#      geometry with NO king-safety filter. So it counts captures by pinned pieces, and — the
#      case above — every capture while the opponent is in check, none of which are legal.
#
# Both are fixed by probing the position the opponent will actually face. _rule_negate already
# did exactly this ("a checking move forces the opponent to respond and the capture never
# happens") and was the only rule that got it right; this generalises its probe to the rest.
#
# THE MOVER'S TWO SQUARES ARE BOTH EXCLUDED. base["from"] is empty after the move and cannot be
# buffed; base["to"] holds the mover post-move, but game.gd executes every "use" BEFORE the
# terminal move, so buffing that square would land the modifier on whatever is standing there
# NOW — an enemy piece, or nothing at all.
#
# EVERY RESULT IS RE-VALIDATED against the real board before it is returned, for the same
# reason _rule_negate re-validates: castling relocates a rook and en passant clears a square
# the mover never touched, so a square that held one of our pieces in the probe may hold
# something else, or nothing, by the time the use executes.
func _threats_after_move(color: String, base, exclude: Array) -> Array:
	if base == null:
		return _hanging_pieces(color, exclude)

	# The probe moves a piece, so answers cached about the CURRENT board must not be visible
	# inside it — but they are still valid afterwards. Swap the cache out, don't clear it.
	var saved_cache := _hang_cache
	_hang_cache = {}
	var undo = engine._make({"from": base["from"], "to": base["to"]})
	var gives_check: bool = game.is_in_check(_other(color))
	var found := []
	for t in _hanging_pieces(color, exclude + [base["to"]], gives_check):
		found.append({"pos": t["pos"], "val": t["val"],
			"type": String(game.board_state[t["pos"]]["type"])})
	engine._unmake(undo)
	_hang_cache = saved_cache

	var out := []
	for t in found:
		if not game.board_state.has(t["pos"]):
			continue
		var pc = game.board_state[t["pos"]]
		if pc["color"] != color or String(pc["type"]) != t["type"]:
			continue
		out.append({"pos": t["pos"], "val": t["val"]})
	return out

# Does the move we are about to play give check? Read once per turn and handed to the rules,
# so nobody probes the board twice for the same answer.
func _move_gives_check(color: String, base) -> bool:
	if base == null:
		return false
	var undo = engine._make({"from": base["from"], "to": base["to"]})
	var yes: bool = game.is_in_check(_other(color))
	engine._unmake(undo)
	return yes


# --- RULE: SAVE ------------------------------------------------------
# "A piece of mine is hanging and I hold something that stops it being taken."
# Emits Ground before Shield (Rule B — both make the piece uncapturable, Ground is $2
# cheaper). Teleport is a separate rule because it is Agility, not Defense, and can
# therefore stack with a Ground on a DIFFERENT piece in the same turn.
func _rule_save(color: String, threats: Array) -> Array:
	var out := []
	if not (engine._ready_has(color, "Ground") or engine._ready_has(color, "Shield")):
		return out
	if not _roll(P_SAVE):
		return out
	var min_val := bar(float(DEFENSE_BASELINE_VALUE))
	for t in threats:
		if float(t["val"]) < min_val:
			continue
		# Ground immobilises for one cycle. That is free on a piece that was not moving —
		# which is exactly the case here, since the mover is excluded above.
		if engine._ready_has(color, "Ground"):
			out.append(_defense_proposal("Ground", t,
				"%s worth %d is hanging — Ground is the cheapest thing that saves it" % [
					game.board_state[t["pos"]]["type"], t["val"]]))
		if engine._ready_has(color, "Shield"):
			out.append(_defense_proposal("Shield", t,
				"%s worth %d is hanging — Shield saves it and leaves it mobile" % [
					game.board_state[t["pos"]]["type"], t["val"]]))
	return out

func _defense_proposal(item: String, t: Dictionary, why: String) -> Dictionary:
	return {
		"item": item, "class": "Defense", "rule": why,
		"rank": RANK_SAVE_PIECE, "stake": float(t["val"]),
		"cost": int(game.powerup_costs.get(item, 0)), "target": t["pos"],
		"use": {"kind": "use", "item": item, "target": t["pos"]},
		"engine_actions": [{"kind": "modifier", "item": item, "target": t["pos"]}],
		"move_override": null, "terminal": null, "reviving": false, "assumes_mover": null,
	}

# --- RULE: ESCAPE ----------------------------------------------------
# "A piece of mine is hanging and Teleport can walk it off the square entirely."
# Third rung of the Rule B ladder ($8). Only fires when the piece is worth the premium.
func _rule_escape(color: String, threats: Array) -> Array:
	var out := []
	if not engine._ready_has(color, "Teleport") or not _roll(P_SAVE):
		return out
	var enemy := _other(color)
	var min_val := bar(float(ESCAPE_BASELINE_VALUE))
	for t in threats:
		if float(t["val"]) < min_val:
			continue
		var landing = _safe_teleport_landing(t["pos"], enemy)
		if landing == null:
			continue
		out.append({
			"item": "Teleport", "class": "Agility",
			"rule": "%s worth %d is hanging — Teleport it clear" % [
				game.board_state[t["pos"]]["type"], t["val"]],
			"rank": RANK_SAVE_PIECE, "stake": float(t["val"]),
			"cost": int(game.powerup_costs.get("Teleport", 0)), "target": t["pos"],
			"use": {"kind": "use", "item": "Teleport", "target": t["pos"]},
			# An instant Agility buff leaves no lasting state: the scored position is just
			# the relocated piece, so the buffed move REPLACES the base move.
			"engine_actions": [], "move_override": {"from": t["pos"], "to": landing},
			"terminal": null, "reviving": false, "assumes_mover": null,
		})
	return out

# --- RULE: WIN MATERIAL ----------------------------------------------
# "Capture or Phase geometry unlocks a safe capture that normal geometry cannot reach."
# This is the least controversial power-up use in the game and it should fire eagerly.
func _rule_win_material(color: String, planned: Array) -> Array:
	var out := []
	var min_val := bar(float(OFFENSE_BASELINE_VALUE))
	for pair in [["Capture", "Attack"], ["Phase", "Agility"]]:
		var item: String = pair[0]
		var cls: String = pair[1]
		if not engine._ready_has(color, item) or engine._class_used(cls, planned):
			continue
		if not _roll(P_OFFENSE):
			continue
		for mv in _captures_unlocked_by(color, item):
			if float(mv["victim"]) < min_val:
				continue
			out.append({
				"item": item, "class": cls,
				"rule": "%s unlocks a safe capture worth %d" % [item, mv["victim"]],
				"rank": RANK_WIN_MATERIAL, "stake": float(mv["victim"]),
				"cost": int(game.powerup_costs.get(item, 0)), "target": mv["from"],
				"use": {"kind": "use", "item": item, "target": mv["from"]},
				"engine_actions": [], "move_override": {"from": mv["from"], "to": mv["to"]},
				"terminal": null, "reviving": false, "assumes_mover": null,
			})
	return out

# --- RULE: DELIVER CHECK ---------------------------------------------
# "I cannot save what is hanging, so I will take the opponent's turn away instead."
#
# THE EXACT INVERSE OF THE THREAT-MODEL FIX ABOVE, and it only makes sense once that fix is in.
# A check does not merely pay $2 (game.gd _finish_turn: player_gold[acting] += 2) — it deletes
# every reply that is not an evasion. So when something of ours is hanging and no Defense or
# Agility slot can cover it, a forcing check is a way of paying for the piece's survival out of
# the Attack/Agility rack instead. The material saved is worth several times the $2.
#
# THIS IS NARROW ON PURPOSE. "Patzer sees a check, patzer gives check" is a real failure mode,
# and a bot that shoves its bishop to the edge of the board for $2 every turn would be worse
# than one that hoards. So the rule refuses to fire unless ALL of these hold:
#   - something is genuinely hanging AFTER our intended move (propose() gates on threats)
#   - the move we already intend is not itself a check (no point buying what we have)
#   - the buff unlocks a check that plain geometry cannot reach
#   - the checking piece is SAFE where it lands — a check that hangs the checker is a gift,
#     and worse than the threat it was trying to answer
#   - what is hanging is worth at least the defensive bar, scaled by the dial
#
# It ranks just under WIN_MATERIAL: winning a piece outright beats renting a tempo. It ranks
# ABOVE Multiply because the material at risk is larger than any Multiply payout.
func _rule_deliver_check(color: String, planned: Array, threats: Array) -> Array:
	var out := []
	var at_stake := 0.0
	for t in threats:
		at_stake = maxf(at_stake, float(t["val"]))
	if at_stake < bar(float(DEFENSE_BASELINE_VALUE)):
		return out
	if not _roll(P_OFFENSE):
		return out
	for pair in [["Capture", "Attack"], ["Phase", "Agility"]]:
		var item: String = pair[0]
		var cls: String = pair[1]
		if not engine._ready_has(color, item) or engine._class_used(cls, planned):
			continue
		for mv in _checks_unlocked_by(color, item):
			out.append({
				"item": item, "class": cls,
				"rule": "$%d of ours is hanging — %s lets the %s check instead, which takes the reply away" % [
					int(at_stake), item, mv["checker"]],
				"rank": RANK_FORCING, "stake": at_stake,
				"cost": int(game.powerup_costs.get(item, 0)), "target": mv["from"],
				"use": {"kind": "use", "item": item, "target": mv["from"]},
				"engine_actions": [], "move_override": {"from": mv["from"], "to": mv["to"]},
				"terminal": null, "reviving": false, "assumes_mover": null,
			})
	return out

# Checks a buff unlocks that plain geometry cannot reach, and that do not hang the checker.
# Same geometry-only reasoning as _captures_unlocked_by: get_safe_moves strips Agility
# modifiers during its internal threat scans by design, so buffed would equal plain every time.
func _checks_unlocked_by(color: String, buff_name: String) -> Array:
	var out := []
	var enemy := _other(color)
	for p in game.board_state.keys():
		var pc = game.board_state[p]
		if pc["color"] != color or pc["type"] == "King":
			continue
		if pc.get("is_super_pawn", false) or pc.get("modifier", "") != "":
			continue
		var plain: Array = game.get_legal_moves(p, false)
		pc["modifier"] = buff_name
		var buffed: Array = game.get_legal_moves(p, false)
		pc["modifier"] = ""
		for dest in buffed:
			if dest in plain:
				continue
			if game.board_state.has(dest) and game.board_state[dest]["type"] == "King":
				continue   # taking the King is _rule_win_material's business, not this one
			if engine._is_attacked_after(p, dest, enemy):
				continue   # a check that hangs the checker costs more than it buys
			# Does it actually check? Simulate the buffed move and ask. The modifier is put back
			# on for the probe because Phase/Teleport geometry is what reaches the square at all.
			var undo = engine._make({"from": p, "to": dest})
			var checks: bool = game.is_in_check(enemy)
			engine._unmake(undo)
			if checks:
				out.append({"from": p, "to": dest, "checker": String(pc["type"])})
	return out

# --- RULE: MULTIPLY --------------------------------------------------
# "I am capturing something anyway — get paid double for it."
# NOTE ON THE OLD BAR: this used to require a victim worth 3+, which is strictly wrong.
# engine._multiply_reward pays $4 for a Multiplied pawn capture against $1 normally, so
# even a pawn nets +$3 on a $2 slot. Rule A is the correct and only test here.
func _rule_multiply(color: String, base: Dictionary, planned: Array) -> Array:
	var out := []
	if not engine._ready_has(color, "Multiply") or engine._class_used("Economy", planned):
		return out
	if not _roll(P_MULTIPLY):
		return out
	var bt: Vector2 = base["to"]
	var bf: Vector2 = base["from"]
	if not game.board_state.has(bt) or not game.board_state.has(bf):
		return out
	var victim = game.board_state[bt]
	if victim["color"] == color or victim["type"] == "King":
		return out
	var mover = game.board_state[bf]
	if mover["type"] == "King":
		return out   # power-ups may never target the King — game.apply_powerup rejects it
	if mover.get("is_super_pawn", false) or mover.get("modifier", "") != "":
		return out   # one modifier per piece, and Super Pawns take none
	# LIABILITY — the half of Multiply this rule used to ignore. The modifier survives the
	# opponent's whole reply (duration 1 owner turn, not an instant Agility buff), and
	# game._capture_payout reads the VICTIM's modifier before the capturer's. So a Multiplied
	# piece that gets taken pays the OPPONENT double. Buffing a queen to turn a $1 pawn
	# capture into $4, then losing her, hands back $18 instead of $9 — a net loss on a rule
	# that advertised a guaranteed gain. score_turn cannot catch it either: _turn_income_cp
	# only scores the bot's own actions and is deliberately blind to opponent income.
	# So: only ever Multiply a capturer that is safe where it lands.
	if engine._is_attacked_after(bf, bt, _other(color)):
		return out
	# Rule A: the EXTRA gold this earns, not the victim's raw value.
	var gain := int(round(engine._multiply_reward(victim))) - engine._piece_value(victim)
	if not _pays_for_itself("Multiply", gain):
		return out
	out.append({
		"item": "Multiply", "class": "Economy",
		"rule": "capturing a %s anyway — Multiply turns $%d into $%d" % [
			victim["type"], engine._piece_value(victim), int(round(engine._multiply_reward(victim)))],
		"rank": RANK_MULTIPLY, "stake": float(gain),
		"cost": int(game.powerup_costs.get("Multiply", 0)), "target": bf,
		"use": {"kind": "use", "item": "Multiply", "target": bf},
		"engine_actions": [{"kind": "modifier", "item": "Multiply", "target": bf}],
		"move_override": null, "terminal": null, "reviving": false,
		# Multiply only pays if THIS piece is the one that captures. If a higher-ranked rule
		# swapped the terminal move to a different piece, this proposal is stale — the caller
		# drops it rather than buffing a piece that is no longer going anywhere.
		"assumes_mover": bf,
	})
	return out

# --- RULE: SUPER PAWN ------------------------------------------------
# "This pawn is far enough up the board that $10 of permanent upgrade pays off."
#
# ALSO THE QUIET-BOARD RULE, and the only power-up that can honestly hold that job. Super Pawn
# is not a timed modifier — game.apply_powerup sets is_super_pawn = true and leaves
# modifier_duration at 0, so the upgrade never expires. That is what separates it from Ground
# and Shield: on a board where nothing is happening, a one-cycle Defense buff protects against
# nothing and evaporates, while a permanent upgrade is still on the board twenty moves later.
# So when there is no threat to answer and the bank can stand it, the advancement bar relaxes
# and the bot invests instead of hoarding.
func _rule_superpawn(color: String, exclude: Array, quiet: bool = false) -> Array:
	var out := []
	if not engine._ready_has(color, "Super Pawn"):
		return out
	if not _roll(P_SUPERPAWN):
		return out
	var min_adv := superpawn_bar(quiet)
	var enemy := _other(color)
	for p in game.board_state.keys():
		if p in exclude:
			continue
		var pc = game.board_state[p]
		if pc["color"] != color or pc["type"] != "Pawn":
			continue
		if pc.get("is_super_pawn", false) or pc.get("modifier", "") != "":
			continue
		var adv: int = (6 - int(p.y)) if color == "White" else (int(p.y) - 1)
		if float(adv) < min_adv:
			continue
		# Never sink $10 into a pawn that is about to be taken for free.
		if engine._is_attacked(p, enemy) and not engine._is_attacked(p, color):
			continue
		out.append({
			"item": "Super Pawn", "class": "Attack",
			"rule": "pawn is %d ranks up — worth the permanent upgrade" % adv,
			"rank": RANK_SUPERPAWN, "stake": float(adv),
			"cost": int(game.powerup_costs.get("Super Pawn", 0)), "target": p,
			"use": {"kind": "use", "item": "Super Pawn", "target": p},
			"engine_actions": [{"kind": "superpawn", "target": p}],
			"move_override": null, "terminal": null, "reviving": false, "assumes_mover": null,
		})
	return out

# --- RULE: NEGATE ----------------------------------------------------
# THE RULE THAT THE SCREENSHOT BUG LIVES IN. Negate does not save the piece — it only
# denies the opponent the gold when the piece dies. So it is correct ONLY when all three
# hold, and the old code checked none of them:
#   1. The piece is genuinely going to be captured (it is hanging).
#   2. The payout being denied EXCEEDS Negate's own $4 price (Rule A). With gold values
#      P1 N3 B3 R5 Q9 that means Negate only ever goes on a ROOK or a QUEEN. Never a pawn.
#   3. We are not already saving that piece some other way — the caller drops any proposal
#      whose target a higher-ranked rule already claimed, so a Grounded rook never also
#      gets Negated.
# The old path also skipped the check test; kept, because a checking move forces the
# opponent to respond and the capture never happens.
func _rule_negate(color: String, base: Dictionary, exclude: Array) -> Array:
	var out := []
	if not engine._ready_has(color, "Negate") or not _roll(P_NEGATE):
		return out
	# Judge the board AS IT WILL LOOK after the move, so we do not Negate a piece whose
	# only attacker is the one we are about to capture. The piece TYPE is read inside the
	# probe, never after the unmake — see the re-validation below for why.
	# The probe below moves a piece, so cached answers about the CURRENT board must not be
	# visible inside it — but they are still valid afterwards, and recomputing them costs a
	# full board scan the think budget would rather keep. Swap the cache out, don't clear it.
	var saved_cache := _hang_cache
	_hang_cache = {}
	var undo = engine._make({"from": base["from"], "to": base["to"]})
	var gives_check: bool = game.is_in_check(_other(color))
	var found := []
	if not gives_check:
		for t in _hanging_pieces(color, exclude + [base["to"]]):
			found.append({"pos": t["pos"], "val": t["val"],
				"type": String(game.board_state[t["pos"]]["type"])})
	engine._unmake(undo)
	_hang_cache = saved_cache   # discard everything cached during the probe; restore the real board's
	if gives_check:
		return out

	for t in found:
		# Rule A. This single line is the whole fix for "$4 to deny $1": with gold values
		# P1 N3 B3 R5 Q9 and Negate at $4, only a Rook or a Queen ever clears it.
		if not _pays_for_itself("Negate", int(t["val"])):
			continue
		# The square was judged on the POST-move board but the use executes on the PRE-move
		# one (game.gd runs every "use" before the terminal move). Castling relocates a rook
		# and en passant clears a square the mover never touched, so re-confirm the same
		# piece is really standing there before proposing anything.
		if not game.board_state.has(t["pos"]):
			continue
		var pc = game.board_state[t["pos"]]
		if pc["color"] != color or String(pc["type"]) != t["type"]:
			continue
		out.append({
			"item": "Negate", "class": "Economy",
			"rule": "%s worth $%d is lost anyway — deny the payout" % [t["type"], t["val"]],
			"rank": RANK_NEGATE, "stake": float(t["val"]),
			"cost": int(game.powerup_costs.get("Negate", 0)), "target": t["pos"],
			"use": {"kind": "use", "item": "Negate", "target": t["pos"]},
			# DELIBERATELY EMPTY. Negate's payoff is gold DENIAL, which the evaluation
			# cannot see at all — scoring it would just reproduce the plain move's score.
			# Leaving it out also keeps a modifier off a square the terminal move may be
			# about to rearrange. Rule A is the gate here, not the search.
			"engine_actions": [],
			"move_override": null, "terminal": null, "reviving": false,
			# "Is this piece doomed?" was answered on the board after THIS move. Swap the
			# move and the answer may no longer hold, so the caller drops the proposal.
			"assumes_mover": base["from"],
		})
	return out

# --- RULE: TAP-IN ----------------------------------------------------
# Terminal action: ends the turn, so it is proposed alone and the caller stops if it wins.
#
# THE CANDIDATE SPACE IS THE WHOLE PROBLEM HERE. Bench × own-pieces is up to 15 × 15, and
# the veto pass scores at most MAX_PROPOSALS_SCORED of everything the rule book returns,
# wall-clock bounded. An unfiltered list would crowd every other rule out of the turn. So
# the filtering happens INSIDE this rule, before anything reaches the caller, and only two
# shapes ever get proposed:
#
#   UPGRADE — the piece coming on is worth materially more than the one coming off.
#   RESCUE  — the piece coming off is hanging (the real _hanging_pieces test, not "attacked")
#             and worth enough to be worth a tempo. This is the play the mechanic exists for:
#             a doomed Queen walks to the bench for $1 and a pawn's presence.
#
# SUBS ARE SCARCE, NOT MERELY LEGAL. Three per match, never refunded. With one left the bar
# to spend it has to rise, or the bot cheerfully burns its last sub on a marginal rotation in
# move 12 and has nothing when the queen is trapped in move 40. Scarcity therefore scales
# BOTH the value bar and the gold-floor test, per GDD 8.5.
func _rule_tapin(color: String) -> Array:
	var out := []
	if not _roll(P_TAPIN):
		return out
	if game.subs_left[color] <= 0:
		return out
	# A tap-in swaps one of our pieces for another on the SAME square, so it changes no
	# occupancy and can never break a check. Proposing one while in check would have the veto
	# pass burn budget on a turn that cannot legally stand — and game._bot_tapin would refuse
	# it at execution anyway, leaving the turn unswapped until game.gd's fallback fires.
	if game.is_in_check(color):
		return out
	var pool: Array = game.bench[color]
	if pool.is_empty():
		return out

	# 1.0 with a full budget, rising as the budget empties (3/3 → 1.0, 3/1 → 3.0).
	var scarcity: float = float(game.SUBS_PER_MATCH) / float(maxi(1, game.subs_left[color]))
	var upgrade_bar: float = bar(float(TAPIN_UPGRADE_BASELINE)) * scarcity
	var rescue_bar: float = bar(float(TAPIN_RESCUE_BASELINE)) * scarcity

	# What is actually losing material right now, on the CURRENT board — a tap-in replaces
	# the move rather than following it, so the post-move threat list is the wrong question.
	var hanging := {}
	for t in _hanging_pieces(color, []):
		hanging[t["pos"]] = float(t["val"])

	for i in range(pool.size()):
		var in_type: String = pool[i]["type"]
		var in_val := int(game.piece_rules[in_type]["value"])
		# game._tapin_targets is the single source of truth for legality AND affordability
		# (King, Grounded, promotion rank, gold). The rule book must not re-derive any of it.
		for square in game._tapin_targets(color, in_type):
			var out_type: String = String(game.board_state[square]["type"])
			var out_val := int(game.piece_rules[out_type]["value"])
			var cost: int = game.tapin_cost(in_type, out_type)
			# The same gold floor a purchase respects: emptying the bank for a rook leaves
			# the bot unable to answer anything for five turns. Scarcity makes a sub spent
			# late in the budget "cost" more against that floor than an early one.
			if game.player_gold[color] - int(ceil(float(cost) * scarcity)) < gold_floor():
				continue
			var gain := float(in_val - out_val)
			var why := ""
			var stake := 0.0
			if hanging.has(square) and hanging[square] >= rescue_bar:
				# RESCUE. What's at stake is the piece we're saving, not what comes on.
				why = "%s on %s is hanging — %s comes on, %s walks to the bench for $%d" \
					% [out_type, str(square), in_type, out_type, cost]
				stake = hanging[square]
			elif gain >= upgrade_bar:
				# UPGRADE. What's at stake is the material the swap gains.
				why = "%s on the bench outclasses the %s on %s by %d — $%d to swap" \
					% [in_type, out_type, str(square), int(gain), cost]
				stake = gain
			else:
				continue
			out.append({
				"item": "", "class": "Uber",
				"rule": why,
				"rank": RANK_TAPIN, "stake": stake, "cost": cost, "target": square,
				"use": null,
				"engine_actions": [{"kind": "tapin", "bench_index": i, "square": square, "color": color}],
				"move_override": null, "assumes_mover": null,
				"terminal": {"kind": "tapin", "index": i, "square": square}, "reviving": true,
			})
	# Even after filtering, a rich bench late in the game can offer a dozen swaps. Keep the
	# best few by stake — the caller's budget is shared with every other rule in the turn.
	out.sort_custom(func(a, b):
		if a["stake"] != b["stake"]:
			return a["stake"] > b["stake"]
		return a["cost"] < b["cost"])
	if out.size() > TAPIN_MAX_PROPOSALS:
		out.resize(TAPIN_MAX_PROPOSALS)
	return out

# --- RULE: CHEAT -----------------------------------------------------
# Cheat reshapes the board, so the strategy resolves it BEFORE the deep search rather than
# as a proposal. Returns {from, to} or null. Still heuristic (GDD slice 2 folds it into the
# search), but now with a value bar and a dial-scaled roll instead of firing on a coin flip.
func plan_cheat(color: String):
	if not engine._ready_has(color, "Cheat") or not _roll(P_CHEAT):
		return null
	var enemy := _other(color)
	var min_disrupt := bar(float(CHEAT_BASELINE_DISRUPT))
	var attackers := []
	for p in game.board_state.keys():
		var pc = game.board_state[p]
		if pc["color"] != enemy or pc["type"] == "King":
			continue
		for m in game.get_legal_moves(p, true):
			if not game.board_state.has(m):
				continue
			var victim = game.board_state[m]
			if victim["color"] == color and float(engine._piece_value(victim)) >= min_disrupt:
				attackers.append({"pos": p, "threat": engine._piece_value(victim)})
				break
	if attackers.is_empty():
		return null   # nothing worth $15 to disrupt — hold it
	attackers.sort_custom(func(a, b): return a["threat"] > b["threat"])
	var from_pos: Vector2 = attackers[0]["pos"]
	var dests: Array = game.get_cheat_moves(from_pos)
	if dests.is_empty():
		return null
	# Prefer dragging the attacker to an empty square where our own pieces already cover it.
	var best = null
	for d in dests:
		if game.board_state.has(d):
			continue
		if engine._is_attacked(d, color):
			return {"from": from_pos, "to": d}
		if best == null:
			best = d
	if best == null:
		# Every legal destination is OCCUPIED. game.execute_cheat_move captures whatever is
		# standing on the target square for no gold, and game.get_cheat_moves only excludes
		# Kings — so "take the first destination" can spend the $15 Uber slot to delete the
		# bot's OWN queen. Hold the Cheat instead.
		#
		# This has to be caught here and nowhere else: plan_turn commits the relocation to
		# game.board_state before engine.best_move() runs, so the search only ever sees the
		# post-collateral position and can never compare it against not cheating at all.
		return null
	return {"from": from_pos, "to": best}


# =====================================================================
# 6. THE SHOP
# =====================================================================
# Replaces the old weighted-dice _plan_buy. Two things changed and both were real bugs:
#   1. GOLD_RESERVE was 0, so the bot bought until it was broke. It now keeps
#      gold_floor() in the bank, always.
#   2. BUY_WEIGHTS were static, so the bot bought a Teleport it had no use for while its
#      Defense rack sat empty. Weights are now computed from the board every turn.
# `freeing` — how many slots the uses already accepted for THIS turn will hand back. The
# strategy passes it in; see UberbotStrategy.plan_turn.
#
# WHY IT IS A PARAMETER AND NOT READ OFF THE BOARD: planning runs entirely before execution,
# so at this point the rack still physically holds the items the bot has just decided to
# spend — game.gd only calls _consume_held_slot() when apply_powerup actually lands, which is
# seconds later inside _maybe_let_bot_move's pacing loop. Reading _slot_count alone therefore
# said "rack full, cannot buy" on precisely the turns the bot was emptying it, so the rack
# could never be refilled on the same turn it was used. That is a one-item-per-two-turns
# ceiling on kit throughput and it compounded with the gold floor above.
func plan_buy(color: String, freeing: int = 0):
	if engine._slot_count(color) - freeing >= game.MAX_SLOTS:
		return null
	if not _roll(P_BUY):
		return null
	var gold: int = game.player_gold[color]
	var floor_now := effective_gold_floor(color, freeing)
	var wants := _buy_weights(color)
	var affordable := []
	for item in wants.keys():
		if engine._has_in_slots(color, item):
			continue   # never hold two of the same thing — the rack is only three wide
		var cost := int(game.powerup_costs[item])
		if gold - cost < floor_now:
			continue
		if float(wants[item]) <= 0.0:
			continue
		affordable.append({"item": item, "val": float(wants[item])})
	if affordable.is_empty():
		return null
	var pick = _pick_weighted(affordable)
	if pick == null:
		return null
	return {"kind": "buy", "item": pick["item"]}

# What the bot actually needs right now, scored from the board. Zero means "do not buy".
func _buy_weights(color: String) -> Dictionary:
	var enemy := _other(color)
	var w := {
		"Ground": 1.0, "Shield": 1.0, "Phase": 1.0, "Teleport": 1.0,
		"Super Pawn": 1.0, "Capture": 1.0, "Multiply": 1.0, "Negate": 1.0, "Cheat": 0.0,
	}
	var gold: int = game.player_gold[color]

	# DEFENCE FIRST. An empty Defense rack is the single most common way this bot loses
	# material, and Ground is the cheapest insurance in the game at $3.
	var has_defense: bool = engine._has_in_slots(color, "Ground") or engine._has_in_slots(color, "Shield")
	if not has_defense:
		w["Ground"] += 5.0
		w["Shield"] += 2.5

	# THERE WAS A SHIELD BONUS HERE AND IT IS GONE WITH THE RULE IT FED. It read "Shield is the
	# only item with a use on a quiet board", which was true only while a prophylactic Defense
	# rule existed to use it — and that rule was unsound (see the block above its former home).
	# Shield is now purely reactive insurance again, which is what these two lines above already
	# price it as, so weighting it twice would just crowd out the items that do have quiet-board
	# value. Removing scaffolding when its load disappears is cheaper than discovering later
	# that the rack is full of Shields nothing is allowed to spend.

	# Multiply is $2 and pays for itself on literally any capture (see _rule_multiply).
	# It is the best gold-per-dollar item in the shop and the bot should nearly always
	# hold one.
	w["Multiply"] += 4.0

	# Negate is only ever playable on a rook or a queen (Rule A), so only buy one while we
	# still HAVE a rook or a queen for it to protect.
	var heavy := 0
	var advanced_pawn := false
	var big_enemy_target := false
	for p in game.board_state.keys():
		var pc = game.board_state[p]
		if pc["color"] == color:
			if engine._piece_value(pc) >= 5:
				heavy += 1
			if pc["type"] == "Pawn" and not pc.get("is_super_pawn", false):
				var adv: int = (6 - int(p.y)) if color == "White" else (int(p.y) - 1)
				# Priced against the RELAXED bar (superpawn_bar(true)) rather than the raw
				# baseline, because buying happens a turn before using: the item is ready=false
				# until control returns, so the shop has to anticipate the loosest bar the rule
				# might apply next turn. Judging the purchase by the strict bar was the
				# threshold mismatch that would leave the quiet-board rule with an empty rack.
				if float(adv) >= superpawn_bar(true):
					advanced_pawn = true
		elif engine._piece_value(pc) >= 5:
			big_enemy_target = true
	if heavy == 0:
		w["Negate"] = 0.0
	else:
		w["Negate"] += 1.0

	# Only buy the $10 upgrade when there is a pawn worth upgrading.
	w["Super Pawn"] = (w["Super Pawn"] + 3.0) if advanced_pawn else 0.0

	# Offensive geometry is only worth buying while the enemy still has something big for
	# it to reach.
	if big_enemy_target:
		w["Capture"] += 2.0
		w["Phase"] += 1.5
	else:
		w["Capture"] = 0.0
		w["Phase"] = 0.0

	# Teleport is an $8 escape hatch — worth it only once we own pieces worth escaping with.
	w["Teleport"] = (w["Teleport"] + 1.5) if heavy > 0 else 0.0

	# Cheat is $15 and would blow past the gold floor at any sane bank. Only when genuinely
	# rich, and only when the dial says the bot likes drama.
	if gold >= int(game.powerup_costs["Cheat"]) + gold_floor() + 6 and aggression >= 1.0:
		w["Cheat"] = 2.0 * aggression

	# The dial's last job here: a hoarder skews hard toward the cheap items, a reckless bot
	# happily reaches for the expensive ones.
	for item in w.keys():
		var price := float(game.powerup_costs[item])
		w[item] = float(w[item]) * pow(clampf(aggression, AGGRESSION_MIN, AGGRESSION_MAX), price / 8.0)
	return w


# =====================================================================
# 7. BOARD QUERIES — shared by the rules above
# =====================================================================

# Own pieces that are actually LOSING MATERIAL if left alone. "Attacked" is not enough:
# a defended knight attacked by a rook is fine, and buffing it wastes a slot. A piece
# qualifies when it is attacked AND (undefended, OR the cheapest attacker is worth less
# than the piece — i.e. the exchange loses material even after we recapture).
func _hanging_pieces(color: String, exclude: Array, legal_only: bool = false) -> Array:
	var key := color + "|" + str(exclude) + "|" + str(legal_only)
	if _hang_cache.has(key):
		return _hang_cache[key]
	var attackers := _enemy_capture_map(color, legal_only)
	var out := []
	for p in attackers.keys():
		if p in exclude:
			continue
		var pc = game.board_state[p]
		if pc["type"] == "King":
			continue
		# One modifier per piece, and Super Pawns may never receive one.
		if pc.get("is_super_pawn", false) or pc.get("modifier", "") != "":
			continue
		var val := engine._piece_value(pc)
		if not engine._is_attacked(p, color):
			out.append({"pos": p, "val": val})            # undefended — free material
		elif val > int(attackers[p]):
			out.append({"pos": p, "val": val})            # defended, but a losing exchange
	out.sort_custom(func(a, b): return a["val"] > b["val"])
	_hang_cache[key] = out
	return out

# For every square holding one of our pieces that the enemy can ACTUALLY capture this turn:
# the gold value of the cheapest piece that can take it. One pass over the enemy's real move
# lists, which is both cheaper and more correct than asking per-piece.
#
# WHY REAL MOVES AND NOT engine._is_attacked. _is_attacked is raw threat geometry and ignores
# modifiers on the ATTACKER. A Shielded enemy still guards squares by design (so it can give
# check) but game.get_legal_moves strips its captures, so it cannot actually take anything —
# and pricing threats off _is_attacked had the bot spending a Ground to save a piece nothing
# could legally capture. Conversely a Phase-buffed slider reaching THROUGH a blocker is a real
# capture that raw geometry never sees.
#
# DEFENCE is still measured with engine._is_attacked (in the caller) and that asymmetry is
# deliberate, not an oversight: "can you take me" is a question about legal moves right now,
# while "would I recapture" is a question about geometry AFTER the enemy piece lands on the
# square — which is exactly what turns a friendly pawn's diagonal into a capture it does not
# currently possess.
#
# The King is priced at 99 rather than its real value of 0. It must count as an attacker (it
# can take an undefended piece) but must never win the exchange test below (it can never take
# a defended one).
#
# `legal_only` ADDS THE KING-SAFETY FILTER, and is set by _threats_after_move whenever our own
# move gives check. Geometry alone says a pinned piece can capture, and says every piece can
# capture while its own king is in check; neither is a move the opponent may actually play.
# Filtering is done per CAPTURE rather than by routing the whole sweep through
# game.get_safe_moves, which simulates and re-scans for every candidate move of every enemy
# piece — captures are a small fraction of those, and they are the only ones this map keeps.
func _enemy_capture_map(color: String, legal_only: bool = false) -> Dictionary:
	var enemy := _other(color)
	var out := {}
	for p in game.board_state.keys():
		var pc = game.board_state[p]
		if pc["color"] != enemy:
			continue
		var v := 99 if pc["type"] == "King" else engine._piece_value(pc)
		for dest in game.get_legal_moves(p, false):
			if not game.board_state.has(dest):
				continue
			if game.board_state[dest]["color"] != color:
				continue
			if legal_only and not _capture_is_legal(p, dest, enemy):
				continue
			if not out.has(dest) or v < int(out[dest]):
				out[dest] = v
	return out

# Would `enemy` still have a safe king after playing from_pos -> to_pos? Mirrors the simulate/
# test/rewind shape of game.get_safe_moves for a single move. The board is identical on return.
func _capture_is_legal(from_pos: Vector2, to_pos: Vector2, enemy: String) -> bool:
	if not game.board_state.has(from_pos) or not game.board_state.has(to_pos):
		return false
	var mover = game.board_state[from_pos]
	var victim = game.board_state[to_pos]
	# Taking a King ends the game outright and is legal even out of check (GDD 4, path 1), so it
	# is never filtered — and a bot that lets its King be taken has a bigger problem than a slot.
	if victim["type"] == "King":
		return true
	game.board_state.erase(from_pos)
	game.board_state[to_pos] = mover
	var safe: bool = not game.is_in_check(enemy)
	game.board_state[to_pos] = victim
	game.board_state[from_pos] = mover
	return safe

# Captures a buff unlocks that plain geometry cannot reach, highest victim first, and only
# where the capturing piece is not itself taken back.
#
# NOTE (carried over from the original, still true): this uses get_legal_moves(p, false) —
# geometry only, no king-safety filter — because get_safe_moves strips Agility modifiers
# during its internal threat scans by design, so Phase/Capture geometry never shows up
# there and buffed would equal plain every time. King safety for the resulting move is
# handled by _safe_moves inside the negamax that scores the candidate.
func _captures_unlocked_by(color: String, buff_name: String) -> Array:
	var out := []
	var enemy := _other(color)
	for p in game.board_state.keys():
		var pc = game.board_state[p]
		if pc["color"] != color or pc["type"] == "King":
			continue
		if pc.get("is_super_pawn", false) or pc.get("modifier", "") != "":
			continue
		var plain: Array = game.get_legal_moves(p, false)
		pc["modifier"] = buff_name
		var buffed: Array = game.get_legal_moves(p, false)
		pc["modifier"] = ""
		for dest in buffed:
			if dest in plain or not game.board_state.has(dest):
				continue
			var victim = game.board_state[dest]
			if victim["color"] == color or victim["type"] == "King":
				continue
			if engine._is_attacked_after(p, dest, enemy):
				continue
			out.append({"from": p, "to": dest, "victim": engine._piece_value(victim)})
	out.sort_custom(func(a, b): return a["victim"] > b["victim"])
	return out

# One safe empty square a Teleport could put `from_pos` on, or null. Same geometry-only
# reasoning as _captures_unlocked_by.
func _safe_teleport_landing(from_pos: Vector2, enemy: String):
	var pc = game.board_state[from_pos]
	pc["modifier"] = "Teleport"
	var dests: Array = game.get_legal_moves(from_pos, false)
	pc["modifier"] = ""
	if dests.is_empty():
		return null
	dests.shuffle()
	for d in dests:
		if not engine._is_attacked_after(from_pos, d, enemy):
			return d
	return null

func _pick_weighted(cands: Array):
	if cands.is_empty():
		return null
	var total := 0.0
	for c in cands:
		total += float(c["val"])
	if total <= 0.0:
		return cands[rng.randi() % cands.size()]
	var r := rng.randf() * total
	for c in cands:
		r -= float(c["val"])
		if r <= 0.0:
			return c
	return cands[cands.size() - 1]
