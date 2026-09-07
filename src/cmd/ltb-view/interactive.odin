package main

import "core:fmt"
import "core:math"
import "ltb:app"
import hex "ltb:hex"
import "ltb:layers"
import "ltb:render"
import "ltb:sim"
import "ltb:world"
import rl "vendor:raylib"

// Interactive map view: pan, zoom, cycle layers, inspect a cell, run the
// simulation, and open a different dataset from the File menu.
run_interactive :: proc(a: ^app.App) {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT})
	rl.InitWindow(i32(a.opts.width), i32(a.opts.height), "ltb")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	cam: render.Camera
	render.camera_init(&cam, &a.world, a.opts.width, a.opts.height)

	rend: render.Renderer
	render.renderer_init(&rend)
	defer render.renderer_destroy(&rend)

	available := app.populated_layers(&a.world)
	defer delete(available)

	menu: Menu
	menu_init(&menu, a.opts.manifest)
	defer menu_destroy(&menu)

	// `has_data` gates the map. There is no stand-in layer to draw when a
	// dataset brings nothing or names a layer it does not have: the window
	// reports the reason and draws no map at all.
	view: render.View
	current, reason := opening_layer(a, available)
	has_data := len(reason) == 0
	if has_data {
		view = render.default_view(available[current])
	} else {
		fmt.eprintln(reason)
		menu_set_status(&menu, reason)
	}

	running := false
	show_inspector := true
	tick_accum := 0.0
	TICKS_PER_SECOND :: 4.0

	for !rl.WindowShouldClose() {
		w := int(rl.GetScreenWidth())
		h := int(rl.GetScreenHeight())
		render.camera_resize(&cam, w, h)

		// ---- menu ----
		// The bar gets first refusal on the frame's input, so a click on it
		// never also drags the map underneath.
		menu_owns_input := menu_input(&menu, a)

		switch menu.request {
		case .None:
		case .Quit:
			menu.request = .None
			return
		case .Open_Dataset, .Reload:
			opts := a.opts
			if menu.request == .Open_Dataset {
				o, is_manifest := app.dataset_options(a.opts, menu.path)
				if !is_manifest {
					menu_set_status(&menu, "not a dataset manifest")
					menu.request = .None
					break
				}
				opts = o
			}
			menu.request = .None
			if !app.reload(a, opts) {
				fmt.eprintln("could not build that world; the previous one is gone")
				return
			}
			// Everything below held a handle into the world that just went
			// away: the layer ids, the cached value ranges and the framing.
			render.renderer_destroy(&rend)
			render.renderer_init(&rend)
			delete(available)
			available = app.populated_layers(&a.world)
			render.camera_init(&cam, &a.world, w, h)
			menu_set_current(&menu, a.opts.manifest)
			// The options now hold the menu's copy of the path, which outlives
			// the request string they were built from.
			a.opts.manifest = menu.dataset

			current, reason = opening_layer(a, available)
			has_data = len(reason) == 0
			if has_data {
				view = render.default_view(available[current])
				menu_set_status(&menu, "")
			} else {
				fmt.eprintln(reason)
				menu_set_status(&menu, reason)
			}
		case .Load_Source:
			path, layer := menu.path, menu.layer
			menu.request = .None
			app.load_source(&a.world, path, layer)
			delete(available)
			available = app.populated_layers(&a.world)
			render.renderer_invalidate(&rend, view.layer)

			// Show what was just ingested, which is why it was. A source that
			// wrote nothing leaves the map on the layer it was already on and
			// says so, rather than reporting an ingest that did not happen.
			id, known := layers.lookup(a.world.registry, layer)
			shown := false
			if known {
				for l, i in available {
					if l == id {
						current, view.layer, has_data, shown = i, id, true, true
						break
					}
				}
			}
			if shown {
				menu_set_status(&menu, fmt.tprintf("ingested %s", layer))
			} else {
				menu_set_status(&menu, fmt.tprintf("%s wrote no cells to %s", path, layer))
			}
		}

		// ---- input ----
		if !menu_owns_input {
			if rl.IsMouseButtonDown(.LEFT) {
				d := rl.GetMouseDelta()
				render.camera_pan_pixels(&cam, f64(d.x), f64(d.y))
			}
			pan := 600.0 * f64(rl.GetFrameTime())
			if rl.IsKeyDown(.LEFT) {render.camera_pan_pixels(&cam, pan, 0)}
			if rl.IsKeyDown(.RIGHT) {render.camera_pan_pixels(&cam, -pan, 0)}
			if rl.IsKeyDown(.UP) {render.camera_pan_pixels(&cam, 0, pan)}
			if rl.IsKeyDown(.DOWN) {render.camera_pan_pixels(&cam, 0, -pan)}

			if wheel := rl.GetMouseWheelMove(); wheel != 0 {
				mp := rl.GetMousePosition()
				render.camera_zoom_at(&cam, math.pow(0.86, f64(wheel)), {f64(mp.x), f64(mp.y)})
			}

			if rl.IsKeyPressed(.RIGHT_BRACKET) && len(available) > 0 {
				current = (current + 1) %% len(available)
				view.layer = available[current]
			}
			if rl.IsKeyPressed(.LEFT_BRACKET) && len(available) > 0 {
				current = (current - 1) %% len(available)
				view.layer = available[current]
			}
			if rl.IsKeyPressed(.G) {view.show_grid = !view.show_grid}
			if rl.IsKeyPressed(.H) {view.shade_strength = view.shade_strength > 0 ? 0.0 : 0.45}
			if rl.IsKeyPressed(.F) {view.fill_from_coarser = !view.fill_from_coarser}
			if rl.IsKeyPressed(.I) {show_inspector = !show_inspector}
			if rl.IsKeyPressed(.SPACE) {running = !running}
			if rl.IsKeyPressed(.N) {
				sim.step(&a.sim)
				sim.flush_pyramid(&a.sim)
				render.renderer_invalidate(&rend, view.layer)
			}
			if rl.IsKeyPressed(.R) {view.auto_range = !view.auto_range}
			if rl.IsKeyPressed(.O) {browser_open(&menu.browser, a)}
			auto_level, _ := render.camera_visible(&cam, &a.world)
			if rl.IsKeyPressed(.COMMA) {
				base := view.force_level < 0 ? auto_level : view.force_level
				view.force_level = min(base + 1, world.level_count(&a.world) - 1)
			}
			if rl.IsKeyPressed(.PERIOD) {
				base := view.force_level < 0 ? auto_level : view.force_level
				view.force_level = max(base - 1, 0)
			}
			if rl.IsKeyPressed(.GRAVE) {view.force_level = -1}
		}

		if running {
			tick_accum += f64(rl.GetFrameTime()) * TICKS_PER_SECOND
			for tick_accum >= 1.0 {
				sim.step(&a.sim)
				tick_accum -= 1.0
			}
			render.renderer_invalidate(&rend, view.layer)
		}

		// ---- draw ----
		rl.BeginDrawing()
		rl.ClearBackground(render.BACKGROUND)

		if has_data {
			stats := render.draw_layer(&rend, &a.world, &cam, view)

			hovered: hex.Hex
			if !menu_owns_input {
				mp := rl.GetMousePosition()
				hovered = render.camera_pick(&cam, &a.world, {f64(mp.x), f64(mp.y)}, stats.level)
				render.draw_cell_outline(&a.world, &cam, stats.level, hovered, rl.Color{255, 255, 255, 190}, 2)
			}
			draw_hud(a, &cam, view, stats, hovered, running, show_inspector)
		} else {
			draw_no_map(menu.status)
		}
		menu_draw(&menu, a)
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}

/*
The layer to open on.

A dataset that names one and does not have it is a broken dataset, and says so
rather than drawing a different layer that happens to be there: a road network
silently rendered as the elevation underneath it looks like a working render.

With no layer named there is nothing to contradict, so the first layer holding
data is the documented default for an unset option.
*/
@(private)
opening_layer :: proc(a: ^app.App, available: []layers.Layer_Id) -> (index: int, reason: string) {
	if len(available) == 0 {
		return 0, "this dataset loaded no data"
	}
	want := a.opts.open_layer
	if len(want) == 0 {
		return 0, ""
	}

	id, known := layers.lookup(a.world.registry, want)
	if !known {
		return 0, fmt.tprintf("no layer named %q; run --list-layers to see the catalogue", want)
	}
	for l, i in available {
		if l == id {
			return i, ""
		}
	}
	return 0, fmt.tprintf("layer %q holds no data in this dataset", want)
}

// Why there is no map, in the middle of the window where the map would be.
// The alternative -- drawing some other layer so the window looks busy -- is
// what this viewer does not do.
@(private)
draw_no_map :: proc(reason: string) {
	centred :: proc(text: cstring, y: i32, size: i32, color: rl.Color) {
		rl.DrawText(text, rl.GetScreenWidth() / 2 - rl.MeasureText(text, size) / 2, y, size, color)
	}
	y := rl.GetScreenHeight() / 2 - 30
	centred(fmt.ctprintf("%s", reason), y, 22, rl.Color{235, 170, 160, 255})
	centred(
		"File > Open dataset, press o, or drop a GeoTIFF or GeoJSON on the window",
		y + 34,
		14,
		rl.Color{160, 170, 190, 255},
	)
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
	screen_w := rl.GetScreenWidth()
	screen_h := rl.GetScreenHeight()
	// Everything hangs below the menu bar rather than under it.
	top := i32(MENU_BAR_H) + 1

	// Left panel: what is being drawn.
	rl.DrawRectangle(0, top, 320, 118, rl.Color{0, 0, 0, 150})
	desc := layers.desc_of(a.world.registry, view.layer)
	rl.DrawText(fmt.ctprintf("%s", desc.name), 10, top + 8, 20, rl.RAYWHITE)
	rl.DrawText(fmt.ctprintf("%s", desc.description), 10, top + 30, 11, rl.GRAY)
	rl.DrawText(
		fmt.ctprintf(
			"level %d%s  %.0f m/px  cell %.0f m",
			stats.level,
			view.force_level >= 0 ? " (locked)" : "",
			cam.metres_per_pixel,
			world.level_resolution(&a.world, stats.level),
		),
		10,
		top + 52,
		13,
		rl.LIGHTGRAY,
	)
	rl.DrawText(
		fmt.ctprintf("%d cells drawn, %d without data", stats.cells_drawn, stats.cells_missing),
		10,
		top + 70,
		13,
		rl.LIGHTGRAY,
	)
	rl.DrawText(
		fmt.ctprintf(
			"%s  year %d  day %.0f  %d fps",
			running ? "running" : "paused",
			sim.clock_year(a.sim.clock),
			sim.clock_day_of_year(a.sim.clock),
			rl.GetFPS(),
		),
		10,
		top + 88,
		13,
		running ? rl.Color{140, 220, 150, 255} : rl.Color{220, 190, 140, 255},
	)

	// Legend, bottom left.
	legend_h := i32(len(desc.categories) > 0 ? 30 + 17 * len(desc.categories) : 62)
	rl.DrawRectangle(0, screen_h - legend_h - 46, 240, legend_h + 46, rl.Color{0, 0, 0, 150})
	render.draw_legend(&a.world, view.layer, 10, screen_h - legend_h - 36, stats.range_lo, stats.range_hi)
	render.draw_scale_bar(cam, 10, screen_h - 22)

	// Inspector, right.
	if show_inspector {
		rl.DrawRectangle(screen_w - 300, top, 300, screen_h - top, rl.Color{0, 0, 0, 150})
		render.draw_cell_inspector(&a.world, stats.level, hovered, screen_w - 288, top + 10, 30)
	}

	rl.DrawText(
		"[ ] layer   g grid   h shade   f fill   r range   i inspector   , . level   ` auto   space run   n step   o open",
		10,
		screen_h - 40 - 0,
		11,
		rl.Color{200, 200, 200, 160},
	)
}
