package ui

import rl "vendor:raylib"

/*
A panel sized by what is put in it.

	p := ui.panel_begin(.Top_Left, {0, 27})
	p.min_width = 320
	ui.title(&p, name)
	ui.caption(&p, description)
	ui.line(&p, status, ui.OK)
	ui.panel_end(&p)

The rows are collected on the temporary allocator and drawn by `panel_end`,
which measures them first. Nothing above this file computes a panel height, so
adding a line cannot leave the box behind it one line short.
*/

Anchor :: enum {
	Top_Left,
	Top_Right,
	Bottom_Left,
	Bottom_Right,
	Bottom_Center,
}

Row_Kind :: enum {
	Text,
	// Two labels on one line, the second right-aligned. Ranges and key/value
	// readouts, where the eye wants the second column against an edge.
	Span,
	// A colour chip with a label beside it, for a legend's classes.
	Swatch,
	// A colour ramp across the panel's width.
	Gradient,
	// A map scale bar: a rule of a known pixel length, with its distance under it.
	Scale,
	Gap,
}

// Colour at position `t` in 0..1 along a gradient row. A callback, so that this
// package never learns what a palette is.
Sampler :: struct {
	at:   proc(t: f64, user: rawptr) -> rl.Color,
	user: rawptr,
}

@(private)
Row :: struct {
	kind:   Row_Kind,
	text:   string,
	right:  string,
	size:   i32,
	color:  rl.Color,
	swatch: rl.Color,
	ramp:   Sampler,
	// Pixel length of a `.Scale` rule, or the height of a `.Gradient` or `.Gap`.
	extent: i32,
}

Panel :: struct {
	anchor:     Anchor,
	// Distance from the anchored corner, in pixels.
	inset:      [2]i32,
	// The panel grows past these to fit its rows; it never shrinks below them.
	// A readout whose text changes every frame needs a floor, or it flickers
	// wider and narrower under the mouse.
	min_width:  i32,
	min_height: i32,
	pad:        [2]i32,
	bg:         rl.Color,
	rows:       [dynamic]Row,
}

@(private)
SWATCH_SIZE :: 14
@(private)
SWATCH_GAP :: 6
@(private)
SPAN_GAP :: 12

panel_begin :: proc(anchor: Anchor, inset: [2]i32 = {0, 0}) -> Panel {
	return Panel {
		anchor = anchor,
		inset = inset,
		pad = {10, 8},
		bg = PANEL,
		rows = make([dynamic]Row, 0, 16, context.temp_allocator),
	}
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

title :: proc(p: ^Panel, s: string) {
	append(&p.rows, Row{kind = .Text, text = s, size = TITLE, color = TEXT})
}

heading :: proc(p: ^Panel, s: string) {
	append(&p.rows, Row{kind = .Text, text = s, size = HEADING, color = TEXT})
}

// A line of readout. The colour is the row's meaning, so it is the one thing
// worth passing.
line :: proc(p: ^Panel, s: string, color := TEXT_DIM) {
	append(&p.rows, Row{kind = .Text, text = s, size = LABEL, color = color})
}

// Secondary text: a description under a title, a hint under a control.
caption :: proc(p: ^Panel, s: string, color := TEXT_FAINT) {
	append(&p.rows, Row{kind = .Text, text = s, size = SMALL, color = color})
}

span :: proc(p: ^Panel, left, right: string, size: i32 = SMALL, color := TEXT_DIM) {
	append(&p.rows, Row{kind = .Span, text = left, right = right, size = size, color = color})
}

swatch :: proc(p: ^Panel, color: rl.Color, s: string) {
	append(&p.rows, Row{kind = .Swatch, text = s, size = SMALL, color = TEXT_DIM, swatch = color})
}

gradient :: proc(p: ^Panel, ramp: Sampler, height: i32 = 14) {
	append(&p.rows, Row{kind = .Gradient, ramp = ramp, extent = height})
}

// `length` is the bar's length in pixels; the caller worked out what round
// distance that is and passes it as `label`.
scale :: proc(p: ^Panel, length: i32, label: string) {
	append(&p.rows, Row{kind = .Scale, text = label, size = SMALL, color = TEXT, extent = length})
}

gap :: proc(p: ^Panel, height: i32 = LEADING) {
	append(&p.rows, Row{kind = .Gap, extent = height})
}

// ---------------------------------------------------------------------------
// Measure and draw
// ---------------------------------------------------------------------------

@(private)
row_height :: proc(r: Row) -> i32 {
	switch r.kind {
	case .Text, .Span:
		return r.size + LEADING
	case .Swatch:
		return max(SWATCH_SIZE, r.size) + 3
	case .Scale:
		// Rule, then the distance under it.
		return 11 + r.size + LEADING
	case .Gradient, .Gap:
		return r.extent
	}
	return 0
}

// Width the row needs. A gradient claims none: it stretches to whatever the
// rest of the panel turns out to be.
@(private)
row_width :: proc(r: Row) -> i32 {
	switch r.kind {
	case .Text:
		return text_width(r.text, r.size)
	case .Span:
		return text_width(r.text, r.size) + SPAN_GAP + text_width(r.right, r.size)
	case .Swatch:
		return SWATCH_SIZE + SWATCH_GAP + text_width(r.text, r.size)
	case .Scale:
		return max(r.extent, text_width(r.text, r.size))
	case .Gradient, .Gap:
		return 0
	}
	return 0
}

// Sizes the panel around its rows, paints it, and draws them. Returns the box
// it occupied, so panels can be stacked against the same edge.
panel_end :: proc(p: ^Panel) -> rl.Rectangle {
	w, h := p.min_width, 2 * p.pad.y
	for r in p.rows {
		w = max(w, row_width(r) + 2 * p.pad.x)
		h += row_height(r)
	}
	h = max(h, p.min_height)

	screen_w, screen_h := rl.GetScreenWidth(), rl.GetScreenHeight()
	x, y: i32
	switch p.anchor {
	case .Top_Left:
		x, y = p.inset.x, p.inset.y
	case .Top_Right:
		x, y = screen_w - w - p.inset.x, p.inset.y
	case .Bottom_Left:
		x, y = p.inset.x, screen_h - h - p.inset.y
	case .Bottom_Right:
		x, y = screen_w - w - p.inset.x, screen_h - h - p.inset.y
	case .Bottom_Center:
		x, y = (screen_w - w) / 2 + p.inset.x, screen_h - h - p.inset.y
	}

	box := rect(x, y, w, h)
	fill(box, p.bg)

	inner_x := x + p.pad.x
	inner_w := w - 2 * p.pad.x
	cy := y + p.pad.y
	for r in p.rows {
		draw_row(r, inner_x, cy, inner_w)
		cy += row_height(r)
	}
	return box
}

@(private)
draw_row :: proc(r: Row, x, y, width: i32) {
	switch r.kind {
	case .Text:
		text(r.text, x, y, r.size, r.color)
	case .Span:
		text(r.text, x, y, r.size, r.color)
		text_right(r.right, x + width, y, r.size, r.color)
	case .Swatch:
		fill(rect(x, y, SWATCH_SIZE, SWATCH_SIZE), r.swatch)
		text(r.text, x + SWATCH_SIZE + SWATCH_GAP, y + 1, r.size, r.color)
	case .Gradient:
		if r.ramp.at == nil {
			return
		}
		// A column per pixel, sampled in the ramp's own space, so a log palette
		// shows where its values actually land.
		for i in 0 ..< width {
			c := r.ramp.at(f64(i) / f64(max(1, width - 1)), r.ramp.user)
			rl.DrawRectangle(x + i, y, 1, r.extent, c)
		}
	case .Scale:
		rl.DrawRectangle(x, y + 4, r.extent, 3, r.color)
		rl.DrawRectangle(x, y, 2, 11, r.color)
		rl.DrawRectangle(x + r.extent - 2, y, 2, 11, r.color)
		text(r.text, x, y + 13, r.size, r.color)
	case .Gap:
	}
}

// The inset a bottom-anchored panel needs to sit directly above `r`, which
// `panel_end` returned. Stacks panels against the bottom edge without anyone
// having to know how tall the one below came out.
above :: proc(r: rl.Rectangle) -> [2]i32 {
	return {i32(r.x), rl.GetScreenHeight() - i32(r.y)}
}
