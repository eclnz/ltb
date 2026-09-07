/*
ltb-view: windowed front end.

The same world as the headless command, drawn and inspectable. Everything that
touches raylib lives in this command and in ltb:render, so the engine itself
stays free of a graphics dependency.
*/
package main

import "core:os"
import "ltb:app"

main :: proc() {
	opts, ok := app.parse_options()
	if !ok {
		os.exit(0)
	}
	if opts.print_layers {
		app.print_catalogue_only()
		return
	}

	a: app.App
	if !app.startup(&a, opts) {
		os.exit(1)
	}
	defer app.shutdown(&a)

	if opts.headless {
		app.report_layers(&a.world)
		return
	}
	if len(opts.shots_dir) > 0 {
		run_capture(&a, opts.shots_dir, DEFAULT_SHOTS[:])
		return
	}
	run_interactive(&a)
}

// The frames `--shots` renders: one per layer family, plus a walk down the
// pyramid over the same ground.
DEFAULT_SHOTS := [?]Shot {
	{
		file = "01-elevation.png",
		layer = "terrain.elevation",
		caption = "terrain.elevation - real SRTM, read from an LZW-compressed int16 GeoTIFF",
		shade = 0.55,
		force_level = -1,
		inspector = true,
		fill = false,
	},
	{
		file = "02-landcover.png",
		layer = "land.cover",
		caption = "land.cover - Natural Earth land, lakes and urban areas, layered in manifest order",
		shade = 0.35,
		force_level = -1,
		inspector = true,
		fill = true,
	},
	{
		file = "03-road-class.png",
		layer = "human.road_class",
		caption = "human.road_class - Natural Earth roads, highest class per cell",
		shade = 0.0,
		force_level = -1,
		inspector = true,
		fill = false,
	},
	{
		file = "04-haul-speed.png",
		layer = "logistics.haul_speed",
		caption = "logistics.haul_speed - a layer declared in the manifest, not in the code",
		shade = 0.0,
		force_level = -1,
		inspector = true,
		fill = false,
	},
	{
		file = "05-road-density.png",
		layer = "human.road_density",
		caption = "human.road_density - km of road per km2, accumulated along each line",
		shade = 0.0,
		force_level = -1,
		inspector = true,
		fill = false,
	},
	{
		file = "06-built-up.png",
		layer = "human.built_up",
		caption = "human.built_up - fraction of each cell inside an urban area polygon",
		shade = 0.25,
		force_level = -1,
		inspector = true,
		fill = false,
	},
	{
		file = "07-water.png",
		layer = "water.permanent",
		caption = "water.permanent - lake polygons and river centrelines on the same grid",
		shade = 0.0,
		force_level = -1,
		inspector = true,
		fill = true,
	},
	{
		file = "08-forest-density.png",
		layer = "forest.density",
		caption = "forest.density - canopy cover fraction in one byte",
		shade = 0.45,
		force_level = -1,
		inspector = true,
		fill = true,
	},
	{
		file = "09-zoom-cells.png",
		layer = "terrain.elevation",
		caption = "zoomed in to level 0: 537 m cells, outlined",
		zoom = 9,
		shade = 0.55,
		grid = true,
		force_level = -1,
		inspector = true,
		fill = true,
	},
	{
		file = "10-lod-L0.png",
		layer = "terrain.elevation",
		caption = "same ground, pyramid level 0",
		zoom = 60,
		grid = true,
		shade = 0.5,
		force_level = 0,
		fill = false,
	},
	{
		file = "11-lod-L1.png",
		layer = "terrain.elevation",
		caption = "level 1: cells twice as wide, four times the area",
		zoom = 60,
		grid = true,
		shade = 0.5,
		force_level = 1,
		fill = false,
	},
	{
		file = "12-lod-L2.png",
		layer = "terrain.elevation",
		caption = "level 2: built by aggregating level 1, not by resampling the source",
		zoom = 60,
		grid = true,
		shade = 0.5,
		force_level = 2,
		fill = false,
	},
	{
		file = "13-lod-L3.png",
		layer = "terrain.elevation",
		caption = "level 3: sixty-four level-0 cells to one",
		zoom = 60,
		grid = true,
		shade = 0.5,
		force_level = 3,
		fill = false,
	},
}
