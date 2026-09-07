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
	  "derive": [ "slope_aspect", "hillshade" ],
	  "build_pyramid": true
	}

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
	succeeded: int,
	failed:    int,
}

manifest_report_destroy :: proc(r: ^Manifest_Report, allocator := context.allocator) {
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

	// Custom layer declarations, if any.
	if _, has := obj["layers"]; has {
		added, _ := layers.parse_layer_manifest(w.registry, string(src), allocator)
		report.layers_added = added
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
		for path, fc in cache {
			features_destroy(fc)
			free(fc, context.allocator)
			delete(path, context.allocator)
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
		rep.message = fmt.aprintf("no layer named %q", layer_name, allocator = allocator)
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
	kind := layers.json_string(obj, "kind", format_from_extension(full))

	switch kind {
	case "raster":
		rep = load_raster_entry(w, obj, full, id, level, rep, allocator)
	case "vector":
		rep = load_vector_entry(w, obj, full, id, level, rep, cache, allocator)
	case:
		rep.message = fmt.aprintf("cannot tell what kind of file %q is; set \"kind\"", rel, allocator = allocator)
	}
	return
}

@(private)
format_from_extension :: proc(path: string) -> string {
	lower := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".tif"), strings.has_suffix(lower, ".tiff"):
		return "raster"
	case strings.has_suffix(lower, ".asc"), strings.has_suffix(lower, ".grd"):
		return "raster"
	case strings.has_suffix(lower, ".geojson"), strings.has_suffix(lower, ".json"):
		return "vector"
	}
	return ""
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
	crs: Maybe(geo.Projection)
	if epsg := int(layers.json_number(obj, "epsg", 0)); epsg > 0 {
		if p, ok := projection_for_epsg(epsg); ok {
			crs = p
		} else {
			rep.message = fmt.aprintf("EPSG:%d is not one this build knows", epsg, allocator = allocator)
			return
		}
	}

	raster: Raster
	lower := strings.to_lower(path, context.temp_allocator)
	if strings.has_suffix(lower, ".asc") || strings.has_suffix(lower, ".grd") {
		r, err := read_esri_ascii(path, crs.? or_else geo.proj_geographic())
		if err != .None {
			rep.message = fmt.aprintf("%v", err, allocator = allocator)
			return
		}
		raster = r
	} else {
		r, err := read_geotiff(path, crs)
		if err != .None {
			rep.message = fmt.aprintf("%v", err, allocator = allocator)
			return
		}
		raster = r
	}
	defer raster_destroy(&raster)

	opts := Options {
		level        = level,
		resample     = resample_from_name(layers.json_string(obj, "resample", "auto")),
		rule         = layers.aggregate_from_name(layers.json_string(obj, "rule", "none")),
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

	res, err := rasterize(w, &raster, id, opts)
	if err != .None {
		rep.message = fmt.aprintf("%v", err, allocator = allocator)
		return
	}
	rep.ok = true
	rep.cells_written = res.cells_written
	rep.message = fmt.aprintf(
		"%dx%d %v, ~%.0f m/px, %v -> %d cells",
		raster.width,
		raster.height,
		raster.kind,
		raster_ground_resolution(&raster),
		res.resample_used,
		res.cells_written,
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
	crs: Maybe(geo.Projection)
	if epsg := int(layers.json_number(obj, "epsg", 0)); epsg > 0 {
		if p, ok := projection_for_epsg(epsg); ok {
			crs = p
		}
	}

	fc: ^Feature_Collection
	if cached, hit := cache[path]; hit {
		fc = cached
	} else {
		read_start := time.now()
		parsed, err := read_geojson(path, crs, context.allocator)
		rep.read_seconds = time.duration_seconds(time.since(read_start))
		if err != .None {
			rep.message = fmt.aprintf("%v", err, allocator = allocator)
			return
		}
		fc = new(Feature_Collection, context.allocator)
		fc^ = parsed
		cache[strings.clone(path, context.allocator)] = fc
	}

	opts := Vector_Options {
		level              = level,
		measure            = measure_from_name(layers.json_string(obj, "measure", "value")),
		rule               = layers.aggregate_from_name(layers.json_string(obj, "rule", "none")),
		coverage_samples   = int(layers.json_number(obj, "coverage_samples", 7)),
		line_step_fraction = layers.json_number(obj, "line_step", 0.25),
		unit_scale         = layers.json_number(obj, "unit_scale", 1),
	}
	opts.width = width_source_from_json(obj, allocator)
	if layers.json_string(obj, "rule") == "" {
		opts.rule = .None // let the measure or the layer decide
	}
	opts.value = value_source_from_json(obj, allocator)
	opts.filter = filter_from_json(obj, allocator)
	defer delete(opts.filter, allocator)

	res, verr := vectorize(w, fc, id, opts)
	if verr != .None {
		rep.message = fmt.aprintf("%v", verr, allocator = allocator)
		return
	}

	points, lines, polys := feature_count_by_kind(fc)
	rep.ok = true
	rep.cells_written = res.cells_written
	rep.message = fmt.aprintf(
		"%d pt / %d line / %d poly, %d used / %d filtered / %d outside, width %.0f m -> %d cells",
		points,
		lines,
		polys,
		res.features_used,
		res.features_skipped,
		res.features_outside,
		res.max_width,
		res.cells_written,
		allocator = allocator,
	)
	return
}

@(private)
value_source_from_json :: proc(obj: json.Object, allocator := context.allocator) -> Value_Source {
	v, has := obj["value"]
	if !has {
		return constant_value(1)
	}
	vo, is_obj := v.(json.Object)
	if !is_obj {
		if n, is_num := layers.json_value_number(v); is_num {
			return constant_value(n)
		}
		return constant_value(1)
	}
	return value_source_from_object(vo, allocator)
}

@(private)
value_source_from_object :: proc(vo: json.Object, allocator := context.allocator) -> Value_Source {
	if _, has_const := vo["constant"]; has_const {
		return constant_value(layers.json_number(vo, "constant", 1))
	}
	if field := layers.json_string(vo, "field"); len(field) > 0 {
		return number_field(
			field,
			layers.json_number(vo, "scale", 1),
			layers.json_number(vo, "offset", 0),
			layers.json_number(vo, "fallback", 0),
		)
	}
	if field := layers.json_string(vo, "classify"); len(field) > 0 {
		classes := named_class_table(layers.json_string(vo, "table"))
		if classes == nil {
			classes = class_table_from_json(vo, allocator)
		}
		return classified_field(
			field,
			classes,
			layers.json_number(vo, "fallback", 0),
			layers.json_bool(vo, "skip_unclassified", true),
		)
	}
	return constant_value(1)
}

// "width_m": 30, or "width_m": { "classify": "type", "table": "ne_road_width" }
@(private)
width_source_from_json :: proc(obj: json.Object, allocator := context.allocator) -> Value_Source {
	v, has := obj["width_m"]
	if !has {
		return constant_value(0)
	}
	if n, is_num := layers.json_value_number(v); is_num {
		return constant_value(n)
	}
	if vo, is_obj := v.(json.Object); is_obj {
		return value_source_from_object(vo, allocator)
	}
	return constant_value(0)
}

@(private)
named_class_table :: proc(name: string) -> []Class_Rule {
	switch name {
	case "osm_highway":
		return OSM_HIGHWAY_CLASSES[:]
	case "osm_railway":
		return OSM_RAILWAY_CLASSES[:]
	case "osm_highway_speed":
		return OSM_HIGHWAY_SPEEDS[:]
	case "osm_landcover":
		return OSM_LANDCOVER_CLASSES[:]
	case "ne_road":
		return NE_ROAD_CLASSES[:]
	case "ne_road_speed":
		return NE_ROAD_SPEEDS[:]
	case "ne_water":
		return NE_WATER_CLASSES[:]
	case "ne_road_width":
		return NE_ROAD_WIDTHS[:]
	case "osm_highway_width":
		return OSM_HIGHWAY_WIDTHS[:]
	}
	return nil
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
resample_from_name :: proc(s: string) -> Resample {
	switch s {
	case "scatter":
		return .Scatter
	case "nearest", "gather_nearest":
		return .Gather_Nearest
	case "linear", "gather_linear", "bilinear":
		return .Gather_Linear
	}
	return .Auto
}

@(private)
measure_from_name :: proc(s: string) -> Measure {
	switch s {
	case "presence", "any":
		return .Presence
	case "count":
		return .Count
	case "density":
		return .Density
	case "coverage", "fraction":
		return .Coverage
	}
	return .Value
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
