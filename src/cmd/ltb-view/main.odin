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
		set := DEFAULT_SHOTS[:]
		switch opts.shots_set {
		case "close":
			set = CLOSE_SHOTS[:]
		case "terrain":
			set = TERRAIN_SHOTS[:]
		case "imagery":
			set = IMAGERY_SHOTS[:]
		}
		run_capture(&a, opts.shots_dir, set)
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

// A ladder down to a single carriageway, for a world built at half-metre cells.
// Widths come from the road class, so a motorway is seventy cells across rather
// than one.
CLOSE_SHOTS := [?]Shot {
	{
		file = "c1-1200m.png",
		layer = "human.road_class",
		caption = "1200 m across - the 401 / 427 / 409 interchange on a half-metre grid",
		zoom = 0.83,
		force_level = -1,
		inspector = true,
	},
	{
		file = "c2-400m.png",
		layer = "human.road_class",
		caption = "400 m across - carriageways 36 m wide, from the road class width table",
		zoom = 0.278,
		force_level = -1,
		inspector = true,
	},
	{
		file = "c3-120m.png",
		layer = "human.road_class",
		caption = "120 m across - the junction, still below one cell of the wide-area grid",
		zoom = 0.0833,
		grid = true,
		force_level = -1,
		inspector = true,
	},
	{
		file = "c4-40m.png",
		layer = "human.road_class",
		caption = "40 m across - the northern edge of the carriageway",
		zoom = 0.0278,
		offset = {0, 16},
		grid = true,
		force_level = -1,
		inspector = true,
	},
	{
		file = "c5-20m.png",
		layer = "human.road_class",
		caption = "20 m across - forty cells edge to edge, each half a metre",
		zoom = 0.0139,
		offset = {0, 16},
		grid = true,
		force_level = -1,
		inspector = true,
	},
	{
		file = "c6-20m-elevation.png",
		layer = "terrain.elevation",
		caption = "20 m across, elevation - bilinear from a 790 m DEM: smooth, not detailed",
		zoom = 0.0139,
		offset = {0, 16},
		grid = true,
		force_level = -1,
		inspector = true,
	},
	{
		file = "c7-20m-speed.png",
		layer = "logistics.haul_speed",
		caption = "20 m across, logistics.haul_speed - a layer declared in JSON, at half-metre cells",
		zoom = 0.0139,
		offset = {0, 16},
		grid = true,
		force_level = -1,
		inspector = true,
	},
}

// Terrain, hydrology, climate and forest over a real DEM. Every layer here
// except elevation is derived or modelled from it.
TERRAIN_SHOTS := [?]Shot {
	{
		file = "t01-elevation.png",
		layer = "terrain.elevation",
		caption = "terrain.elevation - real 90 m SRTM over the Sierra Nevada, 32 m to 3993 m",
		zoom = 22,
		shade = 0.55,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t02-slope.png",
		layer = "terrain.slope",
		caption = "terrain.slope - least squares plane through the six hex neighbours",
		zoom = 22,
		shade = 0.0,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t03-roughness.png",
		layer = "terrain.roughness",
		caption = "terrain.roughness - elevation range across each cell's neighbourhood",
		zoom = 22,
		shade = 0.0,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t04-hillshade.png",
		layer = "terrain.hillshade",
		caption = "terrain.hillshade - cached Lambert shading, so the renderer never relights",
		zoom = 22,
		shade = 0.0,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t05-flow.png",
		layer = "water.flow_accumulation",
		caption = "water.flow_accumulation - drainage routed downhill across the real DEM",
		zoom = 22,
		shade = 0.25,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t06-precip.png",
		layer = "climate.precip_annual",
		caption = "climate.precip_annual - orographic: wet western slope, dry eastern rain shadow",
		zoom = 40,
		shade = 0.30,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t07-temperature.png",
		layer = "climate.temp_mean_annual",
		caption = "climate.temp_mean_annual - latitude plus a 6.5 K/km lapse on the real terrain",
		zoom = 40,
		shade = 0.30,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t08-forest-density.png",
		layer = "forest.density",
		caption = "forest.density - canopy cover from warmth, water, rooting depth and steepness",
		zoom = 22,
		shade = 0.40,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t09-forest-composition.png",
		layer = "forest.composition",
		caption = "forest.composition - eight species fractions per cell, blended by abundance",
		zoom = 22,
		shade = 0.35,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t10-canopy-height.png",
		layer = "forest.canopy_height",
		caption = "forest.canopy_height - Chapman-Richards on stand age and site index",
		zoom = 22,
		shade = 0.35,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t11-landcover.png",
		layer = "land.cover",
		caption = "land.cover - classified from the modelled climate and cover",
		zoom = 22,
		shade = 0.30,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t12-soil-moisture.png",
		layer = "soil.moisture",
		caption = "soil.moisture - rainfall less evaporative demand, drained by slope",
		zoom = 22,
		shade = 0.30,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t13-fuel-moisture.png",
		layer = "fire.fuel_moisture",
		caption = "fire.fuel_moisture - the layer a fire model would read first",
		zoom = 22,
		shade = 0.30,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t14-zoom-3km.png",
		layer = "forest.density",
		caption = "3 km across - individual 100 m cells, the DEM's own resolution",
		zoom = 2.1,
		grid = true,
		shade = 0.40,
		force_level = -1,
		inspector = true,
	},
	{
		file = "t15-zoom-800m.png",
		layer = "terrain.elevation",
		caption = "800 m across - past the data's resolution; cells are flat because the source is",
		zoom = 0.56,
		grid = true,
		shade = 0.5,
		force_level = -1,
		inspector = true,
	},
}

// Real 1 m NAIP aerial photography over Miami, FL, ingested onto a 0.5 m hex
// grid: finer than the source, so each pixel covers about four cells.
IMAGERY_SHOTS := [?]Shot {
	{
		file = "i01-full.png",
		layer = "imagery.true_color",
		caption = "real 1 m NAIP aerial photography, ingested onto a 0.5 m hex grid",
		force_level = -1,
		inspector = true,
	},
	{
		file = "i02-200m.png",
		layer = "imagery.true_color",
		caption = "200 m across - individual roofs, driveways and pools",
		zoom = 0.14,
		force_level = -1,
		inspector = true,
	},
	{
		file = "i03-40m.png",
		layer = "imagery.true_color",
		caption = "40 m across - a single building",
		zoom = 0.028,
		force_level = -1,
		inspector = true,
	},
	{
		file = "i04-20m.png",
		layer = "imagery.true_color",
		caption = "20 m across, hex grid on - half-metre cells, each about a quarter of a source pixel",
		zoom = 0.0139,
		grid = true,
		force_level = -1,
		inspector = true,
	},
	{
		file = "i05-lod.png",
		layer = "imagery.true_color",
		caption = "same view, one pyramid level up: cells average four times the source pixels",
		zoom = 0.0139,
		grid = true,
		force_level = 1,
		fill = true,
		inspector = true,
	},
}
