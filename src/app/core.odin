/*
Package app wires the engine together: it builds a world from command-line
options, generates or ingests its data, sets up the simulation and reports on
what it made.

It deliberately knows nothing about drawing. The headless command links this
package alone and needs no graphics libraries at all; the windowed command adds
the renderer on top. Keeping the split at a package boundary means the
simulation can be run, profiled and tested on a machine with no display.
*/
package app

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import geo "ltb:geo"
import "ltb:ingest"
import "ltb:layers"
import "ltb:sim"
import "ltb:world"
import "ltb:worldgen"

App :: struct {
	registry: layers.Registry,
	store:    layers.Store,
	world:    world.World,
	sim:      sim.Sim,
	opts:     Options,
}

// Builds everything the front ends share. On success the caller owns `app` and
// must call `shutdown`.
startup :: proc(app: ^App, opts: Options) -> (ok: bool) {
	layers.registry_init(&app.registry)
	layers.register_standard_layers(&app.registry)
	layers.store_init(&app.store, &app.registry)
	app.opts = opts

	// A degree of latitude is about 111 km; longitude shrinks with the cosine
	// of latitude, but the world's bounds only need to be approximate since
	// the projection is centred on them anyway.
	half_deg_lat := opts.span_km / 111.0
	half_deg_lon := opts.span_km / (111.0 * max(0.15, math.cos(opts.lat * math.RAD_PER_DEG)))
	cfg := world.Config {
		name = "ltb",
		bounds = geo.Geo_Bounds {
			lat_min = opts.lat - half_deg_lat,
			lat_max = opts.lat + half_deg_lat,
			lon_min = opts.lon - half_deg_lon,
			lon_max = opts.lon + half_deg_lon,
		},
		base_cell_area = opts.cell_area,
		level_count = clamp(opts.levels, 1, world.MAX_LEVELS),
	}
	if !world.init(&app.world, cfg, &app.registry, &app.store) {
		fmt.eprintln("failed to build the world; check --cell-area and --levels")
		return false
	}

	report_world(&app.world, opts)

	// Generate a landscape, then overwrite parts of it with real data if any
	// was given. Generating first means an ingest that covers only part of the
	// region still leaves a coherent world around it.
	gen_start := time.now()
	params := worldgen.default_params()
	params.seed = opts.seed
	stats, gen_ok := worldgen.generate(&app.world, params)
	if !gen_ok {
		fmt.eprintln("world generation failed: the standard layer catalogue is missing entries")
		return false
	}
	fmt.printfln(
		"generated %d cells (%d land, %d forested) in %.2f s",
		stats.cells,
		stats.land_cells,
		stats.forested,
		time.duration_seconds(time.since(gen_start)),
	)

	if len(opts.load_path) > 0 {
		load_source(&app.world, opts.load_path, opts.load_layer)
	}

	report_store(&app.store, &app.registry)

	sim.init(&app.sim, &app.world, 0, opts.seed)
	sim.add_example_systems(&app.sim)
	app.sim.clock.days_per_tick = opts.days_per_tick
	ready := sim.start(&app.sim)
	for sys in app.sim.systems {
		if !sys.enabled {
			fmt.eprintfln("system %q disabled: no layer named %q", sys.name, sys.note)
		}
	}
	fmt.printfln("sim: %d of %d systems ready", ready, len(app.sim.systems))

	if opts.ticks > 0 {
		run_ticks(&app.sim, opts.ticks)
	}
	return true
}

shutdown :: proc(app: ^App) {
	sim.destroy(&app.sim)
	world.destroy(&app.world)
	layers.store_destroy(&app.store)
	layers.registry_destroy(&app.registry)
}

run_ticks :: proc(s: ^sim.Sim, n: int) {
	start := time.now()
	sim.run(s, n)
	sim.flush_pyramid(s)
	elapsed := time.duration_seconds(time.since(start))
	fmt.printfln(
		"simulated %d ticks (%.0f days, %.1f years) in %.2f s",
		n,
		s.clock.day,
		s.clock.day / 365.2425,
		elapsed,
	)
	for sys in s.systems {
		if sys.runs > 0 {
			fmt.printfln("  %-16s %6d runs, %8d cells last pass", sys.name, sys.runs, sys.cells_touched)
		}
	}
}

load_source :: proc(w: ^world.World, path, layer_name: string) {
	id, found := layers.lookup(w.registry, layer_name)
	if !found {
		fmt.eprintfln("no layer named %q; run --list-layers to see the catalogue", layer_name)
		return
	}

	raster: ingest.Raster
	if strings.has_suffix(path, ".asc") || strings.has_suffix(path, ".grd") {
		r, err := ingest.read_esri_ascii(path, geo.proj_geographic())
		if err != .None {
			fmt.eprintfln("could not read %s: %v", path, err)
			return
		}
		raster = r
	} else {
		r, err := ingest.read_geotiff(path)
		if err != .None {
			fmt.eprintfln("could not read %s: %v", path, err)
			return
		}
		raster = r
	}
	defer ingest.raster_destroy(&raster)

	b := ingest.raster_geo_bounds(&raster)
	fmt.printfln(
		"%s: %dx%d, %d band(s), %v, ~%.0f m/px, lat %.4f..%.4f lon %.4f..%.4f",
		path,
		raster.width,
		raster.height,
		raster.bands,
		raster.kind,
		ingest.raster_ground_resolution(&raster),
		b.lat_min,
		b.lat_max,
		b.lon_min,
		b.lon_max,
	)

	res, err := ingest.rasterize(w, &raster, id, ingest.Options{level = 0, fill_gaps = true})
	if err != .None {
		fmt.eprintfln("could not resample %s: %v", path, err)
		return
	}
	fmt.printfln(
		"  -> %s: %d cells written by %v (%d samples used, %d missing, %d gaps filled)",
		layer_name,
		res.cells_written,
		res.resample_used,
		res.samples_used,
		res.samples_missing,
		res.gap_filled,
	)
	world.build_pyramid(w, id, 0)

	// Terrain derivatives depend on elevation, so refresh them when it changes.
	if layer_name == "terrain.elevation" {
		slope, _ := layers.lookup(w.registry, "terrain.slope")
		aspect, _ := layers.lookup(w.registry, "terrain.aspect")
		shade, _ := layers.lookup(w.registry, "terrain.hillshade")
		ingest.derive_slope_aspect(w, id, slope, aspect, 0)
		ingest.derive_hillshade(w, slope, aspect, shade, 0)
		world.build_pyramid(w, slope, 0)
		world.build_pyramid(w, aspect, 0)
		world.build_pyramid(w, shade, 0)
	}
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

print_catalogue :: proc(r: ^layers.Registry) {
	group := ""
	for i in 0 ..< layers.layer_count(r) {
		d := layers.desc_of(r, layers.Layer_Id(i))
		if d.group != group {
			group = d.group
			fmt.printfln("\n[%s]", group)
		}
		comps := layers.desc_components(d)
		fmt.printfln(
			"  %-36s %-6v x%d  %-11v %-16v %s",
			d.name,
			d.kind,
			comps,
			d.semantic,
			d.aggregate,
			d.unit,
		)
	}
	fmt.printfln("\n%d layers", layers.layer_count(r))
}

report_world :: proc(w: ^world.World, opts: Options) {
	fmt.printfln("world: %v centred on %.4f, %.4f", w.projection.kind, opts.lat, opts.lon)
	fmt.printfln("       equal-area: %v", geo.is_equal_area(w.projection))
	for i in 0 ..< world.level_count(w) {
		lv := w.levels[i]
		ext := world.extent(w, i)
		fmt.printfln(
			"  L%d  cell %8.1f m across, %10.4f km^2, index %d x %d cells",
			i,
			lv.pitch,
			lv.cell_area / 1e6,
			ext.q1 - ext.q0 + 1,
			ext.r1 - ext.r0 + 1,
		)
	}
}

report_store :: proc(s: ^layers.Store, r: ^layers.Registry) {
	total_chunks := 0
	populated := 0
	for i in 0 ..< layers.layer_count(r) {
		id := layers.Layer_Id(i)
		n := 0
		for l in 0 ..< 16 {
			n += layers.count_chunks(s, id, u8(l))
		}
		if n > 0 {
			populated += 1
			total_chunks += n
		}
	}
	fmt.printfln(
		"store: %d layers with data, %d chunks, %.1f MiB resident",
		populated,
		total_chunks,
		f64(s.bytes_resident) / (1024.0 * 1024.0),
	)
}

// Prints a value range per populated layer, which is the quickest way to see
// whether a model or an ingest has gone wrong.
report_layers :: proc(w: ^world.World) {
	fmt.println("\nlayer summary at level 0:")
	for i in 0 ..< layers.layer_count(w.registry) {
		id := layers.Layer_Id(i)
		d := layers.desc_of(w.registry, id)
		cells := layers.collect_cells(w.store, id, 0, context.temp_allocator)
		defer delete(cells, context.temp_allocator)
		if len(cells) == 0 {
			continue
		}
		lo, hi, sum := cells[0].value, cells[0].value, 0.0
		for c in cells {
			lo = min(lo, c.value)
			hi = max(hi, c.value)
			sum += c.value
		}
		fmt.printfln(
			"  %-36s %9d cells  min %10.3f  mean %10.3f  max %10.3f  %s",
			d.name,
			len(cells),
			lo,
			sum / f64(len(cells)),
			hi,
			d.unit,
		)
		free_all(context.temp_allocator)
	}
}

// Layers that actually hold data, for the interactive layer cycle.
populated_layers :: proc(w: ^world.World, allocator := context.allocator) -> []layers.Layer_Id {
	out := make([dynamic]layers.Layer_Id, 0, 32, allocator)
	for i in 0 ..< layers.layer_count(w.registry) {
		id := layers.Layer_Id(i)
		if layers.count_chunks(w.store, id, 0) > 0 {
			append(&out, id)
		}
	}
	return out[:]
}

// Prints the catalogue without building a world, for `--list-layers`.
print_catalogue_only :: proc() {
	r: layers.Registry
	layers.registry_init(&r)
	defer layers.registry_destroy(&r)
	layers.register_standard_layers(&r)
	print_catalogue(&r)
}
