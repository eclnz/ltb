package ingest

import "core:mem"
import "core:strings"
import geo "ltb:geo"
import "ltb:layers"

/*
What this package can read, and how a name becomes a thing.

Every reader has the same shape -- a path and an optional CRS in, a `Raster` or a
`Feature_Collection` out -- so the choice of reader is a table lookup rather than
a chain of suffix tests. Before this existed the same list of extensions was
written out in four places (the manifest's format guess, the manifest's raster
branch, the app's drop-a-file path, and the viewer's file dialog), and adding a
format meant finding all four.

Adding one now means adding a row.
*/

// Everything that can go wrong between a file on disk and cells in a world. One
// enum rather than one per reader: every failure ends up in the same report
// line, and a caller that just wants to say what went wrong should not need to
// know which decoder produced it.
Ingest_Error :: enum {
	None,

	// Getting at the file
	File_Not_Found,
	// No reader claims this extension, and none was named.
	Unknown_Format,
	// The format carries no CRS of its own and none was supplied.
	Crs_Required,

	// GeoTIFF
	Not_Tiff,
	Unsupported_Layout,
	Unsupported_Sample,
	Decompression_Failed,
	No_Georeferencing,
	Unknown_Crs,

	// ESRI ASCII grid
	Bad_Header,
	Truncated,

	// GeoJSON and manifests
	Bad_Json,
	Not_A_Feature_Collection,
	Bad_Manifest,
	// A manifest named a resample, measure, rule or class table that does not
	// exist. Reported rather than defaulted: a typo silently resampled by the
	// wrong rule produces a plausible-looking layer holding the wrong numbers.
	Unknown_Name,

	// Resampling onto the grid
	Unknown_Layer,
	Too_Many_Cells,
	Bad_Raster,
	Component_Mismatch,
}

// `crs` overrides whatever the file claims. Formats that carry no CRS of their
// own require it and fail with `.Crs_Required` when it is absent, rather than
// assuming degrees for a grid that might be in metres.
Raster_Read_Proc :: proc(
	path: string,
	crs: Maybe(geo.Projection),
	allocator: mem.Allocator,
) -> (
	Raster,
	Ingest_Error,
)

Vector_Read_Proc :: proc(
	path: string,
	crs: Maybe(geo.Projection),
	allocator: mem.Allocator,
) -> (
	Feature_Collection,
	Ingest_Error,
)

Raster_Reader :: struct {
	name:       string,
	extensions: []string,
	read:       Raster_Read_Proc,
}

Vector_Reader :: struct {
	name:       string,
	extensions: []string,
	read:       Vector_Read_Proc,
}

RASTER_READERS := [?]Raster_Reader {
	{"GeoTIFF", {".tif", ".tiff"}, read_geotiff},
	{"ESRI ASCII grid", {".asc", ".grd"}, read_esri_ascii},
}

VECTOR_READERS := [?]Vector_Reader {
	{"GeoJSON", {".geojson", ".json"}, read_geojson},
}

// The reader that claims this path's extension.
raster_reader_for :: proc(path: string) -> (reader: Raster_Reader, ok: bool) {
	lower := strings.to_lower(path, context.temp_allocator)
	for r in RASTER_READERS {
		for ext in r.extensions {
			if strings.has_suffix(lower, ext) {
				return r, true
			}
		}
	}
	return {}, false
}

vector_reader_for :: proc(path: string) -> (reader: Vector_Reader, ok: bool) {
	lower := strings.to_lower(path, context.temp_allocator)
	for r in VECTOR_READERS {
		for ext in r.extensions {
			if strings.has_suffix(lower, ext) {
				return r, true
			}
		}
	}
	return {}, false
}

// Whether any reader here could open this path. What a file dialog wants, so
// that the list of openable files and the list of readable formats cannot drift
// apart.
is_readable :: proc(path: string) -> bool {
	_, is_raster := raster_reader_for(path)
	if is_raster {
		return true
	}
	_, is_vector := vector_reader_for(path)
	return is_vector
}

// ---------------------------------------------------------------------------
// Names in a manifest
// ---------------------------------------------------------------------------

/*
The names a manifest may use for this package's own enums.

The table type and the lookup live in `layers`, which sits below this package
and has the same problem with the same stakes: a name nobody recognises is
reported, never quietly replaced with a default.
*/
RESAMPLE_NAMES := [?]layers.Named(Resample) {
	{"auto", .Auto},
	{"scatter", .Scatter},
	{"nearest", .Gather_Nearest},
	{"gather_nearest", .Gather_Nearest},
	{"linear", .Gather_Linear},
	{"bilinear", .Gather_Linear},
	{"gather_linear", .Gather_Linear},
}

MEASURE_NAMES := [?]layers.Named(Measure) {
	{"presence", .Presence},
	{"any", .Presence},
	{"count", .Count},
	{"density", .Density},
	{"value", .Value},
	{"coverage", .Coverage},
	{"fraction", .Coverage},
}

// ---------------------------------------------------------------------------
// Class tables
// ---------------------------------------------------------------------------

// A named attribute vocabulary, so that a manifest can say
// "table": "osm_highway" instead of repeating thirty rules.
Named_Class_Table :: struct {
	name:  string,
	rules: []Class_Rule,
}

/*
The vocabularies this build ships with.

A world using a national dataset with its own coding adds a row here, or spells
the table out inline with "classes". Both are data; neither needs a new branch
in the manifest reader.
*/
CLASS_TABLES := [?]Named_Class_Table {
	{"osm_highway", OSM_HIGHWAY_CLASSES[:]},
	{"osm_railway", OSM_RAILWAY_CLASSES[:]},
	{"osm_highway_speed", OSM_HIGHWAY_SPEEDS[:]},
	{"osm_highway_width", OSM_HIGHWAY_WIDTHS[:]},
	{"osm_landcover", OSM_LANDCOVER_CLASSES[:]},
	{"ne_road", NE_ROAD_CLASSES[:]},
	{"ne_road_speed", NE_ROAD_SPEEDS[:]},
	{"ne_road_width", NE_ROAD_WIDTHS[:]},
	{"ne_water", NE_WATER_CLASSES[:]},
}

class_table_for :: proc(name: string) -> (rules: []Class_Rule, ok: bool) {
	for t in CLASS_TABLES {
		if t.name == name {
			return t.rules, true
		}
	}
	return nil, false
}
