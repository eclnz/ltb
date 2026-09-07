package main

import "core:fmt"
import "core:math"
import "ltb:app"
import hex "ltb:hex"
import "ltb:layers"
import "ltb:render"
import "ltb:sim"
import "ltb:ui"
import "ltb:world"

/*
The readouts drawn over the map.

Everything here is a `ui.Panel`: rows go in, the panel measures itself and
paints its own background. Nothing in this file knows how tall a panel is, which
is the only way the box and the text in it stay in agreement.

The panels hang off the window's corners rather than sitting at fixed
coordinates, so the layout survives a resize and a longer layer name.
*/

// Below the menu bar rather than under it.
@(private)
hud_top :: proc() -> i32 {
	return i32(MENU_BAR_H) + 1
}

@(private)
rgb :: proc(c: layers.RGB) -> ui.Color {
	return ui.Color{c.r, c.g, c.b, 255}
}

@(private)
draw_hud :: proc(
	a: ^app.App,
	cam: ^render.Camera,
	view: render.View,
	stats: render.Stats,
	hovered: hex.Hex,
	running: bool,
	show_inspector: bool,
) {
	draw_status_panel(a, cam, view, stats, running)

	// Bottom left, stacked upwards: the keys, then the legend and scale above
	// them. `ui.above` takes the height of each from what it measured.
	keys := draw_key_hints()
	draw_legend(a, cam, view, stats, ui.above(keys))

	if show_inspector {
		draw_inspector(a, stats.level, hovered)
	}
}

// What is being drawn, and how the simulation is doing.
@(private)
draw_status_panel :: proc(
	a: ^app.App,
	cam: ^render.Camera,
	view: render.View,
	stats: render.Stats,
	running: bool,
) {
	desc := layers.desc_of(a.world.registry, view.layer)
	if desc == nil {
		return
	}

	p := ui.panel_begin(.Top_Left, {0, hud_top()})
	p.min_width = 320
	defer ui.panel_end(&p)

	ui.title(&p, desc.name)
	ui.caption(&p, desc.description)
	ui.line(
		&p,
		fmt.tprintf(
			"level %d%s  %.0f m/px  cell %.0f m",
			stats.level,
			view.force_level >= 0 ? " (locked)" : "",
			cam.metres_per_pixel,
			world.level_resolution(&a.world, stats.level),
		),
	)
	ui.line(&p, fmt.tprintf("%d cells drawn, %d without data", stats.cells_drawn, stats.cells_missing))
	ui.line(
		&p,
		fmt.tprintf(
			"%s  year %d  day %.0f  %d fps",
			running ? "running" : "paused",
			sim.clock_year(a.sim.clock),
			sim.clock_day_of_year(a.sim.clock),
			ui.fps(),
		),
		running ? ui.OK : ui.WARN,
	)
}

@(private)
draw_key_hints :: proc() -> ui.Rectangle {
	p := ui.panel_begin(.Bottom_Left)
	ui.caption(
		&p,
		"[ ] layer   g grid   h shade   f fill   r range   i inspector   , . level   ` auto   space run   n step   o open",
		ui.TEXT_FAINT,
	)
	return ui.panel_end(&p)
}

// ---------------------------------------------------------------------------
// Legend
// ---------------------------------------------------------------------------

// What a gradient row needs to colour itself: the descriptor's palette, and the
// value range the map was actually stretched across.
@(private)
Ramp :: struct {
	desc:   ^layers.Layer_Desc,
	lo, hi: f64,
}

@(private)
ramp_sample :: proc(t: f64, user: rawptr) -> ui.Color {
	r := (^Ramp)(user)
	// Sampled in value space, so a log layer's ramp shows where its values land.
	v := r.lo + (r.hi - r.lo) * t
	return rgb(layers.palette_sample(r.desc.palette, layers.palette_position(r.desc, v, r.lo, r.hi)))
}

// The colour key for the layer on screen, with a scale bar under it.
@(private)
draw_legend :: proc(a: ^app.App, cam: ^render.Camera, view: render.View, stats: render.Stats, inset: [2]i32) {
	desc := layers.desc_of(a.world.registry, view.layer)
	if desc == nil {
		return
	}

	p := ui.panel_begin(.Bottom_Left, inset)
	p.min_width = 240
	defer ui.panel_end(&p)

	ui.heading(&p, desc.name)

	#partial switch desc.semantic {
	case .Categorical, .Composition:
		for cat in desc.categories {
			ui.swatch(&p, rgb(cat.color), cat.name)
		}
	case .Color:
		ui.caption(&p, "true colour RGB, 0-255 per channel")
	case:
		// `ramp` is read during `panel_end`, which the deferred call above runs
		// before this scope ends.
		ramp := Ramp{desc, stats.range_lo, stats.range_hi}
		ui.gradient(&p, {ramp_sample, &ramp})
		ui.span(
			&p,
			fmt.tprintf("%.4g", stats.range_lo),
			desc.display == .Linear \
			? fmt.tprintf("%.4g %s", stats.range_hi, desc.unit) \
			: fmt.tprintf("%.4g %s (%v)", stats.range_hi, desc.unit, desc.display),
		)
	}

	ui.gap(&p)
	length, label := scale_bar(cam)
	ui.scale(&p, length, label)
}

// A scale bar's pixel length and its label: about 140 px, rounded down to 1, 2
// or 5 times a power of ten so the number under it is one a map reader expects.
@(private)
scale_bar :: proc(cam: ^render.Camera) -> (length: i32, label: string) {
	target := 140.0 * cam.metres_per_pixel
	exp := math.pow(10.0, math.floor(math.log10(target)))
	mant := target / exp
	nice := mant >= 5 ? 5.0 : (mant >= 2 ? 2.0 : 1.0)
	metres := nice * exp
	label = metres >= 1000 ? fmt.tprintf("%.0f km", metres / 1000.0) : fmt.tprintf("%.0f m", metres)
	return i32(metres / cam.metres_per_pixel), label
}

// ---------------------------------------------------------------------------
// Inspector
// ---------------------------------------------------------------------------

// Every layer that has data at the hovered cell. This is what makes a
// hundred-layer world comprehensible.
@(private)
draw_inspector :: proc(a: ^app.App, level: int, h: hex.Hex, max_rows := 30) {
	top := hud_top()
	p := ui.panel_begin(.Top_Right, {0, top})
	p.min_width = 300
	// Runs to the bottom of the window: the row count changes with the cell
	// under the mouse, and a panel that grew and shrank as the mouse moved
	// would be unreadable.
	p.min_height = ui.screen_height() - top
	defer ui.panel_end(&p)

	ll := world.cell_center_ll(&a.world, level, h)
	ui.line(&p, fmt.tprintf("cell %d, %d  @L%d", h.q, h.r, level), ui.TEXT)
	ui.caption(&p, fmt.tprintf("%.5f, %.5f", ll.lat, ll.lon), ui.TEXT_MUTED)
	ui.gap(&p)

	rows := 0
	comps: [layers.MAX_ACCUM_COMPONENTS]f64
	for i in 0 ..< layers.layer_count(a.world.registry) {
		if rows >= max_rows {
			ui.caption(&p, "...")
			break
		}
		id := layers.Layer_Id(i)
		d := layers.desc_of(a.world.registry, id)
		nc := layers.desc_components(d)

		#partial switch d.semantic {
		case .Composition:
			if !layers.get_components(a.world.store, id, u8(level), h, comps[:nc]) {
				continue
			}
			idx, share := layers.dominant_component(comps[:nc])
			name := idx >= 0 && idx < len(d.categories) ? d.categories[idx].name : "?"
			ui.caption(&p, fmt.tprintf("%s: %s %.0f%%", d.name, name, share * 100), ui.TEXT_DIM)
			rows += 1
			continue
		case .Color:
			if !layers.get_components(a.world.store, id, u8(level), h, comps[:nc]) {
				continue
			}
			ui.caption(
				&p,
				fmt.tprintf("%s: rgb(%.0f, %.0f, %.0f)", d.name, comps[0], comps[1], comps[2]),
				ui.TEXT_DIM,
			)
			rows += 1
			continue
		}

		value, ok := layers.get(a.world.store, id, u8(level), h)
		if !ok {
			continue
		}
		switch {
		case d.semantic == .Categorical:
			label := "unknown"
			for cat in d.categories {
				if f64(cat.value) == value {
					label = cat.name
					break
				}
			}
			ui.caption(&p, fmt.tprintf("%s: %s", d.name, label), ui.TEXT_DIM)
		case len(d.unit) > 0:
			ui.caption(&p, fmt.tprintf("%s: %.4g %s", d.name, value, d.unit), ui.TEXT_DIM)
		case:
			ui.caption(&p, fmt.tprintf("%s: %.4g", d.name, value), ui.TEXT_DIM)
		}
		rows += 1
	}
}

// ---------------------------------------------------------------------------
// Full-window messages
// ---------------------------------------------------------------------------

// Why there is no map, in the middle of the window where the map would be. The
// alternative -- drawing some other layer so the window looks busy -- is what
// this viewer does not do.
@(private)
draw_no_map :: proc(reason: string) {
	y := ui.screen_height() / 2 - 30
	ui.text_screen_centered(reason, y, ui.TITLE - 2, ui.ALERT)
	ui.text_screen_centered(
		"File > Open dataset, press o, or drop a GeoTIFF or GeoJSON on the window",
		y + 34,
		ui.BODY,
		ui.TEXT_MUTED,
	)
}

// A caption under a scripted screenshot.
@(private)
draw_caption :: proc(text: string) {
	p := ui.panel_begin(.Bottom_Center, {0, 64})
	p.pad = {14, 7}
	p.bg = ui.Color{0, 0, 0, 170}
	defer ui.panel_end(&p)
	ui.heading(&p, text)
}
