package ingest

/*
Ready-made vocabularies for OpenStreetMap tags.

OSM is where road networks, building footprints and land use come from for most
of the world, and its tags are strings. These tables turn the common ones into
the numbers the standard catalogue's categorical layers expect, so getting a
road network in is a manifest entry rather than a research project.

They are ordinary data, listed in `CLASS_TABLES` so a manifest can name one. A
world using a national dataset with its own coding adds a row there, or spells
its table out inline with "classes".
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
