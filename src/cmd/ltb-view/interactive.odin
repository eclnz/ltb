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
// simulation.
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
	if len(available) == 0 {
		fmt.eprintln("no layer holds any data; nothing to draw")
		return
	}
	current := 0
	// Open on elevation if it is there, since that is the map people expect.
	if id, ok := layers.lookup(a.world.registry, "terrain.elevation"); ok {
		for l, i in available {
			if l == id {
				current = i
				break
			}
		}
	}

	view := render.default_view(available[current])
	running := false
	show_inspector := true
	tick_accum := 0.0
	TICKS_PER_SECOND :: 4.0

	for !rl.WindowShouldClose() {
		w := int(rl.GetScreenWidth())
		h := int(rl.GetScreenHeight())
		render.camera_resize(&cam, w, h)

		// ---- input ----
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

		if rl.IsKeyPressed(.RIGHT_BRACKET) {
			current = (current + 1) %% len(available)
			view.layer = available[current]
		}
		if rl.IsKeyPressed(.LEFT_BRACKET) {
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
		rl.ClearBackground(view.background)

		stats := render.draw_layer(&rend, &a.world, &cam, view)

		mp := rl.GetMousePosition()
		hovered := render.camera_pick(&cam, &a.world, {f64(mp.x), f64(mp.y)}, stats.level)
		render.draw_cell_outline(&a.world, &cam, stats.level, hovered, rl.Color{255, 255, 255, 190}, 2)

		draw_hud(a, &cam, view, stats, hovered, running, show_inspector)
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
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

	// Left panel: what is being drawn.
	rl.DrawRectangle(0, 0, 320, 118, rl.Color{0, 0, 0, 150})
	desc := layers.desc_of(a.world.registry, view.layer)
	rl.DrawText(fmt.ctprintf("%s", desc.name), 10, 8, 20, rl.RAYWHITE)
	rl.DrawText(fmt.ctprintf("%s", desc.description), 10, 30, 11, rl.GRAY)
	rl.DrawText(
		fmt.ctprintf(
			"level %d%s  %.0f m/px  cell %.0f m",
			stats.level,
			view.force_level >= 0 ? " (locked)" : "",
			cam.metres_per_pixel,
			world.level_resolution(&a.world, stats.level),
		),
		10,
		52,
		13,
		rl.LIGHTGRAY,
	)
	rl.DrawText(
		fmt.ctprintf("%d cells drawn, %d without data", stats.cells_drawn, stats.cells_missing),
		10,
		70,
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
		88,
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
		rl.DrawRectangle(screen_w - 300, 0, 300, screen_h, rl.Color{0, 0, 0, 150})
		render.draw_cell_inspector(&a.world, stats.level, hovered, screen_w - 288, 10, 30)
	}

	rl.DrawText(
		"[ ] layer   g grid   h shade   f fill   r range   i inspector   , . level   ` auto   space run   n step",
		10,
		screen_h - 40 - 0,
		11,
		rl.Color{200, 200, 200, 160},
	)
}
