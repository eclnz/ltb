package render

import "core:fmt"
import "core:math"
import "core:strings"
import hex "ltb:hex"
import "ltb:layers"
import "ltb:world"
import rl "vendor:raylib"

// What the map is currently showing.
View :: struct {
	layer:          layers.Layer_Id,
	// Blends cached hillshade over the layer colour. Terrain reads as terrain
	// with it and as a flat choropleth without it.
	shade_strength: f64,
	show_grid:      bool,
	// Overrides the automatic level. -1 follows the zoom.
	force_level:    int,
	// Stretches the palette across the values present at the drawn level
	// instead of the descriptor's declared range.
	auto_range:     bool,
	// Cell outline colour, used when `show_grid` is set.
	grid_color:     rl.Color,
	background:     rl.Color,
	// Fills cells with no data at the drawn level by walking up the pyramid.
	// With it off, a cell is drawn only where the drawn level itself has data.
	fill_from_coarser: bool,
}

default_view :: proc(layer: layers.Layer_Id) -> View {
	return View {
		layer = layer,
		shade_strength = 0.45,
		show_grid = false,
		force_level = -1,
		auto_range = true,
		grid_color = rl.Color{0, 0, 0, 60},
		background = rl.Color{14, 16, 20, 255},
		fill_from_coarser = true,
	}
}

Stats :: struct {
	level:        int,
	cells_drawn:  int,
	cells_missing: int,
	bounds:       hex.Bounds,
	// Value range the palette was stretched across.
	range_lo:     f64,
	range_hi:     f64,
}

Range_Key :: struct {
	layer: layers.Layer_Id,
	level: u8,
}

Value_Range :: struct {
	lo, hi: f64,
}

// Holds what the renderer caches between frames.
Renderer :: struct {
	ranges: map[Range_Key]Value_Range,
}

renderer_init :: proc(r: ^Renderer, allocator := context.allocator) {
	r.ranges = make(map[Range_Key]Value_Range, 64, allocator)
}

renderer_destroy :: proc(r: ^Renderer) {
	delete(r.ranges)
	r^ = {}
}

// Drops a cached value range, so the next frame recomputes it. Call after a
// system has rewritten a layer.
renderer_invalidate :: proc(r: ^Renderer, layer: layers.Layer_Id) {
	for key in r.ranges {
		if key.layer == layer {
			delete_key(&r.ranges, key)
		}
	}
}

// The range of values present in a layer at one level, cached.
value_range :: proc(r: ^Renderer, w: ^world.World, layer: layers.Layer_Id, level: int) -> Value_Range {
	key := Range_Key{layer, u8(level)}
	if v, ok := r.ranges[key]; ok {
		return v
	}
	d := layers.desc_of(w.registry, layer)
	out := Value_Range{d.min_value, d.max_value}

	cells := layers.collect_cells(w.store, layer, u8(level), context.temp_allocator)
	defer delete(cells, context.temp_allocator)
	if len(cells) > 0 {
		lo, hi := cells[0].value, cells[0].value
		for c in cells[1:] {
			lo = math.min(lo, c.value)
			hi = math.max(hi, c.value)
		}
		if hi > lo {
			out = Value_Range{lo, hi}
		}
	}
	r.ranges[key] = out
	return out
}

// Draws one layer over the visible area. Returns what it did, for the HUD.
draw_layer :: proc(r: ^Renderer, w: ^world.World, cam: ^Camera, view: View) -> (stats: Stats) {
	level, bounds := camera_visible(cam, w)
	if view.force_level >= 0 {
		level = clamp(view.force_level, 0, world.level_count(w) - 1)
		mn, mx := camera_view_rect(cam)
		bounds = hex.bounds_covering_rect(world.layout(w, level), mn, mx)
	}
	stats.level = level
	stats.bounds = bounds

	desc := layers.desc_of(w.registry, view.layer)
	if desc == nil {
		return
	}
	lay := world.layout(w, level)
	shade_id, has_shade := layers.lookup(w.registry, "terrain.hillshade")

	// Cell radius in pixels.
	radius_px := f32(math.sqrt(lay.size.x * lay.size.y) / cam.metres_per_pixel)
	// `start_angle` is the first corner's position in sixths of a turn, which
	// is the rotation raylib wants in degrees.
	rotation := f32(lay.orientation.start_angle * 60.0)

	stats.range_lo = desc.min_value
	stats.range_hi = desc.max_value
	if view.auto_range && desc.semantic != .Composition && desc.semantic != .Categorical {
		vr := value_range(r, w, view.layer, level)
		stats.range_lo, stats.range_hi = vr.lo, vr.hi
	}
	span := stats.range_hi - stats.range_lo

	nc := layers.desc_components(desc)
	comps: [layers.MAX_ACCUM_COMPONENTS]f64

	for r in bounds.r0 ..= bounds.r1 {
		for q in bounds.q0 ..= bounds.q1 {
			h := hex.Hex{q, r}

			value: f64
			ok: bool
			draw_level := level
			if desc.semantic == .Composition {
				ok = layers.get_components(w.store, view.layer, u8(level), h, comps[:nc])
				if !ok && view.fill_from_coarser {
					cell := h
					for l := level + 1; l < world.level_count(w); l += 1 {
						cell = world.parent(cell)
						if layers.get_components(w.store, view.layer, u8(l), cell, comps[:nc]) {
							ok = true
							draw_level = l
							break
						}
					}
				}
			} else {
				value, ok = layers.get(w.store, view.layer, u8(level), h)
				if !ok && view.fill_from_coarser {
					v, found_level, got := world.sample(w, view.layer, level, h)
					value, draw_level, ok = v, found_level, got
				}
			}
			if !ok {
				stats.cells_missing += 1
				continue
			}

			rgb: layers.RGB
			if desc.semantic == .Composition {
				rgb = layers.composition_color(desc, comps[:nc])
			} else if desc.semantic == .Categorical || desc.semantic == .Boolean {
				rgb = layers.value_color(desc, value)
			} else {
				t := span > 0 ? (value - stats.range_lo) / span : 0
				rgb = layers.palette_sample(desc.palette, t)
			}

			if view.shade_strength > 0 && has_shade {
				if s, got := layers.get(w.store, shade_id, u8(draw_level), draw_level == level ? h : world.to_level(h, level, draw_level)); got {
					// Lambert shading blended towards the base colour, so the
					// hue survives and only the value changes.
					f := 1.0 - view.shade_strength + view.shade_strength * clamp(s * 1.35, 0.15, 1.25)
					rgb = {
						u8(clamp(f64(rgb.r) * f, 0, 255)),
						u8(clamp(f64(rgb.g) * f, 0, 255)),
						u8(clamp(f64(rgb.b) * f, 0, 255)),
					}
				}
			}

			p := hex.to_world(lay, h)
			sp := world_to_screen(cam, p)
			rl.DrawPoly(rl.Vector2{sp.x, sp.y}, 6, radius_px, rotation, rl.Color{rgb.r, rgb.g, rgb.b, 255})
			if view.show_grid && radius_px > 6 {
				rl.DrawPolyLines(rl.Vector2{sp.x, sp.y}, 6, radius_px, rotation, view.grid_color)
			}
			stats.cells_drawn += 1
		}
	}
	return
}

// Outlines a single cell, for the hover and selection cursors.
draw_cell_outline :: proc(w: ^world.World, cam: ^Camera, level: int, h: hex.Hex, color: rl.Color, thickness: f32 = 2) {
	lay := world.layout(w, level)
	corners: [6]hex.Vec2
	hex.corners(lay, h, &corners)
	for i in 0 ..< 6 {
		a := world_to_screen(cam, corners[i])
		b := world_to_screen(cam, corners[(i + 1) % 6])
		rl.DrawLineEx(rl.Vector2{a.x, a.y}, rl.Vector2{b.x, b.y}, thickness, color)
	}
}

// ---------------------------------------------------------------------------
// Legend and readouts
// ---------------------------------------------------------------------------

// Draws a colour ramp labelled with the range it spans, or a class list for a
// categorical or composition layer.
draw_legend :: proc(
	w: ^world.World,
	layer: layers.Layer_Id,
	x, y: i32,
	lo, hi: f64,
	width: i32 = 200,
) -> (
	height: i32,
) {
	desc := layers.desc_of(w.registry, layer)
	if desc == nil {
		return 0
	}
	pad := i32(6)
	rl.DrawText(strings.clone_to_cstring(desc.name, context.temp_allocator), x, y, 16, rl.RAYWHITE)
	cy := y + 22

	#partial switch desc.semantic {
	case .Categorical, .Composition:
		for cat in desc.categories {
			rl.DrawRectangle(x, cy, 14, 14, rl.Color{cat.color.r, cat.color.g, cat.color.b, 255})
			rl.DrawText(strings.clone_to_cstring(cat.name, context.temp_allocator), x + 20, cy, 12, rl.LIGHTGRAY)
			cy += 17
		}
	case:
		bar_h := i32(14)
		for i in 0 ..< width {
			t := f64(i) / f64(max(1, width - 1))
			c := layers.palette_sample(desc.palette, t)
			rl.DrawRectangle(x + i, cy, 1, bar_h, rl.Color{c.r, c.g, c.b, 255})
		}
		cy += bar_h + 3
		lo_text := fmt.ctprintf("%.4g", lo)
		hi_text := fmt.ctprintf("%.4g %s", hi, desc.unit)
		rl.DrawText(lo_text, x, cy, 12, rl.LIGHTGRAY)
		rl.DrawText(hi_text, x + width - rl.MeasureText(hi_text, 12), cy, 12, rl.LIGHTGRAY)
		cy += 16
	}
	return cy - y + pad
}

// Values of every layer that has data at a cell, as a readable block. This is
// the inspector that makes a hundred-layer world comprehensible.
draw_cell_inspector :: proc(
	w: ^world.World,
	level: int,
	h: hex.Hex,
	x, y: i32,
	max_rows := 24,
) -> (
	height: i32,
) {
	cy := y
	ll := world.cell_center_ll(w, level, h)
	rl.DrawText(fmt.ctprintf("cell %d, %d  @L%d", h.q, h.r, level), x, cy, 14, rl.RAYWHITE)
	cy += 18
	rl.DrawText(fmt.ctprintf("%.5f, %.5f", ll.lat, ll.lon), x, cy, 12, rl.GRAY)
	cy += 18

	rows := 0
	comps: [layers.MAX_ACCUM_COMPONENTS]f64
	for i in 0 ..< layers.layer_count(w.registry) {
		if rows >= max_rows {
			rl.DrawText("...", x, cy, 12, rl.GRAY)
			cy += 15
			break
		}
		id := layers.Layer_Id(i)
		d := layers.desc_of(w.registry, id)
		nc := layers.desc_components(d)

		if d.semantic == .Composition {
			if !layers.get_components(w.store, id, u8(level), h, comps[:nc]) {
				continue
			}
			idx, share := layers.dominant_component(comps[:nc])
			name := idx >= 0 && idx < len(d.categories) ? d.categories[idx].name : "?"
			rl.DrawText(fmt.ctprintf("%s: %s %.0f%%", d.name, name, share * 100), x, cy, 12, rl.LIGHTGRAY)
			cy += 15
			rows += 1
			continue
		}

		value, ok := layers.get(w.store, id, u8(level), h)
		if !ok {
			continue
		}
		if d.semantic == .Categorical {
			label := "unknown"
			for cat in d.categories {
				if f64(cat.value) == value {
					label = cat.name
					break
				}
			}
			rl.DrawText(fmt.ctprintf("%s: %s", d.name, label), x, cy, 12, rl.LIGHTGRAY)
		} else if len(d.unit) > 0 {
			rl.DrawText(fmt.ctprintf("%s: %.4g %s", d.name, value, d.unit), x, cy, 12, rl.LIGHTGRAY)
		} else {
			rl.DrawText(fmt.ctprintf("%s: %.4g", d.name, value), x, cy, 12, rl.LIGHTGRAY)
		}
		cy += 15
		rows += 1
	}
	return cy - y
}

// A scale bar sized to a round number of metres or kilometres.
draw_scale_bar :: proc(cam: ^Camera, x, y: i32) {
	// Aim for about 140 px, then round down to 1, 2 or 5 times a power of ten.
	target := 140.0 * cam.metres_per_pixel
	exp := math.pow(10.0, math.floor(math.log10(target)))
	mant := target / exp
	nice := mant >= 5 ? 5.0 : (mant >= 2 ? 2.0 : 1.0)
	metres := nice * exp
	px := i32(metres / cam.metres_per_pixel)

	rl.DrawRectangle(x, y, px, 3, rl.RAYWHITE)
	rl.DrawRectangle(x, y - 4, 2, 11, rl.RAYWHITE)
	rl.DrawRectangle(x + px - 2, y - 4, 2, 11, rl.RAYWHITE)
	label := metres >= 1000 ? fmt.ctprintf("%.0f km", metres / 1000.0) : fmt.ctprintf("%.0f m", metres)
	rl.DrawText(label, x, y + 8, 12, rl.RAYWHITE)
}
