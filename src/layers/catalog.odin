package layers

/*
The standard layer catalogue.

Every entry here is an ordinary `Layer_Desc` that could equally have come from a
manifest file. Between them they cover every semantic the engine supports.

The integer types and scales are chosen for storage cost, and their ranges have
to cover the real world: elevation as i16 quarter-metres is 2 bytes a cell,
resolves to 25 cm, and still spans -8191 to 8191 m.
*/

NAN :: f64(0h7ff8_0000_0000_0000)

// Sentinels. Integer layers give up their top code to mean "no data"; float
// layers use NaN.
NODATA_U8 :: 255.0
NODATA_I8 :: -128.0
NODATA_U16 :: 65535.0
NODATA_I16 :: -32768.0
NODATA_U32 :: 4294967295.0
NODATA_I32 :: -2147483648.0

// Registers a layer whose values span orders of magnitude.
@(private)
register_log :: proc(r: ^Registry, desc: Layer_Desc) -> (Layer_Id, bool) {
	d := desc
	d.display = .Log
	return register(r, d)
}

@(private)
scalar_layer :: proc(
	name, group, unit: string,
	kind: Element_Kind,
	scale, offset: f64,
	lo, hi: f64,
	pal: Palette,
	agg := Aggregate.Mean,
	description := "",
	nodata: f64 = 0,
	has_nodata := true,
) -> Layer_Desc {
	nd := nodata
	if has_nodata && nodata == 0 {
		switch kind {
		case .U8:
			nd = NODATA_U8
		case .I8:
			nd = NODATA_I8
		case .U16:
			nd = NODATA_U16
		case .I16:
			nd = NODATA_I16
		case .U32:
			nd = NODATA_U32
		case .I32:
			nd = NODATA_I32
		case .F32, .F64:
			nd = NAN
		}
	}
	return Layer_Desc {
		name = name,
		group = group,
		unit = unit,
		description = description,
		kind = kind,
		components = 1,
		semantic = .Scalar,
		aggregate = agg,
		interp = .Linear,
		scale = scale,
		offset = offset,
		has_nodata = has_nodata,
		nodata_raw = nd,
		min_value = lo,
		max_value = hi,
		palette = pal,
	}
}

// A 0..1 quantity stored in one byte, resolving about 0.4%.
@(private)
fraction_layer :: proc(name, group: string, pal: Palette, description := "") -> Layer_Desc {
	d := scalar_layer(name, group, "fraction", .U8, 1.0 / 254.0, 0, 0, 1, pal, .Mean, description)
	d.semantic = .Fraction
	return d
}

// A per-area quantity: sums, rather than averages, when cells merge.
@(private)
density_layer :: proc(
	name, group, unit: string,
	kind: Element_Kind,
	scale, lo, hi: f64,
	pal: Palette,
	description := "",
) -> Layer_Desc {
	d := scalar_layer(name, group, unit, kind, scale, 0, lo, hi, pal, .Sum, description)
	d.semantic = .Density
	return d
}

@(private)
categorical_layer :: proc(name, group: string, cats: []Category, description := "") -> Layer_Desc {
	d := scalar_layer(name, group, "class", .U8, 1, 0, 0, 255, PALETTE_CATEGORICAL, .Majority, description)
	d.semantic = .Categorical
	d.interp = .Nearest
	d.categories = cats
	return d
}

// `components` fractions that sum to one, one per category.
@(private)
composition_layer :: proc(name, group: string, cats: []Category, description := "") -> Layer_Desc {
	d := scalar_layer(name, group, "fraction", .U8, 1.0 / 254.0, 0, 0, 1, PALETTE_COMPOSITION, .Composition_Mean, description)
	d.semantic = .Composition
	d.components = u8(len(cats))
	d.categories = cats
	return d
}

// Three raw 0..255 channels, drawn directly as a colour rather than through a
// palette. Aggregating up the pyramid averages each channel, which is the
// right thing for a photograph: a coarser cell is the mean colour of what it
// covers.
@(private)
color_layer :: proc(name, group: string, description := "") -> Layer_Desc {
	d := scalar_layer(name, group, "", .U8, 1, 0, 0, 255, PALETTE_CATEGORICAL, .Mean, description, has_nodata = false)
	d.semantic = .Color
	d.components = 3
	d.interp = .Linear
	return d
}

@(private)
direction_layer :: proc(name, group: string, description := "") -> Layer_Desc {
	d := scalar_layer(name, group, "degrees", .U16, 360.0 / 65534.0, 0, 0, 360, PALETTE_CYCLIC, .Circular_Mean, description)
	d.semantic = .Direction
	return d
}

@(private)
boolean_layer :: proc(name, group: string, description := "") -> Layer_Desc {
	d := scalar_layer(name, group, "", .U8, 1, 0, 0, 1, PALETTE_CATEGORICAL, .Any, description, has_nodata = false)
	d.semantic = .Boolean
	d.interp = .Nearest
	return d
}

// ---------------------------------------------------------------------------
// Category vocabularies
// ---------------------------------------------------------------------------

@(rodata)
LANDCOVER_CLASSES := [?]Category {
	{0, "water", {36, 82, 130}},
	{1, "permanent snow and ice", {235, 240, 248}},
	{2, "bare rock", {150, 145, 138}},
	{3, "bare soil / sand", {198, 178, 140}},
	{4, "sparse vegetation", {176, 178, 128}},
	{5, "grassland", {156, 190, 104}},
	{6, "shrubland", {138, 152, 82}},
	{7, "wetland", {94, 148, 142}},
	{8, "cropland", {214, 196, 96}},
	{9, "broadleaf forest", {66, 128, 62}},
	{10, "conifer forest", {36, 92, 70}},
	{11, "mixed forest", {52, 112, 66}},
	{12, "plantation forest", {74, 140, 88}},
	{13, "urban", {132, 128, 132}},
	{14, "industrial", {110, 100, 108}},
	{15, "transport", {90, 88, 92}},
	{16, "mine / quarry", {140, 116, 96}},
	{17, "orchard / vineyard", {182, 176, 88}},
	{18, "pasture", {170, 198, 116}},
	{19, "burnt area", {70, 58, 54}},
}

// Broad forest functional types. Regional species lists are expected to replace
// this vocabulary; the engine does not care which one a world uses, only that a
// composition layer's component count matches its category count.
@(rodata)
FOREST_SPECIES_GROUPS := [?]Category {
	{0, "evergreen conifer", {38, 82, 64}},
	{1, "deciduous conifer", {96, 130, 78}},
	{2, "evergreen broadleaf", {56, 122, 60}},
	{3, "deciduous broadleaf", {122, 158, 68}},
	{4, "sclerophyll / dry broadleaf", {138, 142, 82}},
	{5, "tree fern / palm", {84, 156, 106}},
	{6, "mangrove", {58, 108, 96}},
	{7, "exotic plantation", {102, 168, 96}},
}

// Sand / silt / clay, the standard soil texture triangle.
@(rodata)
SOIL_TEXTURE_FRACTIONS := [?]Category {
	{0, "sand", {214, 190, 132}},
	{1, "silt", {166, 148, 110}},
	{2, "clay", {150, 108, 90}},
}

@(rodata)
SOIL_DRAINAGE_CLASSES := [?]Category {
	{0, "very poorly drained", {40, 70, 110}},
	{1, "poorly drained", {70, 108, 140}},
	{2, "imperfectly drained", {118, 148, 156}},
	{3, "moderately well drained", {158, 168, 140}},
	{4, "well drained", {186, 170, 120}},
	{5, "somewhat excessively drained", {206, 182, 128}},
	{6, "excessively drained", {224, 200, 148}},
}

@(rodata)
KOPPEN_CLASSES := [?]Category {
	{0, "Af tropical rainforest", {0, 76, 156}},
	{1, "Am tropical monsoon", {0, 120, 200}},
	{2, "Aw tropical savanna", {70, 168, 244}},
	{3, "BWh hot desert", {246, 78, 78}},
	{4, "BWk cold desert", {248, 140, 140}},
	{5, "BSh hot steppe", {242, 172, 78}},
	{6, "BSk cold steppe", {248, 212, 140}},
	{7, "Csa hot-summer mediterranean", {248, 248, 0}},
	{8, "Csb warm-summer mediterranean", {200, 200, 0}},
	{9, "Cfa humid subtropical", {200, 248, 78}},
	{10, "Cfb oceanic", {102, 248, 102}},
	{11, "Cfc subpolar oceanic", {50, 200, 50}},
	{12, "Dfa hot-summer continental", {56, 200, 248}},
	{13, "Dfb warm-summer continental", {56, 150, 248}},
	{14, "Dfc subarctic", {0, 126, 200}},
	{15, "Dfd extremely cold subarctic", {0, 80, 160}},
	{16, "ET tundra", {178, 178, 178}},
	{17, "EF ice cap", {230, 230, 230}},
}

@(rodata)
ROAD_CLASSES := [?]Category {
	{0, "none", {40, 40, 40}},
	{1, "track", {120, 104, 86}},
	{2, "forestry road", {150, 128, 96}},
	{3, "minor road", {180, 172, 160}},
	{4, "major road", {214, 200, 168}},
	{5, "highway", {240, 212, 120}},
	{6, "motorway", {248, 172, 88}},
	{7, "rail", {132, 132, 148}},
}

@(rodata)
LANDFORM_CLASSES := [?]Category {
	{0, "valley floor", {58, 96, 132}},
	{1, "lower slope", {88, 128, 118}},
	{2, "mid slope", {130, 150, 104}},
	{3, "upper slope", {172, 158, 108}},
	{4, "ridge", {212, 190, 148}},
	{5, "peak", {240, 232, 220}},
	{6, "plain", {156, 174, 128}},
	{7, "terrace", {140, 156, 140}},
	{8, "hollow", {74, 104, 120}},
	{9, "spur", {186, 172, 130}},
}

@(rodata)
FUEL_MODEL_CLASSES := [?]Category {
	{0, "non-burnable", {90, 96, 104}},
	{1, "short grass", {216, 208, 128}},
	{2, "timber understory grass", {192, 190, 108}},
	{3, "tall grass", {224, 190, 96}},
	{4, "chaparral", {180, 130, 76}},
	{5, "brush", {158, 142, 84}},
	{6, "dormant brush", {140, 118, 78}},
	{7, "southern rough", {150, 108, 72}},
	{8, "closed timber litter", {96, 116, 78}},
	{9, "hardwood litter", {124, 132, 78}},
	{10, "timber litter and understory", {88, 104, 66}},
	{11, "light logging slash", {132, 110, 88}},
	{12, "medium logging slash", {118, 92, 74}},
	{13, "heavy logging slash", {100, 76, 62}},
}

@(rodata)
FIRE_STATE_CLASSES := [?]Category {
	{0, "unburnt", {40, 44, 48}},
	{1, "smouldering", {120, 78, 48}},
	{2, "active fire", {236, 122, 40}},
	{3, "crown fire", {250, 214, 96}},
	{4, "burnt out", {62, 54, 50}},
}

@(rodata)
OWNERSHIP_CLASSES := [?]Category {
	{0, "unclaimed", {56, 56, 60}},
	{1, "public / crown", {96, 132, 168}},
	{2, "conservation estate", {84, 148, 106}},
	{3, "private forestry", {150, 168, 92}},
	{4, "private farm", {206, 190, 116}},
	{5, "community", {180, 140, 168}},
	{6, "player", {236, 208, 108}},
	{7, "rival", {206, 108, 100}},
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

// Registers the whole standard catalogue. Safe to call more than once; existing
// names keep their original descriptor and id.
register_standard_layers :: proc(r: ^Registry) {
	register_imagery_layers(r)
	register_terrain_layers(r)
	register_hydrology_layers(r)
	register_climate_layers(r)
	register_soil_layers(r)
	register_vegetation_layers(r)
	register_disturbance_layers(r)
	register_fauna_layers(r)
	register_human_layers(r)
	register_simulation_layers(r)
}

register_imagery_layers :: proc(r: ^Registry) {
	register(r, color_layer("imagery.true_color", "imagery",
		"RGB aerial or satellite photography, resampled onto the grid at ingest."))
}

register_terrain_layers :: proc(r: ^Registry) {
	// Elevation in quarter-metres: +-8191 m at 25 cm resolution, in two bytes,
	// which spans the Dead Sea shore to the summit of Everest.
	register(r, scalar_layer("terrain.elevation", "terrain", "m", .I16, 0.25, 0, -500, 8000, PALETTE_TERRAIN, .Mean,
		"Height of the ground surface above the geoid."))

	register(r, scalar_layer("terrain.slope", "terrain", "degrees", .U8, 90.0 / 254.0, 0, 0, 90, PALETTE_HEAT, .Mean,
		"Steepness of the surface. Drives access cost, erosion and fire spread."))
	register(r, direction_layer("terrain.aspect", "terrain",
		"Compass direction the slope faces. Controls insolation and hence drying and growth."))
	register(r, scalar_layer("terrain.roughness", "terrain", "m", .U16, 0.05, 0, 0, 200, PALETTE_VIRIDIS, .Mean,
		"Local relief within a cell: the elevation range of the finest cells inside it."))
	register(r, scalar_layer("terrain.curvature", "terrain", "1/100m", .I16, 0.001, 0, -1, 1, PALETTE_DIVERGING, .Mean,
		"Profile curvature. Negative is concave and collects water; positive is convex and sheds it."))
	register(r, scalar_layer("terrain.hillshade", "terrain", "", .U8, 1.0 / 254.0, 0, 0, 1, PALETTE_VIRIDIS, .Mean,
		"Cached relief shading, so the renderer does not recompute lighting every frame."))
	register(r, categorical_layer("terrain.landform", "terrain", LANDFORM_CLASSES[:],
		"Geomorphological position, derived from elevation and curvature."))
	register(r, scalar_layer("terrain.rugosity", "terrain", "", .U8, 2.0 / 254.0, 0, 0, 2, PALETTE_VIRIDIS, .Mean,
		"Surface area divided by planimetric area: how much extra ground the terrain hides."))
}

register_hydrology_layers :: proc(r: ^Registry) {
	register(r, scalar_layer("water.depth", "hydrology", "m", .U16, 0.02, 0, 0, 1000, PALETTE_BLUES, .Mean,
		"Standing water depth. Zero on dry land."))
	register(r, boolean_layer("water.permanent", "hydrology",
		"Set where water is present year-round: lakes, sea, perennial rivers."))
	register_log(r, scalar_layer("water.discharge", "hydrology", "m3/s", .F32, 1, 0, 0, 5000, PALETTE_BLUES, .Sum,
		"Channel discharge. Sums downstream, so it aggregates by sum."))
	register_log(r, scalar_layer("water.flow_accumulation", "hydrology", "cells", .U32, 1, 0, 0, 1e7, PALETTE_BLUES, .Sum,
		"Upstream contributing cell count, the usual basis for extracting a stream network."))
	register(r, direction_layer("water.flow_direction", "hydrology",
		"Direction of steepest descent, used to route surface flow between cells."))
	register(r, scalar_layer("water.table_depth", "hydrology", "m", .U16, 0.01, 0, 0, 100, PALETTE_MOISTURE, .Mean,
		"Depth from the surface to the water table."))
	register(r, scalar_layer("water.distance_to_water", "hydrology", "m", .U16, 5, 0, 0, 300000, PALETTE_BLUES, .Min,
		"Straight-line distance to the nearest permanent water. Aggregates by minimum."))
	register(r, fraction_layer("water.flood_probability", "hydrology", PALETTE_BLUES,
		"Annual probability that the cell floods."))
	register(r, scalar_layer("water.snow_depth", "hydrology", "m", .U16, 0.005, 0, 0, 30, PALETTE_BLUES, .Mean,
		"Snowpack depth."))
	register(r, scalar_layer("water.snow_water_equivalent", "hydrology", "mm", .U16, 1, 0, 0, 5000, PALETTE_BLUES, .Mean,
		"Water contained in the snowpack, which is what actually matters for runoff."))
	register(r, scalar_layer("water.ice_thickness", "hydrology", "m", .U16, 0.5, 0, 0, 4000, PALETTE_BLUES, .Mean,
		"Glacier or ice sheet thickness."))
	register(r, scalar_layer("water.catchment_id", "hydrology", "id", .U32, 1, 0, 0, 4e9, PALETTE_CATEGORICAL, .Majority,
		"Identifier of the catchment the cell drains to."))
}

register_climate_layers :: proc(r: ^Registry) {
	// Temperatures in 1/50 K steps over -60..+60 C, in two bytes.
	register(r, scalar_layer("climate.temp_mean_annual", "climate", "C", .I16, 0.02, 0, -60, 60, PALETTE_DIVERGING, .Mean,
		"Mean annual air temperature."))
	register(r, scalar_layer("climate.temp_min_coldest_month", "climate", "C", .I16, 0.02, 0, -70, 40, PALETTE_DIVERGING, .Mean,
		"Mean daily minimum of the coldest month. The usual limit on which species can survive."))
	register(r, scalar_layer("climate.temp_max_warmest_month", "climate", "C", .I16, 0.02, 0, -20, 60, PALETTE_DIVERGING, .Mean,
		"Mean daily maximum of the warmest month."))
	register(r, scalar_layer("climate.temp_seasonality", "climate", "C", .U16, 0.001, 0, 0, 30, PALETTE_HEAT, .Mean,
		"Standard deviation of monthly mean temperature."))
	register(r, scalar_layer("climate.precip_annual", "climate", "mm", .U16, 1, 0, 0, 12000, PALETTE_BLUES, .Mean,
		"Total annual precipitation."))
	register(r, scalar_layer("climate.precip_driest_month", "climate", "mm", .U16, 0.5, 0, 0, 2000, PALETTE_BLUES, .Mean,
		"Precipitation of the driest month, the practical measure of drought exposure."))
	register(r, scalar_layer("climate.precip_seasonality", "climate", "%", .U8, 200.0 / 254.0, 0, 0, 200, PALETTE_HEAT, .Mean,
		"Coefficient of variation of monthly precipitation."))
	register(r, fraction_layer("climate.humidity", "climate", PALETTE_MOISTURE,
		"Mean relative humidity."))
	register(r, scalar_layer("climate.wind_speed", "climate", "m/s", .U8, 60.0 / 254.0, 0, 0, 60, PALETTE_VIRIDIS, .Mean,
		"Mean wind speed 10 m above ground."))
	register(r, direction_layer("climate.wind_direction", "climate",
		"Prevailing wind direction, as the bearing the wind blows towards."))
	register(r, scalar_layer("climate.solar_radiation", "climate", "MJ/m2/day", .U16, 0.002, 0, 0, 45, PALETTE_HEAT, .Mean,
		"Incident shortwave radiation, already adjusted for slope and aspect where the ingest does so."))
	register(r, scalar_layer("climate.evapotranspiration", "climate", "mm/yr", .U16, 0.5, 0, 0, 3000, PALETTE_HEAT, .Mean,
		"Potential evapotranspiration."))
	register(r, scalar_layer("climate.water_deficit", "climate", "mm/yr", .U16, 0.5, 0, 0, 3000, PALETTE_HEAT, .Mean,
		"Potential evapotranspiration minus precipitation, where positive."))
	register(r, scalar_layer("climate.growing_degree_days", "climate", "degree-days", .U16, 1, 0, 0, 12000, PALETTE_GREENS, .Mean,
		"Accumulated warmth above 5 C over a year. Sets what can grow and how fast."))
	register(r, scalar_layer("climate.frost_days", "climate", "days/yr", .U16, 0.01, 0, 0, 365, PALETTE_BLUES, .Mean,
		"Days per year with a screen minimum below 0 C."))
	register(r, scalar_layer("climate.fire_weather_index", "climate", "", .U8, 100.0 / 254.0, 0, 0, 100, PALETTE_HEAT, .Mean,
		"Canadian Fire Weather Index, or an equivalent national index."))
	register(r, categorical_layer("climate.koppen", "climate", KOPPEN_CLASSES[:],
		"Koppen-Geiger climate classification."))
	register(r, scalar_layer("climate.elevation_lapse_correction", "climate", "C", .I16, 0.01, 0, -20, 20, PALETTE_DIVERGING, .Mean,
		"Temperature offset from the coarse climate grid to this cell's elevation."))
}

register_soil_layers :: proc(r: ^Registry) {
	register(r, composition_layer("soil.texture", "soil", SOIL_TEXTURE_FRACTIONS[:],
		"Sand, silt and clay fractions. Determines water holding capacity and workability."))
	register(r, scalar_layer("soil.ph", "soil", "pH", .U8, 14.0 / 254.0, 0, 0, 14, PALETTE_DIVERGING, .Mean,
		"Soil pH in water."))
	register(r, scalar_layer("soil.organic_carbon", "soil", "g/kg", .U16, 0.1, 0, 0, 600, PALETTE_GREENS, .Mean,
		"Soil organic carbon content."))
	register(r, scalar_layer("soil.depth", "soil", "m", .U16, 0.005, 0, 0, 30, PALETTE_VIRIDIS, .Mean,
		"Depth to bedrock or another root-limiting layer."))
	register(r, fraction_layer("soil.moisture", "soil", PALETTE_MOISTURE,
		"Volumetric water content as a fraction of saturation. A simulation state layer as much as a data one."))
	register(r, scalar_layer("soil.bulk_density", "soil", "kg/m3", .U16, 0.1, 0, 0, 2200, PALETTE_VIRIDIS, .Mean,
		"Dry bulk density."))
	register(r, categorical_layer("soil.drainage", "soil", SOIL_DRAINAGE_CLASSES[:],
		"Drainage class."))
	register(r, scalar_layer("soil.fertility", "soil", "", .U8, 1.0 / 254.0, 0, 0, 1, PALETTE_GREENS, .Mean,
		"Composite nutrient availability index, 0 to 1."))
	register(r, scalar_layer("soil.erosion_risk", "soil", "t/ha/yr", .U16, 0.02, 0, 0, 200, PALETTE_HEAT, .Mean,
		"Modelled soil loss rate."))
	register(r, scalar_layer("soil.stoniness", "soil", "%", .U8, 100.0 / 254.0, 0, 0, 100, PALETTE_VIRIDIS, .Mean,
		"Coarse fragment content by volume."))
	register(r, scalar_layer("soil.available_water_capacity", "soil", "mm", .U16, 0.05, 0, 0, 500, PALETTE_MOISTURE, .Mean,
		"Plant-available water the profile can hold."))
}

register_vegetation_layers :: proc(r: ^Registry) {
	register(r, categorical_layer("land.cover", "vegetation", LANDCOVER_CLASSES[:],
		"Primary land cover class."))
	register(r, fraction_layer("forest.density", "vegetation", PALETTE_GREENS,
		"Canopy cover fraction: the share of the cell shaded by tree crowns."))
	register(r, composition_layer("forest.composition", "vegetation", FOREST_SPECIES_GROUPS[:],
		"Species-group mix of the stand, as fractions of basal area summing to one."))
	register(r, scalar_layer("forest.canopy_height", "vegetation", "m", .U8, 80.0 / 254.0, 0, 0, 80, PALETTE_GREENS, .Mean,
		"Mean top-of-canopy height."))
	register(r, scalar_layer("forest.basal_area", "vegetation", "m2/ha", .U8, 120.0 / 254.0, 0, 0, 120, PALETTE_GREENS, .Mean,
		"Cross-sectional area of stems at breast height per hectare. The forester's density measure."))
	register(r, scalar_layer("forest.stand_age", "vegetation", "years", .U16, 1, 0, 0, 2000, PALETTE_VIRIDIS, .Mean,
		"Age of the dominant cohort."))
	register(r, scalar_layer("forest.biomass_above_ground", "vegetation", "t/ha", .U16, 0.05, 0, 0, 2000, PALETTE_GREENS, .Mean,
		"Above-ground live biomass."))
	register(r, scalar_layer("forest.timber_volume", "vegetation", "m3/ha", .U16, 0.05, 0, 0, 2500, PALETTE_GREENS, .Mean,
		"Merchantable standing volume."))
	register(r, scalar_layer("forest.leaf_area_index", "vegetation", "m2/m2", .U8, 12.0 / 254.0, 0, 0, 12, PALETTE_GREENS, .Mean,
		"One-sided leaf area per unit ground area."))
	register(r, scalar_layer("forest.ndvi", "vegetation", "", .I16, 1.0 / 20000.0, 0, -1, 1, PALETTE_GREENS, .Mean,
		"Normalised difference vegetation index, as observed."))
	register(r, fraction_layer("forest.understory_density", "vegetation", PALETTE_GREENS,
		"Cover fraction of the shrub and sapling layer beneath the canopy."))
	register(r, scalar_layer("forest.deadwood_load", "vegetation", "t/ha", .U8, 100.0 / 254.0, 0, 0, 100, PALETTE_HEAT, .Mean,
		"Coarse woody debris on the ground. Habitat, carbon and fuel all at once."))
	register(r, scalar_layer("forest.litter_load", "vegetation", "t/ha", .U8, 40.0 / 254.0, 0, 0, 40, PALETTE_HEAT, .Mean,
		"Fine surface fuel load."))
	register(r, fraction_layer("forest.regeneration", "vegetation", PALETTE_GREENS,
		"Density of established seedlings relative to a fully stocked stand."))
	register(r, fraction_layer("forest.health", "vegetation", PALETTE_GREENS,
		"Crown condition, 1 being healthy and 0 being dead standing."))
	register(r, fraction_layer("forest.canopy_gap_fraction", "vegetation", PALETTE_VIRIDIS,
		"Share of the canopy that is open, which is what light-demanding species need."))
	register(r, scalar_layer("forest.site_index", "vegetation", "m", .U8, 50.0 / 254.0, 0, 0, 50, PALETTE_GREENS, .Mean,
		"Expected dominant height at a reference age: the standard measure of site productivity."))
	register(r, scalar_layer("forest.growth_rate", "vegetation", "m3/ha/yr", .U8, 40.0 / 254.0, 0, 0, 40, PALETTE_GREENS, .Mean,
		"Current annual volume increment."))
	register(r, fraction_layer("veg.grass_cover", "vegetation", PALETTE_GREENS, "Cover fraction of grasses and herbs."))
	register(r, fraction_layer("veg.shrub_cover", "vegetation", PALETTE_GREENS, "Cover fraction of shrubs."))
	register(r, fraction_layer("veg.crop_cover", "vegetation", PALETTE_GREENS, "Cover fraction under crops."))
}

register_disturbance_layers :: proc(r: ^Registry) {
	register(r, categorical_layer("fire.fuel_model", "disturbance", FUEL_MODEL_CLASSES[:],
		"Standard fire behaviour fuel model."))
	register(r, fraction_layer("fire.fuel_moisture", "disturbance", PALETTE_MOISTURE,
		"Fine fuel moisture content, the single strongest control on ignition."))
	register(r, categorical_layer("fire.state", "disturbance", FIRE_STATE_CLASSES[:],
		"Current fire state of the cell."))
	register_log(r, scalar_layer("fire.intensity", "disturbance", "kW/m", .U16, 2, 0, 0, 100000, PALETTE_HEAT, .Max,
		"Fireline intensity. Aggregates by maximum, because a coarse cell containing a crown fire is a crown fire."))
	register(r, scalar_layer("fire.years_since_burn", "disturbance", "years", .U16, 1, 0, 0, 2000, PALETTE_HEAT, .Min,
		"Time since the last fire."))
	register(r, fraction_layer("disturbance.windthrow_risk", "disturbance", PALETTE_HEAT,
		"Probability of significant wind damage in a severe storm."))
	register(r, fraction_layer("disturbance.pest_pressure", "disturbance", PALETTE_HEAT,
		"Insect or pathogen pressure on the current stand."))
	register(r, fraction_layer("disturbance.landslide_susceptibility", "disturbance", PALETTE_HEAT,
		"Susceptibility to shallow landsliding."))
	register(r, scalar_layer("disturbance.drought_stress", "disturbance", "", .U8, 1.0 / 254.0, 0, 0, 1, PALETTE_HEAT, .Mean,
		"Accumulated water stress on the current vegetation."))
}

register_fauna_layers :: proc(r: ^Registry) {
	register(r, density_layer("fauna.deer_density", "fauna", "animals/km2", .U8, 40.0 / 254.0, 0, 40, PALETTE_HEAT,
		"Browsing ungulate density."))
	register(r, density_layer("fauna.predator_density", "fauna", "animals/km2", .U8, 5.0 / 254.0, 0, 5, PALETTE_HEAT,
		"Large predator density."))
	register(r, fraction_layer("fauna.habitat_suitability", "fauna", PALETTE_GREENS,
		"Suitability for the currently selected focal species, 0 to 1."))
	register(r, scalar_layer("fauna.biodiversity_index", "fauna", "", .U8, 1.0 / 254.0, 0, 0, 1, PALETTE_GREENS, .Mean,
		"Composite biodiversity value of the cell."))
	register(r, fraction_layer("fauna.connectivity", "fauna", PALETTE_VIRIDIS,
		"Landscape permeability to movement, 0 being a hard barrier."))
	register(r, density_layer("fauna.pollinator_abundance", "fauna", "index/km2", .U8, 1.0 / 254.0, 0, 1, PALETTE_GREENS,
		"Relative pollinator abundance."))
}

register_human_layers :: proc(r: ^Registry) {
	register_log(r, density_layer("human.population_density", "human", "people/km2", .U16, 0.5, 0, 30000, PALETTE_HEAT,
		"Resident population per square kilometre."))
	register(r, fraction_layer("human.built_up", "human", PALETTE_HEAT,
		"Fraction of the cell under buildings and sealed surface."))
	register(r, categorical_layer("human.road_class", "human", ROAD_CLASSES[:],
		"Highest road class present in the cell."))
	register(r, scalar_layer("human.road_density", "human", "km/km2", .U8, 20.0 / 254.0, 0, 0, 20, PALETTE_HEAT, .Mean,
		"Length of road per unit area."))
	register(r, scalar_layer("human.access_time", "human", "minutes", .U16, 1, 0, 0, 20000, PALETTE_VIRIDIS, .Min,
		"Travel time to the nearest road head. Aggregates by minimum, since a coarse cell is as reachable as its easiest part."))
	register(r, scalar_layer("human.harvest_cost", "human", "currency/m3", .U16, 0.1, 0, 0, 500, PALETTE_HEAT, .Mean,
		"Modelled cost to fell, extract and cart one cubic metre from this cell."))
	register(r, boolean_layer("human.protected_area", "human",
		"Set where legal protection forbids extraction."))
	register(r, categorical_layer("human.ownership", "human", OWNERSHIP_CLASSES[:],
		"Who holds the cell."))
	register(r, scalar_layer("human.admin_id", "human", "id", .U32, 1, 0, 0, 4e9, PALETTE_CATEGORICAL, .Majority,
		"Administrative region identifier, for reporting and rules that vary by jurisdiction."))
	register_log(r, scalar_layer("human.land_value", "human", "currency/ha", .U32, 1, 0, 0, 1e8, PALETTE_HEAT, .Mean,
		"Market land value."))
	register(r, fraction_layer("human.recreation_value", "human", PALETTE_VIRIDIS,
		"Amenity and recreation value of the cell."))
}

// Layers the simulation writes rather than reads. They are ordinary layers, so
// they get the same pyramid, the same palettes and the same save format.
register_simulation_layers :: proc(r: ^Registry) {
	register(r, boolean_layer("sim.explored", "simulation", "Whether the player has surveyed the cell."))
	register(r, fraction_layer("sim.visibility", "simulation", PALETTE_VIRIDIS,
		"How much of the cell is currently observed."))
	register(r, scalar_layer("sim.harvest_year", "simulation", "year", .U16, 1, 0, 0, 3000, PALETTE_VIRIDIS, .Max,
		"Year the cell was last harvested."))
	register(r, boolean_layer("sim.harvest_scheduled", "simulation", "Marked for harvest in the current plan."))
	register(r, scalar_layer("sim.carbon_stock", "simulation", "tC/ha", .U16, 0.05, 0, 0, 1000, PALETTE_GREENS, .Mean,
		"Carbon held in live and dead biomass, tracked for accounting."))
	register(r, scalar_layer("sim.carbon_flux", "simulation", "tC/ha/yr", .I16, 0.001, 0, -20, 20, PALETTE_DIVERGING, .Mean,
		"Net annual carbon exchange. Negative is a source, positive a sink."))
	register(r, scalar_layer("sim.yield_last", "simulation", "m3", .U16, 0.5, 0, 0, 30000, PALETTE_GREENS, .Sum,
		"Volume taken from the cell at the last harvest."))
}
