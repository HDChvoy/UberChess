extends Control

# Main menu for ÜberChess — set as the project's Main Scene. Requires the GameConfig
# autoload (see GameConfig.gd for setup): the menu writes the player's choices into
# GameConfig, then loads the board scene; game.gd reads them back in _ready().
# Three pages toggled by visibility (Main / Local / Difficulty), each its own
# full-rect CenterContainer so it centers independently.

# Board scene the play buttons load. Match your actual filename/capitalization.
const GAME_SCENE_PATH := "res://Game.tscn"

var _main_page: CenterContainer
var _local_page: CenterContainer
var _difficulty_page: CenterContainer

func _ready():
	# Make the root fill the whole window so the centered layout actually centers.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Full-screen dark background.
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.09, 0.12)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Soft, dimmed chessboard backdrop — mirrors the multiplayer lobby's darkened-board
	# mood. Added after bg and before the pages, so it sits behind the (crisp) menu UI.
	add_child(_build_board_backdrop())

	# Build the three pages. Each is a full-rect CenterContainer, so whichever one is
	# visible centers itself in the window on its own.
	_main_page = _build_main_page()
	_local_page = _build_local_page()
	_difficulty_page = _build_difficulty_page()
	add_child(_main_page)
	add_child(_local_page)
	add_child(_difficulty_page)
	_show(_main_page)

# Builds a soft, dimmed chessboard that sits behind the menu — the same darkened-board
# mood as the multiplayer lobby, rendered here as a blurred backdrop since the menu scene
# has no live board. Light/dark squares match draw_board() in game.gd (WHITE / DIM_GRAY).
func _build_board_backdrop() -> TextureRect:
	# Bake an 8x8 checker into a 512px texture (64px squares); the shader does the blur.
	var squares := 8
	var cell := 64
	var tex_size := squares * cell
	var img := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBA8)
	for sy in squares:
		for sx in squares:
			var col := Color.WHITE if (sx + sy) % 2 == 0 else Color.DIM_GRAY
			img.fill_rect(Rect2i(sx * cell, sy * cell, cell, cell), col)
	var tex := ImageTexture.create_from_image(img)

	var rect := TextureRect.new()
	rect.texture = tex
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	rect.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE  # never intercept menu clicks

	# A small binomial (1 4 6 4 1) blur over the board texture, then dimmed toward the
	# menu's dark background so it reads as ambience rather than the focal point.
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;

uniform float blur_radius : hint_range(0.0, 24.0) = 4.0;
uniform float dim : hint_range(0.0, 1.0) = 0.45;
uniform vec3 dim_color : source_color = vec3(0.06, 0.07, 0.10);

void fragment() {
	vec2 ps = TEXTURE_PIXEL_SIZE * blur_radius;
	float k[5] = {0.0625, 0.25, 0.375, 0.25, 0.0625}; // binomial weights
	vec4 sum = vec4(0.0);
	for (int yy = 0; yy < 5; yy++) {
		for (int xx = 0; xx < 5; xx++) {
			vec2 off = vec2(float(xx - 2), float(yy - 2)) * ps;
			sum += texture(TEXTURE, UV + off) * (k[xx] * k[yy]);
		}
	}
	vec3 rgb = mix(sum.rgb, dim_color, dim);
	COLOR = vec4(rgb, 1.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("blur_radius", 4.0)
	mat.set_shader_parameter("dim", 0.45)
	mat.set_shader_parameter("dim_color", Color(0.06, 0.07, 0.10))
	rect.material = mat
	return rect

# Wraps a VBox of buttons in a full-rect CenterContainer.
func _page_wrapper(col: VBoxContainer) -> CenterContainer:
	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cc.add_child(col)
	return cc

func _new_column() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	return col

# --- PAGE 1: MAIN MENU ---
func _build_main_page() -> CenterContainer:
	var col := _new_column()

	var title := Label.new()
	title.text = "ÜBERCHESS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 84)
	col.add_child(title)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 24)
	col.add_child(spacer)

	col.add_child(_make_button("Play Local", _on_show_local))
	col.add_child(_make_button("Multiplayer", _on_multiplayer_pressed))
	col.add_child(_make_button("Options", _on_options_pressed))
	col.add_child(_make_button("Credits", _on_credits_pressed))
	col.add_child(_make_button("Quit", _on_quit_pressed))
	return _page_wrapper(col)

# --- PAGE 2: LOCAL PLAY (2-player vs bot) ---
func _build_local_page() -> CenterContainer:
	var col := _new_column()

	var heading := Label.new()
	heading.text = "Play Local"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 64)
	col.add_child(heading)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 24)
	col.add_child(spacer)

	col.add_child(_make_button("Play 2-Player", _on_two_player_pressed))
	col.add_child(_make_button("Play Über Bot", _on_show_difficulty))

	var back_spacer := Control.new()
	back_spacer.custom_minimum_size = Vector2(0, 18)
	col.add_child(back_spacer)
	col.add_child(_make_button("\u2190 Back", _on_show_main))
	return _page_wrapper(col)

# --- PAGE 3: BOT DIFFICULTY SELECT ---
func _build_difficulty_page() -> CenterContainer:
	var col := _new_column()

	var heading := Label.new()
	heading.text = "Select Difficulty"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 56)
	col.add_child(heading)

	var note := Label.new()
	note.text = "Sides are chosen at random each game."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_font_size_override("font_size", 18)
	note.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	col.add_child(note)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 18)
	col.add_child(spacer)

	col.add_child(_make_button("Easy", _on_difficulty_pressed.bind(GameConfig.Difficulty.EASY)))
	col.add_child(_make_button("Normal", _on_difficulty_pressed.bind(GameConfig.Difficulty.NORMAL)))
	col.add_child(_make_button("Hard", _on_difficulty_pressed.bind(GameConfig.Difficulty.HARD)))
	col.add_child(_make_button("\u00dcber", _on_difficulty_pressed.bind(GameConfig.Difficulty.UBER)))

	var back_spacer := Control.new()
	back_spacer.custom_minimum_size = Vector2(0, 18)
	col.add_child(back_spacer)
	col.add_child(_make_button("\u2190 Back", _on_show_local))
	return _page_wrapper(col)

# --- PAGE SWITCHING ---
# Shows exactly one page and hides the others.
func _show(page: CenterContainer) -> void:
	_main_page.visible = (page == _main_page)
	_local_page.visible = (page == _local_page)
	_difficulty_page.visible = (page == _difficulty_page)

func _on_show_main() -> void:
	_show(_main_page)

func _on_show_local() -> void:
	_show(_local_page)

func _on_show_difficulty() -> void:
	_show(_difficulty_page)

# Builds one menu button with consistent sizing/font and wires its pressed signal.
func _make_button(label: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(320, 56)
	b.add_theme_font_size_override("font_size", 26)
	b.pressed.connect(handler)
	return b

# --- ACTION HANDLERS ---

func _on_two_player_pressed():
	# Local hot-seat: both players share the device. Reset all match config to 2P.
	GameConfig.set_two_player()
	get_tree().change_scene_to_file(GAME_SCENE_PATH)

func _on_difficulty_pressed(diff: GameConfig.Difficulty):
	# Configure a bot match at this tier and randomize sides, then load the board.
	GameConfig.set_vs_bot(diff)
	get_tree().change_scene_to_file(GAME_SCENE_PATH)

func _on_multiplayer_pressed():
	# Online multiplayer (Phase 1 WebSocket relay). Flag the match as multiplayer and
	# load the board; game.gd reads is_multiplayer() in _ready(), opens the relay
	# connection, and shows the create/join lobby before play starts.
	GameConfig.set_multiplayer()
	get_tree().change_scene_to_file(GAME_SCENE_PATH)

func _on_options_pressed():
	# TODO: options panel (sound, board theme, etc.).
	print("[Menu] Options screen not built yet.")

func _on_credits_pressed():
	# TODO: credits panel.
	print("[Menu] Credits screen not built yet.")

func _on_quit_pressed():
	get_tree().quit()
