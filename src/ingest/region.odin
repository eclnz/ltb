package ingest

import "core:encoding/json"
import "core:os"
import "core:strings"
import "ltb:layers"

/*
Where a manifest's data sits on Earth.

A manifest lists its sources but not the ground they cover, so opening one used
to mean knowing its latitude, span and cell size in advance and repeating them
on the command line. An optional "region" block carries them with the dataset:

	"region": {
	  "title": "Miami, FL -- 1 m NAIP aerial photography",
	  "lat": 25.7916, "lon": -80.3638, "span_km": 1.3,
	  "cell_area": 0.2165, "levels": 12,
	  "layer": "imagery.true_color"
	}

Every field is optional, and one that is absent leaves whatever the caller
already had. A manifest can therefore pin only the parts it cares about: a
DEM that suits any cell size need only give its centre and span.
*/
Region :: struct {
	// Human-readable name for the dataset, shown in the viewer's File menu.
	// Empty when the manifest does not name itself.
	title:     string,
	// Layer the viewer should open on. A dataset assembled to show its roads
	// would otherwise open on whatever elevation happens to be underneath.
	layer:     string,
	lat:       Maybe(f64),
	lon:       Maybe(f64),
	span_km:   Maybe(f64),
	cell_area: Maybe(f64),
	levels:    Maybe(int),
}

region_destroy :: proc(r: ^Region, allocator := context.allocator) {
	delete(r.title, allocator)
	delete(r.layer, allocator)
	r^ = {}
}

/*
Reads a manifest's "region" block without loading any of its data.

`ok` is false when the file is not a manifest at all, which is how the dataset
browser tells a manifest apart from any other .json it finds. A manifest with
no "region" block is still a manifest: it returns ok with every field unset.
*/
read_region :: proc(path: string, allocator := context.allocator) -> (r: Region, ok: bool) {
	src, ferr := os.read_entire_file(path, context.temp_allocator)
	if ferr != nil {
		return {}, false
	}
	defer delete(src, context.temp_allocator)

	root, jerr := json.parse_string(string(src), json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if jerr != nil {
		return {}, false
	}
	defer json.destroy_value(root, context.temp_allocator)

	obj, is_obj := root.(json.Object)
	if !is_obj {
		return {}, false
	}
	// "sources" is what makes a file a dataset manifest rather than, say, a
	// bare layer catalogue or a GeoJSON feature collection.
	if _, has_sources := obj["sources"]; !has_sources {
		return {}, false
	}

	ok = true
	rv, has_region := obj["region"]
	if !has_region {
		return
	}
	robj, region_is_obj := rv.(json.Object)
	if !region_is_obj {
		return
	}

	// Cloned, because the parsed document is freed on the way out.
	r.title = strings.clone(layers.json_string(robj, "title"), allocator)
	r.layer = strings.clone(layers.json_string(robj, "layer"), allocator)
	if v, has := robj["lat"]; has {
		if n, got := layers.json_value_number(v); got {r.lat = n}
	}
	if v, has := robj["lon"]; has {
		if n, got := layers.json_value_number(v); got {r.lon = n}
	}
	if v, has := robj["span_km"]; has {
		if n, got := layers.json_value_number(v); got {r.span_km = n}
	}
	if v, has := robj["cell_area"]; has {
		if n, got := layers.json_value_number(v); got {r.cell_area = n}
	}
	if v, has := robj["levels"]; has {
		if n, got := layers.json_value_number(v); got {r.levels = int(n)}
	}
	return
}
