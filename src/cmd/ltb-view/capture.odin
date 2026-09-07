package main

import "core:fmt"
import "core:os"
import "core:strings"
import "ltb:app"
import hex "ltb:hex"
import "ltb:layers"
import "ltb:render"
import "ltb:ui"
import "ltb:world"
import rl "vendor:raylib"

// One frame to render.
Shot :: struct {
	file:        string,
	layer:       string,
	caption:     string,
	// Metres per pixel. Zero frames the whole world.
	zoom:        f64,
	// Offset of the view centre from the world centre, in metres.
	offset:      [2]f64,
	grid:        bool,
	shade:       f64,
	// Pyramid level to draw. Negative follows the zoom.
	force_level: int,
	inspector:   bool,
	fill:        bool,
}

// Renders a scripted set of frames and exits. Used to produce documentation
// images and to check the renderer without a display.
run_capture :: proc(a: ^app.App, dir: string, shots: []Shot) {
	rl.SetConfigFlags({.MSAA_4X_HINT})
	rl.InitWindow(i32(a.opts.width), i32(a.opts.height), "ltb")
	defer rl.CloseWindow()

	if !os.exists(dir) {
		os.make_directory(dir)
	}

	cam: render.Camera
	render.camera_init(&cam, &a.world, a.opts.width, a.opts.height)
	home := cam.center
	fit := cam.metres_per_pixel

	rend: render.Renderer
	render.renderer_init(&rend)
	defer render.renderer_destroy(&rend)

	for shot in shots {
		id, found := layers.lookup(a.world.registry, shot.layer)
		if !found {
			fmt.eprintfln("skipping %s: no layer named %q", shot.file, shot.layer)
			continue
		}
		if layers.count_chunks(a.world.store, id, 0) == 0 {
			fmt.eprintfln("skipping %s: layer %q holds no data", shot.file, shot.layer)
			continue
		}

		view := render.default_view(id)
		view.show_grid = shot.grid
		view.shade_strength = shot.shade
		view.force_level = shot.force_level
		view.fill_from_coarser = shot.fill

		cam.center = {home.x + shot.offset.x, home.y + shot.offset.y}
		cam.metres_per_pixel = shot.zoom > 0 ? shot.zoom : fit

		// raylib needs a frame or two before the framebuffer is worth reading.
		stats: render.Stats
		hovered: hex.Hex
		for _ in 0 ..< 2 {
			rl.BeginDrawing()
			rl.ClearBackground(view.background)
			stats = render.draw_layer(&rend, &a.world, &cam, view)
			centre := [2]f64{cam.screen.x * 0.5, cam.screen.y * 0.42}
			hovered = render.camera_pick(&cam, &a.world, centre, stats.level)
			if shot.inspector {
				render.draw_cell_outline(&a.world, &cam, stats.level, hovered, ui.CURSOR, 2)
			}
			draw_hud(a, &cam, view, stats, hovered, false, shot.inspector)
			if len(shot.caption) > 0 {
				draw_caption(shot.caption)
			}
			rl.EndDrawing()
		}

		path := strings.concatenate({dir, "/", shot.file}, context.temp_allocator)
		rl.TakeScreenshot(strings.clone_to_cstring(path, context.temp_allocator))
		fmt.printfln(
			"%-28s %-32s L%d  %d cells  %.0f m/px",
			shot.file,
			shot.layer,
			stats.level,
			stats.cells_drawn,
			cam.metres_per_pixel,
		)
		free_all(context.temp_allocator)
	}
}
