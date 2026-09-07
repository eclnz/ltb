package ui

import "core:unicode/utf8"
import mu "vendor:microui"
import rl "vendor:raylib"

/*
A raylib backend for microui.

	m: ui.Micro
	ui.micro_init(&m)
	defer ui.micro_destroy(&m)

	for !rl.WindowShouldClose() {
		ui.micro_begin(&m)
		if mu.window(&m.ctx, "Layers", {10, 10, 220, 300}) {
			mu.layout_row(&m.ctx, {-1}, 0)
			if .SUBMIT in mu.button(&m.ctx, "Reload") {
				reload()
			}
			mu.slider(&m.ctx, &exaggeration, 1, 8)
		}
		rl.BeginDrawing()
		render_world()
		ui.micro_end(&m) // must be inside BeginDrawing/EndDrawing
		rl.EndDrawing()
	}

This complements `panel.odin` rather than replacing it. The panels there are
readouts the viewer computes every frame -- legends, colour ramps, the scale
bar -- and they lay themselves out from their contents. microui is for the
things a panel cannot be: buttons, sliders, checkboxes, text entry, scrollable
and draggable windows, anything that has to hold state between frames.

microui itself draws nothing. It walks its widget tree into a command list, and
everything below is the translation of that list into raylib calls, plus the
input pump that feeds it.
*/

Micro :: struct {
	ctx: mu.Context,
	// microui's bundled 128x128 atlas, holding both the font and the five
	// widget icons. Uploaded once at init.
	atlas:    rl.Texture2D,
	// Whether a scissor is currently open, so `micro_end` can close it. raylib
	// has no "query the scissor" call, and leaving one open would clip whatever
	// the viewer draws next.
	clipping: bool,
}

micro_init :: proc(m: ^Micro) {
	mu.init(&m.ctx, set_clipboard = micro_set_clipboard, get_clipboard = micro_get_clipboard)
	m.ctx.text_width = mu.default_atlas_text_width
	m.ctx.text_height = mu.default_atlas_text_height

	// The atlas ships as one alpha byte per pixel. Expand it to RGBA with a
	// white base so raylib's per-draw tint carries the colour microui asked for.
	pixels := make([][4]u8, mu.DEFAULT_ATLAS_WIDTH * mu.DEFAULT_ATLAS_HEIGHT, context.temp_allocator)
	for alpha, i in mu.default_atlas_alpha {
		pixels[i] = {255, 255, 255, alpha}
	}
	image := rl.Image {
		data    = raw_data(pixels),
		width   = mu.DEFAULT_ATLAS_WIDTH,
		height  = mu.DEFAULT_ATLAS_HEIGHT,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	m.atlas = rl.LoadTextureFromImage(image)
}

micro_destroy :: proc(m: ^Micro) {
	rl.UnloadTexture(m.atlas)
	m.atlas = {}
}

// Feeds a frame of raylib input to microui and opens the widget pass. Every
// `mu.*` widget call belongs between this and `micro_end`.
micro_begin :: proc(m: ^Micro) {
	micro_input(m)
	mu.begin(&m.ctx)
}

// Closes the widget pass and draws it. Call inside raylib's
// BeginDrawing/EndDrawing, after the world, so the interface lands on top.
micro_end :: proc(m: ^Micro) {
	mu.end(&m.ctx)
	micro_draw(m)
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

@(private)
MOUSE_BUTTONS :: [?]struct {
	rl: rl.MouseButton,
	mu: mu.Mouse,
}{{.LEFT, .LEFT}, {.RIGHT, .RIGHT}, {.MIDDLE, .MIDDLE}}

// raylib keys microui cares about. Both shift and control sides map onto the
// one modifier, because microui's textbox only asks whether the chord is held.
@(private)
KEYS :: [?]struct {
	rl: rl.KeyboardKey,
	mu: mu.Key,
}{
	{.LEFT_SHIFT, .SHIFT},
	{.RIGHT_SHIFT, .SHIFT},
	{.LEFT_CONTROL, .CTRL},
	{.RIGHT_CONTROL, .CTRL},
	{.LEFT_SUPER, .CTRL}, // macOS chords the textbox would otherwise miss
	{.RIGHT_SUPER, .CTRL},
	{.LEFT_ALT, .ALT},
	{.RIGHT_ALT, .ALT},
	{.BACKSPACE, .BACKSPACE},
	{.DELETE, .DELETE},
	{.ENTER, .RETURN},
	{.KP_ENTER, .RETURN},
	{.LEFT, .LEFT},
	{.RIGHT, .RIGHT},
	{.HOME, .HOME},
	{.END, .END},
	{.A, .A},
	{.X, .X},
	{.C, .C},
	{.V, .V},
}

@(private)
micro_input :: proc(m: ^Micro) {
	pos := rl.GetMousePosition()
	mu.input_mouse_move(&m.ctx, i32(pos.x), i32(pos.y))

	// microui scrolls by pixels; raylib reports notches.
	wheel := rl.GetMouseWheelMoveV()
	if wheel.x != 0 || wheel.y != 0 {
		mu.input_scroll(&m.ctx, i32(-wheel.x * 30), i32(-wheel.y * 30))
	}

	buttons := MOUSE_BUTTONS
	for b in buttons {
		if rl.IsMouseButtonPressed(b.rl) {
			mu.input_mouse_down(&m.ctx, i32(pos.x), i32(pos.y), b.mu)
		}
		if rl.IsMouseButtonReleased(b.rl) {
			mu.input_mouse_up(&m.ctx, i32(pos.x), i32(pos.y), b.mu)
		}
	}

	keys := KEYS
	for k in keys {
		// Repeats matter here: holding backspace in a textbox should keep
		// deleting rather than stopping after one character.
		if rl.IsKeyPressed(k.rl) || rl.IsKeyPressedRepeat(k.rl) {
			mu.input_key_down(&m.ctx, k.mu)
		}
		if rl.IsKeyReleased(k.rl) {
			mu.input_key_up(&m.ctx, k.mu)
		}
	}

	// Typed characters arrive already decoded by the platform layer, so this is
	// the only path that handles anything above ASCII correctly.
	for ch := rl.GetCharPressed(); ch != 0; ch = rl.GetCharPressed() {
		encoded, width := utf8.encode_rune(ch)
		mu.input_text(&m.ctx, string(encoded[:width]))
	}
}

@(private)
micro_set_clipboard :: proc(user_data: rawptr, text: string) -> (ok: bool) {
	// raylib's setter needs a terminated string and does not keep the pointer.
	buf: [512]u8
	if len(text) >= len(buf) {
		return false
	}
	copy(buf[:], text)
	buf[len(text)] = 0
	rl.SetClipboardText(cstring(&buf[0]))
	return true
}

@(private)
micro_get_clipboard :: proc(user_data: rawptr) -> (text: string, ok: bool) {
	c := rl.GetClipboardText()
	if c == nil {
		return "", false
	}
	return string(c), true
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

@(private)
micro_color :: #force_inline proc "contextless" (c: mu.Color) -> rl.Color {
	return {c.r, c.g, c.b, c.a}
}

@(private)
micro_draw :: proc(m: ^Micro) {
	command: ^mu.Command
	for variant in mu.next_command_iterator(&m.ctx, &command) {
		switch cmd in variant {
		case ^mu.Command_Rect:
			rl.DrawRectangle(cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h, micro_color(cmd.color))

		case ^mu.Command_Text:
			// One atlas glyph per rune, advancing by the glyph's own width.
			// Anything the 128-entry atlas has no glyph for is drawn as the
			// character at 127 rather than dropped, so missing coverage is
			// visible instead of silently blank.
			x := cmd.pos.x
			for ch in cmd.str {
				src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + min(int(ch), 127)]
				micro_blit(m, src, {x, cmd.pos.y}, cmd.color)
				x += src.w
			}

		case ^mu.Command_Icon:
			src := mu.default_atlas[cmd.id]
			micro_blit(
				m,
				src,
				{
					cmd.rect.x + (cmd.rect.w - src.w) / 2,
					cmd.rect.y + (cmd.rect.h - src.h) / 2,
				},
				cmd.color,
			)

		case ^mu.Command_Clip:
			if m.clipping {
				rl.EndScissorMode()
			}
			rl.BeginScissorMode(cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h)
			m.clipping = true

		case ^mu.Command_Jump:
			// The iterator follows jumps itself; nothing to draw.
		}
	}

	if m.clipping {
		rl.EndScissorMode()
		m.clipping = false
	}
}

@(private)
micro_blit :: proc(m: ^Micro, src: mu.Rect, pos: mu.Vec2, color: mu.Color) {
	rl.DrawTextureRec(
		m.atlas,
		{f32(src.x), f32(src.y), f32(src.w), f32(src.h)},
		{f32(pos.x), f32(pos.y)},
		micro_color(color),
	)
}
