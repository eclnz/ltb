package ui

import "core:strings"
import rl "vendor:raylib"

// Re-exported so that code drawing chrome talks to this package and not to
// raylib. A viewer file that imports raylib is drawing something this package
// should have been asked for.
Color :: rl.Color
Rectangle :: rl.Rectangle
Vec2 :: rl.Vector2

screen_width :: proc() -> i32 {
	return rl.GetScreenWidth()
}

screen_height :: proc() -> i32 {
	return rl.GetScreenHeight()
}

mouse :: proc() -> Vec2 {
	return rl.GetMousePosition()
}

fps :: proc() -> i32 {
	return rl.GetFPS()
}

// ---------------------------------------------------------------------------
// Text
//
// raylib wants a cstring and a position. Everything above this file works in
// `string` and in the six sizes the theme names, so the conversion happens once,
// here, on the temporary allocator the frame already frees.
// ---------------------------------------------------------------------------

@(private)
cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

text_width :: proc(s: string, size: i32) -> i32 {
	return rl.MeasureText(cstr(s), size)
}

text :: proc(s: string, x, y: i32, size: i32 = LABEL, color := TEXT_DIM) {
	rl.DrawText(cstr(s), x, y, size, color)
}

// Centred on `cx` rather than left-aligned at it.
text_centered :: proc(s: string, cx, y: i32, size: i32 = LABEL, color := TEXT_DIM) {
	c := cstr(s)
	rl.DrawText(c, cx - rl.MeasureText(c, size) / 2, y, size, color)
}

// Right edge of the text sits at `right`.
text_right :: proc(s: string, right, y: i32, size: i32 = LABEL, color := TEXT_DIM) {
	c := cstr(s)
	rl.DrawText(c, right - rl.MeasureText(c, size), y, size, color)
}

// Centred in the window, for the messages that replace the map entirely.
text_screen_centered :: proc(s: string, y: i32, size: i32 = LABEL, color := TEXT_DIM) {
	text_centered(s, rl.GetScreenWidth() / 2, y, size, color)
}

// ---------------------------------------------------------------------------
// Boxes
// ---------------------------------------------------------------------------

rect :: proc(x, y, w, h: i32) -> rl.Rectangle {
	return rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
}

fill :: proc(r: rl.Rectangle, color: rl.Color) {
	rl.DrawRectangleRec(r, color)
}

outline :: proc(r: rl.Rectangle, color := BORDER, thickness: f32 = 1) {
	rl.DrawRectangleLinesEx(r, thickness, color)
}

// A filled box with a border: the shape every drop-down and modal is made of.
frame :: proc(r: rl.Rectangle, bg := SURFACE, border := BORDER) {
	fill(r, bg)
	outline(r, border)
}

// Dims the whole window. Call before drawing a modal on top of it.
scrim :: proc() {
	rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), SCRIM)
}

hovered :: proc(r: rl.Rectangle, mouse: rl.Vector2) -> bool {
	return rl.CheckCollisionPointRec(mouse, r)
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

// Draws a button. Hit testing stays with the caller, because the browser lays
// out, handles input and draws in three separate passes.
button :: proc(r: rl.Rectangle, label: string, is_hovered, enabled: bool) {
	fill(r, enabled && is_hovered ? HIGHLIGHT : CONTROL)
	outline(r, CONTROL_BORDER)
	text_centered(
		label,
		i32(r.x + r.width * 0.5),
		i32(r.y + r.height * 0.5) - LABEL / 2,
		LABEL,
		enabled ? TEXT : TEXT_OFF,
	)
}

// ---------------------------------------------------------------------------
// Scrolling lists
// ---------------------------------------------------------------------------

// How each row of a list reads. A callback rather than a slice of strings so
// that a caller can colour rows by whatever it knows about them -- a directory,
// a disabled entry -- without this package having to know what those are.
Label_Proc :: proc(index: int, user: rawptr) -> (text: string, color: rl.Color)

// Rows that fit in a list of this size.
list_rows :: proc(r: rl.Rectangle) -> int {
	return max(1, int(r.height / ROW_H))
}

// Index under the mouse, or -1. Pairs with `list` so that the row a click lands
// on is the row that was drawn there.
list_row_at :: proc(r: rl.Rectangle, mouse: rl.Vector2, scroll, count: int) -> int {
	if !hovered(r, mouse) {
		return -1
	}
	row := scroll + int((mouse.y - r.y) / ROW_H)
	return row >= 0 && row < count ? row : -1
}

// A scrolling, selectable list of `count` rows clipped to `r`, with a scrollbar
// when there is more than one screenful.
list :: proc(
	r: rl.Rectangle,
	count: int,
	selected, scroll: int,
	mouse: rl.Vector2,
	label: Label_Proc,
	user: rawptr = nil,
) {
	frame(r, FIELD, BORDER_DIM)

	rows := list_rows(r)
	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	defer rl.EndScissorMode()

	for i in scroll ..< min(scroll + rows, count) {
		row := rl.Rectangle{r.x, r.y + f32(i - scroll) * ROW_H, r.width, ROW_H}
		if i == selected {
			fill(row, HIGHLIGHT)
		} else if hovered(row, mouse) {
			fill(row, ROW_HOVER)
		}
		s, color := label(i, user)
		// The selection highlight is dark enough that a tinted row on top of it
		// stops being readable, so a selected row is always plain white.
		text(s, i32(row.x) + 8, i32(row.y) + (ROW_H - LABEL) / 2, LABEL, i == selected ? TEXT : color)
	}

	if count > rows {
		thumb_h := max(f32(20), r.height * f32(rows) / f32(count))
		t := f32(scroll) / f32(max(1, count - rows))
		rl.DrawRectangle(
			i32(r.x + r.width) - 5,
			i32(r.y + t * (r.height - thumb_h)),
			4,
			i32(thumb_h),
			SCROLLBAR,
		)
	}
}
