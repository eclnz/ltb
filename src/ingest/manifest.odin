package ingest

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"
import "core:strings"
import geo "ltb:geo"
import "ltb:layers"
import "ltb:world"

/*
Declarative dataset import.

A world is assembled from a pile of unrelated downloads: a DEM here, a land
cover raster there, a road network as GeoJSON, council parcels as a shapefile.
The pile is described in a file rather than in code:

	{
	  "layers": [ ... optional custom layer declarations ... ],
	  "sources": [
	    { "path": "srtm.tif", "layer": "terrain.elevation" },

	    { "path": "landcover.tif", "layer": "land.cover",
	      "resample": "scatter", "rule": "majority" },

	    { "path": "roads.geojson", "layer": "human.road_class",
	      "measure": "value", "rule": "max",
	      "value": { "classify": "highway", "table": "osm_highway" },
	      "filter": [ { "key": "highway" } ] },

	    { "path": "roads.geojson", "layer": "human.road_density",
	      "measure": "density", "value": { "constant": 1 },
	      "unit_scale": 0.001 },

	    { "path": "buildings.geojson", "layer": "human.built_up",
	      "measure": "coverage", "coverage_samples": 19 }
	  ],
	  "derive": [ "slope_aspect", "hillshade", "bat_habitat" ],
	  "build_pyramid": true
	}

The derivations, in the order they are worth running: "slope_aspect" and
"hillshade" from an ingested DEM, "distance_to_water" from permanent water,
"edge_density" from canopy cover, and "bat_habitat", which runs the New Zealand
bat model over whatever the rest of the manifest managed to load. A derivation
computes what the sources imply rather than inventing what they do not cover: it
writes only where its own inputs are present.

Paths are resolved relative to the manifest. The format is inferred from the
extension unless "kind" says otherwise. Sources are independent: a source that
fails is reported and the rest still load.
*/

Manifest_Error :: enum {
	None,
	File_Not_Found,
	Bad_Json,
	Bad_Manifest,
}

Source_Report :: struct {
	path:          string,
	layer:         string,
	ok:            bool,
	message:       string,
	cells_written: int,
	seconds:       f64,
	// Time spent decoding the file, as opposed to resampling it. Zero when the
	// file was already in the manifest's cache.
	read_seconds:  f64,
}

Manifest_Report :: struct {
	sources:  []Source_Report,
	layers_added: int,
	// What the manifest's own "layers" block declared, including anything it
	// failed to declare.
	layers:    layers.Layer_Manifest_Report,
	succeeded: int,
	failed:    int,
}

manifest_report_destroy :: proc(r: ^Manifest_Report, allocator := context.allocator) {
	layers.layer_manifest_report_destroy(&r.layers, allocator)
	for s in r.sources {
		delete(s.message, allocator)
		delete(s.path, allocator)
		delete(s.layer, allocator)
	}
	delete(r.sources, allocator)
	r^ = {}
}

// Loads every source a manifest names into `w`.
//
// Layer declarations in the manifest are registered first, so a source can
// target a layer the manifest itself defines.
load_manifest :: proc(
	w: ^world.World,
	path: string,
	allocator := context.allocator,
) -> (
	report: Manifest_Report,
	err: Manifest_Error,
) {
	src, ferr := os.read_entire_file(path, context.allocator)
	if ferr != nil {
		return {}, .File_Not_Found
	}
	defer delete(src, context.allocator)

	root, jerr := json.parse_string(string(src), json.DEFAULT_SPECIFICATION, false, context.allocator)
	if jerr != nil {
		return {}, .Bad_Json
	}
	defer json.destroy_value(root, context.allocator)

	obj, is_obj := root.(json.Object)
	if !is_obj {
		return {}, .Bad_Manifest
	}

	// A manifest's paths are relative to the manifest, so a dataset directory
	// can be moved or shared without editing every entry.
	base := filepath.dir(path)

	// Custom layer declarations, if any. A declaration that could not be read is
	// carried into this manifest's report rather than dropped: its sources are
	// about to fail with "no layer named ...", and that is not the reason.
	if _, has := obj["layers"]; has {
		lrep, _ := layers.parse_layer_manifest(w.registry, string(src), allocator)
		report.layers_added = lrep.added
		report.layers = lrep
	}

	entries, has_sources := obj["sources"]
	if !has_sources {
		return report, .None
	}
	list, is_arr := entries.(json.Array)
	if !is_arr {
		return report, .Bad_Manifest
	}

	// One parsed copy per file. A manifest routinely draws several layers from
	// the same source, and these files run to tens of megabytes.
	cache := make(map[string]^Feature_Collection, 8, context.allocator)
	defer {
		for cached_path, fc in cache {
			features_destroy(fc)
			free(fc, context.allocator)
			delete(cached_path, context.allocator)
		}
		delete(cache)
	}

	reports := make([dynamic]Source_Report, 0, len(list), allocator)
	for item in list {
		sobj, ok := item.(json.Object)
		if !ok {
			continue
		}
		start := time.now()
		r := load_source_entry(w, sobj, base, &cache, allocator)
		r.seconds = time.duration_seconds(time.since(start))
		append(&reports, r)
	}
	report.sources = reports[:]
	for s in report.sources {
		if s.ok {
			report.succeeded += 1
		} else {
			report.failed += 1
		}
	}

	// Optional derived layers, once the inputs are in.
	if d, has := obj["derive"]; has {
		if arr, is_a := d.(json.Array); is_a {
			run_derivations(w, arr)
		}
	}

	if layers.json_bool(obj, "build_pyramid", true) {
		world.build_all(w, 0)
	}
	return report, .None
}

@(private)
load_source_entry :: proc(
	w: ^world.World,
	obj: json.Object,
	base: string,
	cache: ^map[string]^Feature_Collection,
	allocator := context.allocator,
) -> (
	rep: Source_Report,
) {
	rel := layers.json_string(obj, "path")
	layer_name := layers.json_string(obj, "layer")
	// Cloned, because these point into the parsed manifest, which is freed
	// before the report is read.
	rep.path = strings.clone(rel, allocator)
	rep.layer = strings.clone(layer_name, allocator)

	if len(rel) == 0 || len(layer_name) == 0 {
		rep.message = strings.clone("a source needs both \"path\" and \"layer\"", allocator)
		return
	}
	id, found := layers.lookup(w.registry, layer_name)
	if !found {
		report_unknown(&rep, "layer", layer_name, allocator)
		return
	}

	full := rel
	if !filepath.is_abs(rel) {
		joined, jerr := filepath.join({base, rel}, context.temp_allocator)
		if jerr != nil {
			rep.message = strings.clone("could not resolve the path", allocator)
			return
		}
		full = joined
	}
	defer if !filepath.is_abs(rel) {
		delete(full, context.temp_allocator)
	}

	level := int(layers.json_number(obj, "level", 0))

	// "kind" forces the branch; without it the reader tables decide, so a format
	// added there needs no change here.
	switch layers.json_string(obj, "kind") {
	case "raster":
		return load_raster_entry(w, obj, full, id, level, rep, allocator)
	case "vector":
		return load_vector_entry(w, obj, full, id, level, rep, cache, allocator)
	case "":
		if _, is_raster := raster_reader_for(full); is_raster {
			return load_raster_entry(w, obj, full, id, level, rep, allocator)
		}
		if _, is_vector := vector_reader_for(full); is_vector {
			return load_vector_entry(w, obj, full, id, level, rep, cache, allocator)
		}
		report_error(&rep, .Unknown_Format, allocator)
	case:
		report_unknown(&rep, "kind", layers.json_string(obj, "kind"), allocator)
	}
	return
}

// ---------------------------------------------------------------------------
// Reporting a failure
//
// Every failed source ends the same way: `ok` stays false and `message` says
// why. These are the two shapes that takes.
// ---------------------------------------------------------------------------

@(private)
report_error :: proc(rep: ^Source_Report, err: Ingest_Error, allocator := context.allocator) {
	rep.ok = false
	rep.message = fmt.aprintf("%v", err, allocator = allocator)
}

// For a manifest that named something this build does not have. The name is
// quoted back, because a typo is the usual cause and seeing it is the fix.
@(private)
report_unknown :: proc(rep: ^Source_Report, what, name: string, allocator := context.allocator) {
	rep.ok = false
	rep.message = fmt.aprintf("no %s called %q", what, name, allocator = allocator)
}

/*
A source that read and resampled cleanly and wrote no cells.

No step failed, so nothing below can report it -- but the entry exists to put
data in a layer and no data arrived, which is the failure the author needs to
see. It is nearly always a mismatch of extent or scale: a world smaller than
the source's sampling, or a source that covers somewhere else. Reported as a
failed source so the count at the end of the run is the number of layers that
actually got something.
*/
@(private)
empty_note :: proc(cells_written: int) -> string {
	return cells_written > 0 ? "" : "  -- nothing in this file reaches this world"
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

// The CRS a source declares with "epsg", if any.
@(private)
crs_from_json :: proc(obj: json.Object) -> (crs: Maybe(geo.Projection), epsg: int, ok: bool) {
	epsg = int(layers.json_number(obj, "epsg", 0))
	if epsg <= 0 {
		return nil, 0, true
	}
	p, known := projection_for_epsg(epsg)
	if !known {
		return nil, epsg, false
	}
	return p, epsg, true
}

// An enum named in the manifest. Returns the name as well, so a caller can
// quote it back when it is not one this build knows.
@(private)
named_option :: proc(
	obj: json.Object,
	key, default: string,
	table: []layers.Named($E),
) -> (
	value: E,
	name: string,
	ok: bool,
) {
	name = layers.json_string(obj, key, default)
	value, ok = layers.lookup_name(name, table)
	return
}

@(private)
load_raster_entry :: proc(
	w: ^world.World,
	obj: json.Object,
	path: string,
	id: layers.Layer_Id,
	level: int,
	rep_in: Source_Report,
	allocator := context.allocator,
) -> (
	rep: Source_Report,
) {
	rep = rep_in
	crs, epsg, crs_ok := crs_from_json(obj)
	if !crs_ok {
		rep.message = fmt.aprintf("EPSG:%d is not one this build knows", epsg, allocator = allocator)
		return
	}

	resample, resample_name, resample_ok := named_option(obj, "resample", "auto", RESAMPLE_NAMES[:])
	if !resample_ok {
		report_unknown(&rep, "resample", resample_name, allocator)
		return
	}
	rule_name := layers.json_string(obj, "rule", "none")
	rule, rule_ok := layers.aggregate_lookup(rule_name)
	if !rule_ok {
		report_unknown(&rep, "rule", rule_name, allocator)
		return
	}

	reader, have_reader := raster_reader_for(path)
	if !have_reader {
		report_error(&rep, .Unknown_Format, allocator)
		return
	}
	raster, err := reader.read(path, crs, context.allocator)
	if err != .None {
		report_error(&rep, err, allocator)
		return
	}
	defer raster_destroy(&raster)

	opts := Raster_Options {
		level        = level,
		resample     = resample,
		rule         = rule,
		value_scale  = layers.json_number(obj, "scale", 1),
		value_offset = layers.json_number(obj, "offset", 0),
		fill_gaps    = layers.json_bool(obj, "fill_gaps", true),
	}
	if b, has := obj["band"]; has {
		if n, is_num := layers.json_value_number(b); is_num {
			bands := make([]int, 1, context.temp_allocator)
			bands[0] = int(n)
			opts.bands = bands
		}
	}
	if nd, has := obj["nodata"]; has {
		if n, is_num := layers.json_value_number(nd); is_num {
			raster.has_nodata = true
			raster.nodata = n
		}
	}

	res, rerr := rasterize(w, &raster, id, opts)
	if rerr == .Source_Too_Coarse {
		// The one error whose numbers are the whole message: knowing the source
		// is too coarse is useless without knowing by how much.
		rep.ok = false
		rep.message = fmt.aprintf(
			"%s %dx%d %v -- one %.0f m pixel spans %.0f of this world's %.2f m cells; too coarse to resample onto it",
			reader.name,
			raster.width,
			raster.height,
			raster.kind,
			res.source_pitch,
			res.source_pitch / res.cell_pitch,
			res.cell_pitch,
			allocator = allocator,
		)
		return
	}
	if rerr != .None {
		report_error(&rep, rerr, allocator)
		return
	}
	rep.ok = res.cells_written > 0
	rep.cells_written = res.cells_written
	rep.message = fmt.aprintf(
		"%s %dx%d %v, ~%.0f m/px, %v -> %d cells%s",
		reader.name,
		raster.width,
		raster.height,
		raster.kind,
		res.source_pitch,
		res.resample_used,
		res.cells_written,
		empty_note(res.cells_written),
		allocator = allocator,
	)
	return
}

@(private)
load_vector_entry :: proc(
	w: ^world.World,
	obj: json.Object,
	path: string,
	id: layers.Layer_Id,
	level: int,
	rep_in: Source_Report,
	cache: ^map[string]^Feature_Collection,
	allocator := context.allocator,
) -> (
	rep: Source_Report,
) {
	rep = rep_in
	crs, epsg, crs_ok := crs_from_json(obj)
	if !crs_ok {
		rep.message = fmt.aprintf("EPSG:%d is not one this build knows", epsg, allocator = allocator)
		return
	}

	measure, measure_name, measure_ok := named_option(obj, "measure", "value", MEASURE_NAMES[:])
	if !measure_ok {
		report_unknown(&rep, "measure", measure_name, allocator)
		return
	}
	// An unset rule lets the measure or the layer decide; a named one must exist.
	rule := layers.Aggregate.None
	if rule_name := layers.json_string(obj, "rule"); len(rule_name) > 0 {
		known: bool
		rule, known = layers.aggregate_lookup(rule_name)
		if !known {
			report_unknown(&rep, "rule", rule_name, allocator)
			return
		}
	}

	value, value_bad, value_ok := value_source_at(obj, "value", 1, allocator)
	if !value_ok {
		report_unknown(&rep, "class table", value_bad, allocator)
		return
	}
	width, width_bad, width_ok := value_source_at(obj, "width_m", 0, allocator)
	if !width_ok {
		report_unknown(&rep, "class table", width_bad, allocator)
		return
	}

	fc: ^Feature_Collection
	if cached, hit := cache[path]; hit {
		fc = cached
	} else {
		reader, have_reader := vector_reader_for(path)
		if !have_reader {
			report_error(&rep, .Unknown_Format, allocator)
			return
		}
		read_start := time.now()
		parsed, err := reader.read(path, crs, context.allocator)
		rep.read_seconds = time.duration_seconds(time.since(read_start))
		if err != .None {
			report_error(&rep, err, allocator)
			return
		}
		fc = new(Feature_Collection, context.allocator)
		fc^ = parsed
		cache[strings.clone(path, context.allocator)] = fc
	}

	opts := Vector_Options {
		level              = level,
		measure            = measure,
		rule               = rule,
		value              = value,
		width              = width,
		coverage_samples   = int(layers.json_number(obj, "coverage_samples", 7)),
		line_step_fraction = layers.json_number(obj, "line_step", 0.25),
		unit_scale         = layers.json_number(obj, "unit_scale", 1),
	}
	opts.filter = filter_from_json(obj, allocator)
	defer delete(opts.filter, allocator)

	res, verr := vectorize(w, fc, id, opts)
	if verr != .None {
		report_error(&rep, verr, allocator)
		return
	}

	points, lines, polys := feature_count_by_kind(fc)
	rep.ok = res.cells_written > 0
	rep.cells_written = res.cells_written
	rep.message = fmt.aprintf(
		"%d pt / %d line / %d poly, %d used / %d filtered / %d outside, width %.0f m -> %d cells%s",
		points,
		lines,
		polys,
		res.features_used,
		res.features_skipped,
		res.features_outside,
		res.max_width,
		res.cells_written,
		empty_note(res.cells_written),
		allocator = allocator,
	)
	return
}

// ---------------------------------------------------------------------------
// Value sources
// ---------------------------------------------------------------------------

/*
The value source at `key`, which may be a bare number or an object:

	"value": 1
	"value": { "field": "lanes", "scale": 3.5 }
	"value": { "classify": "highway", "table": "osm_highway" }

`ok` is false only when a named class table does not exist, in which case
`bad_name` is the name that was asked for. An absent key is not an error: it
means `default_constant`, which is what "width_m": 0 -- centrelines only -- and
"value": 1 -- count each feature once -- are.
*/
@(private)
value_source_at :: proc(
	obj: json.Object,
	key: string,
	default_constant: f64,
	allocator := context.allocator,
) -> (
	src: Value_Source,
	bad_name: string,
	ok: bool,
) {
	v, has := obj[key]
	if !has {
		return constant_value(default_constant), "", true
	}
	if n, is_num := layers.json_value_number(v); is_num {
		return constant_value(n), "", true
	}
	vo, is_obj := v.(json.Object)
	if !is_obj {
		return constant_value(default_constant), "", true
	}

	if _, has_const := vo["constant"]; has_const {
		return constant_value(layers.json_number(vo, "constant", default_constant)), "", true
	}
	if field := layers.json_string(vo, "field"); len(field) > 0 {
		return number_field(
				field,
				layers.json_number(vo, "scale", 1),
				layers.json_number(vo, "offset", 0),
				layers.json_number(vo, "fallback", 0),
			),
			"",
			true
	}
	if field := layers.json_string(vo, "classify"); len(field) > 0 {
		classes: []Class_Rule
		if name := layers.json_string(vo, "table"); len(name) > 0 {
			known: bool
			classes, known = class_table_for(name)
			if !known {
				return {}, name, false
			}
		} else {
			classes = class_table_from_json(vo, allocator)
		}
		return classified_field(
				field,
				classes,
				layers.json_number(vo, "fallback", 0),
				layers.json_bool(vo, "skip_unclassified", true),
			),
			"",
			true
	}
	return constant_value(default_constant), "", true
}

// { "classify": "surface", "classes": { "asphalt": 1, "gravel": 0.6 } }
@(private)
class_table_from_json :: proc(vo: json.Object, allocator := context.allocator) -> []Class_Rule {
	entry, has := vo["classes"]
	if !has {
		return nil
	}
	table, is_obj := entry.(json.Object)
	if !is_obj {
		return nil
	}
	out := make([dynamic]Class_Rule, 0, len(table), allocator)
	for key, value in table {
		if n, is_num := layers.json_value_number(value); is_num {
			append(&out, Class_Rule{strings.clone(key, allocator), n})
		}
	}
	return out[:]
}

// "filter": [ { "key": "highway" }, { "key": "access", "not": ["private"] } ]
@(private)
filter_from_json :: proc(obj: json.Object, allocator := context.allocator) -> []Filter_Clause {
	entry, has := obj["filter"]
	if !has {
		return nil
	}
	arr, is_arr := entry.(json.Array)
	if !is_arr {
		return nil
	}
	out := make([dynamic]Filter_Clause, 0, len(arr), allocator)
	for item in arr {
		co, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		key := layers.json_string(co, "key")
		if len(key) == 0 {
			continue
		}
		clause := Filter_Clause {
			key = strings.clone(key, allocator),
		}
		values_key := "is"
		if _, has_not := co["not"]; has_not {
			clause.negate = true
			values_key = "not"
		}
		if vals, has_vals := co[values_key]; has_vals {
			if va, is_va := vals.(json.Array); is_va {
				list := make([dynamic]string, 0, len(va), allocator)
				for v in va {
					if s, is_str := v.(json.String); is_str {
						append(&list, strings.clone(string(s), allocator))
					}
				}
				clause.any_of = list[:]
			}
		}
		append(&out, clause)
	}
	return out[:]
}

@(private)
run_derivations :: proc(w: ^world.World, arr: json.Array) {
	elevation, has_elev := layers.lookup(w.registry, "terrain.elevation")
	slope, _ := layers.lookup(w.registry, "terrain.slope")
	aspect, _ := layers.lookup(w.registry, "terrain.aspect")
	shade, _ := layers.lookup(w.registry, "terrain.hillshade")

	for item in arr {
		s, ok := item.(json.String)
		if !ok {
			continue
		}
		switch string(s) {
		case "slope_aspect":
			if has_elev {
				derive_slope_aspect(w, elevation, slope, aspect, 0)
			}
		case "hillshade":
			derive_hillshade(w, slope, aspect, shade, 0)
		case "edge_density":
			canopy, has_canopy := layers.lookup(w.registry, "forest.density")
			edge, has_edge := layers.lookup(w.registry, "forest.edge_density")
			if has_canopy && has_edge {
				derive_edge_density(w, canopy, edge, 0)
			}
		case "distance_to_water":
			water, has_water := layers.lookup(w.registry, "water.permanent")
			dist, has_dist := layers.lookup(w.registry, "water.distance_to_water")
			if has_water && has_dist {
				// Restrict the search to cells canopy cover reached, when there
				// is any; otherwise let it run over the whole region.
				canopy, has_canopy := layers.lookup(w.registry, "forest.density")
				if !has_canopy {
					canopy = layers.INVALID_LAYER
				}
				derive_distance_to_water(w, water, dist, canopy, 0)
			}
		case "bat_habitat":
			// Runs its own edge-density and distance-to-water passes
			// first, so it stands alone.
			derive_bat_habitat(w, 0)
		}
	}
}

// The EPSG codes the engine can build a projection for. Kept in one place so
// manifests, GeoTIFF keys and future readers agree.
projection_for_epsg :: proc(epsg: int) -> (geo.Projection, bool) {
	switch {
	case epsg == 4326:
		return geo.proj_geographic(), true
	case epsg == 3857 || epsg == 900913 || epsg == 102100:
		return geo.proj_web_mercator(), true
	case epsg >= 32601 && epsg <= 32660:
		return geo.proj_utm(epsg - 32600, true), true
	case epsg >= 32701 && epsg <= 32760:
		return geo.proj_utm(epsg - 32700, false), true
	case epsg >= 26901 && epsg <= 26923:
		return geo.proj_utm(epsg - 26900, true, geo.GRS80), true
	case epsg == 3035:
		return geo.proj_laea(52, 10, geo.GRS80, 4_321_000, 3_210_000), true
	case epsg == 2193:
		return geo.proj_transverse_mercator(173, 0.9996, geo.GRS80, 1_600_000, 10_000_000), true
	case epsg == 5070 || epsg == 5069:
		return geo.proj_albers(23, -96, 29.5, 45.5, geo.GRS80), true
	case epsg == 3577:
		return geo.proj_albers(0, 132, -18, -36, geo.GRS80), true
	}
	return {}, false
}
