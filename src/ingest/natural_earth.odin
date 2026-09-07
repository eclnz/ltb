package ingest

/*
Vocabularies for Natural Earth, the public-domain global vector dataset.

Natural Earth ships coastlines, roads, rivers, lakes, urban areas and populated
places as GeoJSON at 1:10m, 1:50m and 1:110m. It is coarse next to OSM but
covers the whole world uniformly and needs no extraction step, which makes it
the quickest way to give a world real roads, water and settlement.

Its road classes live in a `type` attribute with its own vocabulary, so it needs
its own tables.
*/

// `type` values from ne_*_roads mapped onto `human.road_class`:
//   0 none  1 track  2 forestry road  3 minor  4 major  5 highway  6 motorway  7 rail
@(rodata)
NE_ROAD_CLASSES := [?]Class_Rule {
	{"Major Highway", 6},
	{"Beltway", 5},
	{"Bypass", 5},
	{"Secondary Highway", 4},
	{"Road", 3},
	{"Unknown", 3},
	{"Track", 1},
}

// Free-flow speed in km/h by the same `type` values.
@(rodata)
NE_ROAD_SPEEDS := [?]Class_Rule {
	{"Major Highway", 110},
	{"Beltway", 90},
	{"Bypass", 80},
	{"Secondary Highway", 80},
	{"Road", 60},
	{"Unknown", 60},
	{"Track", 25},
}

// `featurecla` values from ne_*_rivers_lake_centerlines and ne_*_lakes, mapped
// onto `land.cover`.
@(rodata)
NE_WATER_CLASSES := [?]Class_Rule {
	{"Lake", 0},
	{"Reservoir", 0},
	{"Alkaline Lake", 0},
	{"Playa", 3},
	{"Lake Centerline", 0},
	{"River", 0},
	{"Ferry Route", 0},
}
