class_name FXPlayer
extends Node2D

# =============================================================================
# fx.gd — THE EFFECTS PLAYER (GDD Section 6)
#
# One node, one entry point. game.gd calls fx.play("check", square) and knows
# nothing about tweens, rings or timing. Every future effect is a new branch in
# _cast() plus (eventually) its own scene under res://fx/ — game.gd is already
# 3,000 lines and animation code must not grow inside it.
#
# THE THREE PROBLEMS (6.1), and where each lives here:
#   (a) CAST   — the instant it happens. One-shot, fire-and-forget: play().
#   (b) STATE  — "this is true RIGHT NOW". Persistent, drawn every frame by this
#                node's own _draw(): hold_check() / clear_check().
#   (c) PAYOFF — the moment a rule pays out. Not yet built; see 6.4.
#
# WHY THE STATE LAYER LIVES IN THIS NODE'S _draw() AND NOT ON THE PIECE.
# game.update_visuals() frees and rebuilds every piece node on each redraw (any
# child with a Sprite2D, named Piece*, or in dynamic_overlay). Anything attached
# to a piece therefore evaporates at the next repaint, which for a persistent
# "you are still in check" marker is exactly wrong. This node is not caught by
# that sweep, so it draws the marker itself and looks the king's square up fresh
# every frame — which also means it follows the king when it moves and survives
# a board flip for free.
#
# TIMING (6.5). The bot's turn is a fixed 4s wall clock and FX must fit in the
# gaps, never extend them: cast <= 0.5s, payoff <= 0.4s, Uber cast <= 0.8s.
# play() is deliberately fire-and-forget for this reason — nothing here blocks a
# turn. play_awaited() exists for beats that genuinely must gate one, and should
# stay rare.
# =============================================================================

# FX intensity, mirrored from GameConfig.FXMode. REDUCED keeps the state layer
# (which carries information) and guts the cast beats (which carry drama); OFF
# is silent. Shipped from day one per 6.5 rather than bolted on later.
enum Mode { FULL, REDUCED, OFF }
var mode: int = Mode.FULL

# The Game node. fx asks it for board->screen mapping and piece lookup, nothing
# else — this is a one-way dependency and should stay one.
var game = null

# EVERY colour used by an effect comes from here, and Section 7 (Themes) will own
# this dict outright — a red that reads on the rainbow board and vanishes on a
# walnut one is a silently broken feedback system. Until ThemeManager exists,
# these are the defaults; call set_palette() to override.
var palette := {
	"check": Color(1.0, 0.23, 0.28),
	"dust":  Color(0.93, 0.90, 0.82),
	"shadow": Color(0.0, 0.0, 0.0, 0.42),
}

# --- KNIGHT LEAP tunables (6.8) ---
# Total awaited time is FLIGHT + SQUASH + RECOVER = 0.60s at FULL, against the 0.22s
# a slide costs. That difference is paid on the bot's TERMINAL action, which is
# anchored at the 4s deadline and whose animation has always run past it — so the
# turn budget in 6.5 is unaffected. Do not let this grow much past 0.6s.
const LEAP_FLIGHT := 0.40
const LEAP_SQUASH := 0.05
const LEAP_RECOVER := 0.15
const LEAP_FLIPS := 2          # full rotations in the air
const LEAP_APEX := 1.15        # peak height, x TILE_SIZE

# --- persistent state: check -------------------------------------------------
var _check_color := ""      # "" = nobody is in check
var _pulse_t := 0.0

const RING_SEGMENTS := 48


func _init() -> void:
	# Above the board and the pieces, below the Shield bubbles (z 5) so a shielded
	# king in check still reads as shielded first.
	z_index = 4


func _ready() -> void:
	var cfg = get_node_or_null("/root/GameConfig")
	if cfg != null and "fx_mode" in cfg:
		mode = int(cfg.fx_mode)
	set_process(false)


func set_palette(p: Dictionary) -> void:
	for k in p.keys():
		palette[k] = p[k]


# Duration multiplier for the current mode. REDUCED does not SKIP the cast — a
# beat that vanishes entirely teaches nothing — it just gets out of the way fast.
func _scale() -> float:
	return 0.3 if mode == Mode.REDUCED else 1.0


func _col(key: String) -> Color:
	return palette.get(key, Color.WHITE)


# =============================================================================
# PUBLIC API (GDD 6.2)
# =============================================================================

# Fire a one-shot cast beat at a board square. Never blocks; safe to call from
# inside a turn.
func play(effect: String, board_pos, opts := {}) -> void:
	if mode == Mode.OFF or game == null or board_pos == null:
		return
	match effect:
		"check":
			_cast_check(board_pos, opts)
		_:
			push_warning("fx.play: unknown effect '%s'" % effect)


# Awaitable — for a beat that must gate the turn, which for movement it must: the
# board mutates the moment this returns. Keep this list short (6.5).
func play_awaited(effect: String, board_pos, opts := {}) -> void:
	if mode == Mode.OFF or game == null or board_pos == null:
		return
	match effect:
		"knight_leap":
			await _knight_leap(opts.get("from"), board_pos, opts.get("node"))
		_:
			play(effect, board_pos, opts)
			await get_tree().create_timer(0.45 * _scale()).timeout


# How long the TRAVEL portion of an effect takes, so game.gd can line other beats up
# with the moment of arrival — a knight's victim should be crushed on impact, not
# quietly gone while the knight is still mid-air.
func travel_time(effect: String) -> float:
	if effect == "knight_leap":
		return LEAP_FLIGHT * _scale()
	return 0.0


# --- persistent state --------------------------------------------------------

# "This side is in check right now." Idempotent: calling it every turn is fine.
func hold_check(color: String) -> void:
	if mode == Mode.OFF:
		clear_check()
		return
	if _check_color != color:
		_pulse_t = 0.0
	_check_color = color
	set_process(true)
	queue_redraw()


func clear_check() -> void:
	if _check_color == "":
		return
	_check_color = ""
	set_process(false)
	queue_redraw()


# Drop everything: match reset, resignation, scene teardown.
func clear_all() -> void:
	clear_check()
	for c in get_children():
		c.queue_free()


# =============================================================================
# THE CHECK ALERT
# =============================================================================
# A loud hit, then a quiet hold. The hit says "it just happened", the hold says
# "it is still true" — a player who glances away and looks back must still be
# able to see that their king is under attack, which a one-shot cannot do.
#
# No screen-space effect here on purpose. GDD 6.3 reserves full-screen treatment
# for the Uber class; spending it on check would flatten the one moment that is
# supposed to feel bigger than everything else.
func _cast_check(sq: Vector2, _opts: Dictionary) -> void:
	var center: Vector2 = game._square_center(sq)
	var tile: float = float(game.TILE_SIZE)
	var s := _scale()
	var col: Color = _col("check")

	# Two rings, staggered, punching outward from the square.
	for i in range(2):
		var ring := RingBurst.new()
		ring.color = col
		ring.width = 5.0 - i * 1.5
		ring.position = center
		ring.radius = tile * 0.26
		add_child(ring)

		var grow := 0.40 * s
		var t := create_tween()
		if i > 0:
			t.tween_interval(0.09 * s)
		t.tween_method(ring.set_radius, tile * 0.26, tile * (0.66 + i * 0.10), grow) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		t.parallel().tween_property(ring, "modulate:a", 0.0, grow) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		t.tween_callback(ring.queue_free)

	_jolt_king(sq, s)


# The physical thunk. Shakes the actual piece node rather than a ghost, and binds
# the tween TO that node: game.update_visuals() may free and rebuild the piece
# mid-shake, and a node-bound tween dies with its node instead of writing to a
# freed object. The rebuilt piece simply appears at rest, which is the correct
# fallback — never an error, never a piece stranded off-centre.
func _jolt_king(sq: Vector2, s: float) -> void:
	var piece = game._piece_node_at(sq)
	if piece == null:
		return

	var home: Vector2 = piece.position
	var shake: Tween = piece.create_tween()
	var step := 0.045 * s
	for i in range(4):
		var amp: float = 9.0 * (1.0 - float(i) / 4.0)
		shake.tween_property(piece, "position", home + Vector2(amp, 0), step) \
			.set_trans(Tween.TRANS_SINE)
		shake.tween_property(piece, "position", home - Vector2(amp, 0), step) \
			.set_trans(Tween.TRANS_SINE)
	shake.tween_property(piece, "position", home, step)

	var spr = piece.get_node_or_null("Sprite2D")
	if spr != null:
		var s0: Vector2 = spr.scale
		var punch: Tween = piece.create_tween()
		punch.tween_property(spr, "scale", s0 * 1.13, 0.09 * s) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		punch.tween_property(spr, "scale", s0, 0.26 * s) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


# =============================================================================
# THE PERSISTENT LAYER
# =============================================================================

func _process(delta: float) -> void:
	_pulse_t += delta
	queue_redraw()


func _draw() -> void:
	if _check_color == "" or game == null:
		return
	var sq = game._find_king(_check_color)
	if sq == null:
		return   # king already captured; the match is over and _finish_turn will clear us
	var center: Vector2 = game._square_center(sq)
	var tile: float = float(game.TILE_SIZE)

	# ~0.9 Hz breathing. Slow enough to read as a state rather than an alarm, which
	# is the difference between "you are in check" and "something is broken".
	var wave: float = 0.5 + 0.5 * sin(_pulse_t * TAU * 0.9)
	var col: Color = _col("check")

	# Soft interior wash, then the hard rim. The wash carries at a glance across a
	# busy rainbow board; the rim is what actually draws the eye to the square.
	var fill := col
	fill.a = 0.10 + 0.07 * wave
	draw_circle(center, tile * 0.46, fill)

	var rim := col
	rim.a = 0.45 + 0.35 * wave
	draw_arc(center, tile * 0.44, 0, TAU, RING_SEGMENTS, rim, 3.0 + 1.5 * wave, true)


# =============================================================================
# THE KNIGHT LEAP (GDD 6.8)
# =============================================================================
# Every other piece slides. The knight is the only one that JUMPS OVER things, and
# a flat slide is the one animation that actively contradicts its rule — so it
# vaults: a parabolic arc, two full front-flips, and a heavy landing.
#
# The flip direction follows travel (clockwise moving right), so it reads as
# tumbling FORWARD rather than spinning in place. A ground shadow shrinks and
# fades under it: without one the arc reads as "drifting up the screen" rather
# than "leaving the board", and it is the cheapest possible sell of height.
#
# `ghost` is the animation ghost game.gd already makes for every move. fx never
# creates piece art — it does not know where the sprites live and should not.
func _knight_leap(from_sq, to_sq, ghost) -> void:
	if ghost == null or not is_instance_valid(ghost) or from_sq == null:
		return
	var a: Vector2 = game._square_center(from_sq)
	var b: Vector2 = game._square_center(to_sq)
	var tile: float = float(game.TILE_SIZE)
	var s := _scale()
	var apex: float = tile * LEAP_APEX
	# Godot screen space is y-down, so a positive angle is clockwise = forward when
	# travelling right. Moving left, flip the sign or it tumbles backwards.
	var spin: float = TAU * LEAP_FLIPS * (1.0 if b.x >= a.x else -1.0)

	var shadow := GroundEllipse.new()
	shadow.color = _col("shadow")
	shadow.rx = tile * 0.30
	shadow.ry = tile * 0.11
	shadow.z_index = -1
	add_child(shadow)

	var spr = ghost.get_node_or_null("Sprite2D")
	var base_scale: Vector2 = spr.scale if spr != null else Vector2.ONE

	# Horizontal speed and spin are both LINEAR — that is what a real tumble does.
	# All the arc lives in the height term.
	var t := create_tween()
	t.tween_method(func(k: float) -> void:
			if not is_instance_valid(ghost):
				return
			var ground: Vector2 = a.lerp(b, k)
			var hn: float = 4.0 * k * (1.0 - k)      # 0 -> 1 -> 0, peak at midpoint
			ghost.position = ground - Vector2(0, apex * hn)
			ghost.rotation = spin * k
			if is_instance_valid(shadow):
				shadow.position = ground + Vector2(0, tile * 0.30)
				shadow.scale = Vector2.ONE * (1.0 - 0.45 * hn)
				shadow.modulate.a = 1.0 - 0.55 * hn,
		0.0, 1.0, LEAP_FLIGHT * s)
	await t.finished

	if is_instance_valid(shadow):
		shadow.queue_free()
	if not is_instance_valid(ghost):
		return

	# --- THE CRASH ---
	ghost.position = b
	ghost.rotation = 0.0
	_leap_impact(b, tile, s)

	if spr == null:
		await get_tree().create_timer((LEAP_SQUASH + LEAP_RECOVER) * s).timeout
		return

	# Squash on contact, then an elastic recovery. The ghost also dips a few pixels so
	# the squash reads as weight driving into the square rather than the piece merely
	# getting shorter — the sprite is centre-origin, so scaling alone lifts its feet.
	var land := create_tween()
	land.tween_property(spr, "scale", Vector2(base_scale.x * 1.30, base_scale.y * 0.66), LEAP_SQUASH * s) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	land.parallel().tween_property(ghost, "position", b + Vector2(0, tile * 0.07), LEAP_SQUASH * s)
	land.tween_property(spr, "scale", base_scale, LEAP_RECOVER * s) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	land.parallel().tween_property(ghost, "position", b, LEAP_RECOVER * s) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await land.finished


# Dust ring plus debris. Both are flattened to the ground plane (scale.y ~0.38) so
# the impact reads as happening ON the board rather than in the air above it.
func _leap_impact(center: Vector2, tile: float, s: float) -> void:
	var dust: Color = _col("dust")

	var ring := RingBurst.new()
	ring.color = dust
	ring.width = 4.0
	ring.position = center + Vector2(0, tile * 0.26)
	ring.scale = Vector2(1.0, 0.38)
	ring.radius = tile * 0.16
	add_child(ring)
	var rt := create_tween()
	rt.tween_method(ring.set_radius, tile * 0.16, tile * 0.72, 0.26 * s) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	rt.parallel().tween_property(ring, "modulate:a", 0.0, 0.26 * s)
	rt.tween_callback(ring.queue_free)

	# Six specks thrown outward and slightly up, then pulled down. Cheap, and it is
	# what turns a landing into a crash.
	for i in range(6):
		var speck := Speck.new()
		speck.color = dust
		speck.r = 2.0 + float(i % 3)
		speck.position = center + Vector2(0, tile * 0.26)
		add_child(speck)
		var ang: float = -PI * (0.15 + 0.7 * (float(i) / 5.0))   # fan upward
		var dir := Vector2(cos(ang), sin(ang) * 0.55)
		var dist: float = tile * (0.30 + 0.22 * float(i % 3))
		var start: Vector2 = speck.position
		var life: float = 0.30 * s
		var st := create_tween()
		st.tween_method(func(k: float) -> void:
				if is_instance_valid(speck):
					speck.position = start + dir * dist * k + Vector2(0, tile * 0.42 * k * k),
			0.0, 1.0, life)
		st.parallel().tween_property(speck, "modulate:a", 0.0, life) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		st.tween_callback(speck.queue_free)


# =============================================================================
# An expanding ring. Inner class rather than a scene while there is exactly one
# user of it; it moves to res://fx/ring_burst.tscn as soon as a second effect
# wants it (6.2).
# =============================================================================
class RingBurst extends Node2D:
	var radius := 1.0
	var color := Color.WHITE
	var width := 4.0

	func set_radius(r: float) -> void:
		radius = r
		queue_redraw()

	func _draw() -> void:
		draw_arc(Vector2.ZERO, maxf(radius, 0.1), 0, TAU, 48, color, width, true)


# A flattened ellipse on the ground plane: the in-flight shadow. draw_set_transform
# does the squash so the node's own scale stays free for the shrink tween.
class GroundEllipse extends Node2D:
	var rx := 20.0
	var ry := 8.0
	var color := Color(0, 0, 0, 0.4)

	func _draw() -> void:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, ry / maxf(rx, 0.01)))
		draw_circle(Vector2.ZERO, rx, color)


# One piece of landing debris.
class Speck extends Node2D:
	var r := 3.0
	var color := Color.WHITE

	func _draw() -> void:
		draw_circle(Vector2.ZERO, r, color)
