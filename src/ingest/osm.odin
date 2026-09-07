package ingest

import "ltb:layers"
import "ltb:world"

/*
Ready-made vocabularies for OpenStreetMap tags.

OSM is where road networks, building footprints and land use come from for most
of the world, and its tags are strings. These tables turn the common ones into
the numbers the standard catalogue's categorical layers expect, so getting a
road network in is a call rather than a research project.

They are ordinary data. A world using a national dataset with its own coding
declares its own tables the same way.
*/

// `highway` values mapped onto `human.road_class`:
//   0 none  1 track  2 forestry road  3 minor  4 major  5 highway  6 motorway  7 rail
@(rodata)
OSM_HIGHWAY_CLASSES := [?]Class_Rule {
	{"motorway", 6},
	{"motorway_link", 6},
	{"trunk", 5},
	{"trunk_link", 5},
	{"primary", 5},
	{"primary_link", 5},
	{"secondary", 4},
	{"secondary_link", 4},
	{"tertiary", 4},
	{"tertiary_link", 4},
	{"unclassified", 3},
	{"residential", 3},
	{"living_street", 3},
	{"service", 3},
	{"track", 1},
}

// `railway` values, all of which land on the single rail class.
@(rodata)
OSM_RAILWAY_CLASSES := [?]Class_Rule {
	{"rail", 7},
	{"light_rail", 7},
	{"narrow_gauge", 7},
	{"tram", 7},
	{"subway", 7},
}

// Design speed in km/h by `highway` value, for travel-time and haulage costs.
// These are free-flow speeds on a decent surface, not limits.
@(rodata)
OSM_HIGHWAY_SPEEDS := [?]Class_Rule {
	{"motorway", 100},
	{"motorway_link", 60},
	{"trunk", 85},
	{"trunk_link", 50},
	{"primary", 75},
	{"primary_link", 45},
	{"secondary", 65},
	{"secondary_link", 40},
	{"tertiary", 55},
	{"tertiary_link", 35},
	{"unclassified", 45},
	{"residential", 30},
	{"living_street", 15},
	{"service", 20},
	{"track", 15},
	{"path", 5},
	{"footway", 4},
}

// `landuse` and `natural` values mapped onto `land.cover`.
@(rodata)
OSM_LANDCOVER_CLASSES := [?]Class_Rule {
	{"water", 0},
	{"reservoir", 0},
	{"basin", 0},
	{"glacier", 1},
	{"bare_rock", 2},
	{"scree", 2},
	{"shingle", 2},
	{"sand", 3},
	{"beach", 3},
	{"heath", 6},
	{"scrub", 6},
	{"grass", 5},
	{"grassland", 5},
	{"meadow", 5},
	{"wetland", 7},
	{"marsh", 7},
	{"farmland", 8},
	{"farmyard", 8},
	{"allotments", 8},
	{"wood", 11},
	{"forest", 12}, // `landuse=forest` is managed forest; `natural=wood` is not
	{"orchard", 17},
	{"vineyard", 17},
	{"residential", 13},
	{"retail", 13},
	{"commercial", 14},
	{"industrial", 14},
	{"railway", 15},
	{"quarry", 16},
	{"military", 14},
	{"pasture", 18},
}

// Convenience wrappers. Each is a few lines; they exist so the common case
// reads as one call, and to document which `Measure` suits which feature type.

// Highest road class touching each cell. Class is a label, so it takes the
// maximum rather than an average: a cell with a motorway and a driveway is a
// motorway cell.
ingest_osm_road_class :: proc(
	w: ^world.World,
	fc: ^Feature_Collection,
	layer: layers.Layer_Id,
	level := 0,
) -> (
	Vector_Result,
	Error,
) {
	return vectorize(
		w,
		fc,
		layer,
		Vector_Options {
			level = level,
			measure = .Value,
			rule = .Max,
			value = classified_field("highway", OSM_HIGHWAY_CLASSES[:]),
		},
	)
}

// Kilometres of road per square kilometre. The layer's own scale converts the
// accumulated metres, so pass a layer declared in km/km2.
ingest_osm_road_density :: proc(
	w: ^world.World,
	fc: ^Feature_Collection,
	layer: layers.Layer_Id,
	level := 0,
) -> (
	Vector_Result,
	Error,
) {
	return vectorize(
		w,
		fc,
		layer,
		Vector_Options {
			level = level,
			measure = .Density,
			rule = .Sum,
			value = constant_value(1),
			// metres accumulated per km2; the layer wants km/km2
			filter = nil,
		},
	)
}

// Fraction of each cell under building footprints.
ingest_osm_built_up :: proc(
	w: ^world.World,
	fc: ^Feature_Collection,
	layer: layers.Layer_Id,
	level := 0,
) -> (
	Vector_Result,
	Error,
) {
	return vectorize(
		w,
		fc,
		layer,
		Vector_Options {
			level = level,
			measure = .Coverage,
			rule = .Sum,
			value = constant_value(1),
			coverage_samples = 19,
		},
	)
}

// Land cover from `landuse`, falling back to `natural` where the first is
// absent. Two passes, because a feature can carry either tag.
ingest_osm_landcover :: proc(
	w: ^world.World,
	fc: ^Feature_Collection,
	layer: layers.Layer_Id,
	level := 0,
) -> (
	res: Vector_Result,
	err: Error,
) {
	for field in ([2]string{"natural", "landuse"}) {
		r, e := vectorize(
			w,
			fc,
			layer,
			Vector_Options {
				level = level,
				measure = .Value,
				rule = .Majority,
				value = classified_field(field, OSM_LANDCOVER_CLASSES[:]),
			},
		)
		if e != .None {
			return res, e
		}
		res.cells_written += r.cells_written
		res.features_used += r.features_used
		res.features_skipped += r.features_skipped
	}
	return res, .None
}

// Carriageway width in metres by `highway` value.
@(rodata)
OSM_HIGHWAY_WIDTHS := [?]Class_Rule {
	{"motorway", 32},
	{"motorway_link", 12},
	{"trunk", 22},
	{"trunk_link", 10},
	{"primary", 18},
	{"primary_link", 9},
	{"secondary", 14},
	{"secondary_link", 8},
	{"tertiary", 11},
	{"tertiary_link", 7},
	{"unclassified", 8},
	{"residential", 8},
	{"living_street", 6},
	{"service", 5},
	{"track", 4},
	{"path", 2},
	{"footway", 2},
}
