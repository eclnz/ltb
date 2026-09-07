package ingest

/*
Vocabularies for the New Zealand national datasets.

The Land Cover Database is the country's land cover map, revised every five
years by Manaaki Whenua from satellite imagery and published on the LRIS portal.
Its classes are the vocabulary that everything else in New Zealand land
management is described against, so the fastest way to give a region real
vegetation is to map its class names onto the engine's layers directly.

`Name_2018` is used as the key rather than `Class_2018`, because the engine
classifies on text attributes and because the names have been stable across
LCDB versions while the numeric codes are only stable within one.

The structural tables -- canopy cover, canopy height, emergent height, stand age
-- are *priors*, not measurements. A polygon labelled "Indigenous Forest" is
somewhere between a stunted subalpine stand and forty-metre rimu, and this says
only which is more likely. They exist so the bat model has something defensible
to run on before anyone has flown lidar over the region; ingest a real canopy
height model and it overrides them, since the model only fills what is missing.
*/

// LCDB `Name_2018` mapped onto the LCDB class codes, so `nz.lcdb_class` can be
// filled from the name.
@(rodata)
NZ_LCDB_CODES := [?]Class_Rule {
	{"Built-up Area (settlement)", 1},
	{"Urban Parkland/Open Space", 2},
	{"Transport Infrastructure", 5},
	{"Surface Mine or Dump", 6},
	{"Sand or Gravel", 10},
	{"Landslide", 12},
	{"Permanent Snow and Ice", 14},
	{"Alpine Grass/Herbfield", 15},
	{"Gravel or Rock", 16},
	{"Lake or Pond", 20},
	{"River", 21},
	{"Estuarine Open Water", 22},
	{"Short-rotation Cropland", 30},
	{"Orchard, Vineyard or Other Perennial Crop", 33},
	{"High Producing Exotic Grassland", 40},
	{"Low Producing Grassland", 41},
	{"Tall Tussock Grassland", 43},
	{"Depleted Grassland", 44},
	{"Herbaceous Freshwater Vegetation", 45},
	{"Herbaceous Saline Vegetation", 46},
	{"Flaxland", 47},
	{"Fernland", 50},
	{"Gorse and/or Broom", 51},
	{"Manuka and/or Kanuka", 52},
	{"Broadleaved Indigenous Hardwoods", 54},
	{"Sub Alpine Shrubland", 55},
	{"Mixed Exotic Shrubland", 56},
	{"Matagouri or Grey Scrub", 58},
	{"Forest - Harvested", 64},
	{"Deciduous Hardwoods", 68},
	{"Indigenous Forest", 69},
	{"Mangrove", 70},
	{"Exotic Forest", 71},
}

// LCDB `Name_2018` mapped onto the engine's generic `land.cover` classes, so a
// New Zealand region reads the same as any other to code that does not know
// about LCDB.
@(rodata)
NZ_LCDB_LANDCOVER := [?]Class_Rule {
	{"Built-up Area (settlement)", 13},
	{"Urban Parkland/Open Space", 5},
	{"Transport Infrastructure", 15},
	{"Surface Mine or Dump", 16},
	{"Sand or Gravel", 3},
	{"Landslide", 2},
	{"Permanent Snow and Ice", 1},
	{"Alpine Grass/Herbfield", 4},
	{"Gravel or Rock", 2},
	{"Lake or Pond", 0},
	{"River", 0},
	{"Estuarine Open Water", 0},
	{"Short-rotation Cropland", 8},
	{"Orchard, Vineyard or Other Perennial Crop", 17},
	{"High Producing Exotic Grassland", 18},
	{"Low Producing Grassland", 5},
	{"Tall Tussock Grassland", 5},
	{"Depleted Grassland", 4},
	{"Herbaceous Freshwater Vegetation", 7},
	{"Herbaceous Saline Vegetation", 7},
	{"Flaxland", 7},
	{"Fernland", 6},
	{"Gorse and/or Broom", 6},
	{"Manuka and/or Kanuka", 6},
	{"Broadleaved Indigenous Hardwoods", 9},
	{"Sub Alpine Shrubland", 6},
	{"Mixed Exotic Shrubland", 6},
	{"Matagouri or Grey Scrub", 6},
	{"Forest - Harvested", 3},
	{"Deciduous Hardwoods", 9},
	{"Indigenous Forest", 11},
	{"Mangrove", 7},
	{"Exotic Forest", 12},
}

// Canopy cover fraction by LCDB class. Only the wooded classes are listed;
// anything unlisted is skipped rather than written as zero, so a later source
// with real canopy data is not overwritten with a guess of "none".
@(rodata)
NZ_LCDB_CANOPY := [?]Class_Rule {
	{"Indigenous Forest", 0.90},
	{"Exotic Forest", 0.88},
	{"Broadleaved Indigenous Hardwoods", 0.70},
	{"Deciduous Hardwoods", 0.70},
	{"Mangrove", 0.60},
	{"Manuka and/or Kanuka", 0.55},
	{"Orchard, Vineyard or Other Perennial Crop", 0.50},
	{"Sub Alpine Shrubland", 0.40},
	{"Mixed Exotic Shrubland", 0.40},
	{"Gorse and/or Broom", 0.35},
	{"Matagouri or Grey Scrub", 0.30},
	{"Fernland", 0.20},
	{"Urban Parkland/Open Space", 0.20},
	{"Built-up Area (settlement)", 0.12},
	{"Forest - Harvested", 0.05},
}

// Mean top-of-canopy height in metres by LCDB class.
@(rodata)
NZ_LCDB_CANOPY_HEIGHT := [?]Class_Rule {
	{"Exotic Forest", 26},
	{"Indigenous Forest", 22},
	{"Deciduous Hardwoods", 15},
	{"Broadleaved Indigenous Hardwoods", 12},
	{"Urban Parkland/Open Space", 8},
	{"Manuka and/or Kanuka", 6},
	{"Built-up Area (settlement)", 5},
	{"Mangrove", 4},
	{"Mixed Exotic Shrubland", 4},
	{"Orchard, Vineyard or Other Perennial Crop", 4},
	{"Sub Alpine Shrubland", 3},
	{"Matagouri or Grey Scrub", 2.5},
	{"Gorse and/or Broom", 2},
	{"Fernland", 1.5},
	{"Forest - Harvested", 1},
}

// Height of the tallest emergent stems, which is the number that decides
// whether a stand can hold a roost at all. An old podocarp stand carries
// emergents half again above its mean canopy; a pine compartment is even-aged
// and has almost none.
@(rodata)
NZ_LCDB_EMERGENT_HEIGHT := [?]Class_Rule {
	{"Indigenous Forest", 34},
	{"Exotic Forest", 30},
	{"Deciduous Hardwoods", 22},
	{"Broadleaved Indigenous Hardwoods", 18},
	{"Urban Parkland/Open Space", 16},
	{"Built-up Area (settlement)", 12},
	{"Manuka and/or Kanuka", 8},
	{"Mangrove", 6},
	{"Mixed Exotic Shrubland", 5},
	{"Sub Alpine Shrubland", 4},
	{"Forest - Harvested", 2},
}

// Age of the dominant cohort in years. Indigenous forest that survived the
// clearances is old; a plantation is somewhere in a 28-year rotation, so half of
// it is the honest answer for a class with no planting date attached.
@(rodata)
NZ_LCDB_STAND_AGE := [?]Class_Rule {
	{"Indigenous Forest", 180},
	{"Deciduous Hardwoods", 60},
	{"Broadleaved Indigenous Hardwoods", 45},
	{"Mangrove", 40},
	{"Manuka and/or Kanuka", 25},
	{"Sub Alpine Shrubland", 25},
	{"Urban Parkland/Open Space", 40},
	{"Exotic Forest", 14},
	{"Mixed Exotic Shrubland", 12},
	{"Gorse and/or Broom", 8},
	{"Forest - Harvested", 1},
}

// OSM `landuse` and `natural` values mapped onto `nz.tenure`. Coarse, but it is
// what is available with no API key, and the distinction that matters most --
// plantation against farmland against town -- is one OSM records well.
@(rodata)
NZ_OSM_TENURE := [?]Class_Rule {
	{"forest", 6},
	{"farmland", 7},
	{"meadow", 7},
	{"orchard", 7},
	{"residential", 8},
	{"industrial", 8},
	{"retail", 8},
	{"nature_reserve", 1},
	{"conservation", 1},
}

// LCDB class mapped onto the plantation crop species that class implies. Only
// the exotic forest classes are listed; radiata is the safe answer for New
// Zealand exotic forest, which is about ninety per cent radiata by area.
@(rodata)
NZ_LCDB_CROP_SPECIES := [?]Class_Rule {
	{"Exotic Forest", 1},
	{"Forest - Harvested", 1},
	{"Deciduous Hardwoods", 3},
}
