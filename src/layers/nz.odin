package layers

/*
The New Zealand specialisation of the catalogue.

`ltb` is named for the long-tailed bat, and this file is where the engine stops
being a generic landscape model and starts being a model of the places
*Chalinolobus tuberculatus* and *Mystacina tuberculata* actually live: Fiordland
beech valleys, central North Island podocarp forest, Waikato farmland and
suburbs, and the exotic plantations the long-tailed bat has taken to roosting in.

Three things drive everything here.

  - Both species are obligate tree roosters over most of their range, and they
    switch roost trees every day or two. What matters is not "is there forest"
    but "how many big old cavity-bearing stems are there, and are they close
    enough together to form a roost network".
  - The long-tailed bat is an edge and corridor forager. It flies fast along
    forest margins, shelter belts, river channels and treelined roads, so the
    geometry of the canopy matters as much as its extent.
  - Everything is predator-limited. Ship rats and stoats take bats off roosts,
    and rat and stoat numbers track beech and podocarp masting. A habitat model
    for New Zealand that ignores pest pressure predicts the wrong answer.

The vocabularies are the ones the national datasets actually use -- LCDB v5
classes, NES-PF erosion susceptibility classes, tracking tunnel and residual
trap catch indices -- so an ingest can map a downloaded attribute straight onto
a layer without an intermediate translation table.
*/

// ---------------------------------------------------------------------------
// Category vocabularies
// ---------------------------------------------------------------------------

// Land Cover Database v5 classes, with the class codes Manaaki Whenua ships in
// the `Class_2018` attribute. The codes are sparse and non-contiguous; that is
// the real vocabulary, and keeping it lets a manifest classify on the raw
// attribute value.
@(rodata)
NZ_LCDB_CLASSES := [?]Category {
	{1, "built-up area", {150, 140, 148}},
	{2, "urban parkland / open space", {174, 196, 140}},
	{5, "transport infrastructure", {96, 94, 98}},
	{6, "surface mine or dump", {140, 116, 96}},
	{10, "sand or gravel", {214, 202, 168}},
	{12, "landslide", {166, 126, 104}},
	{14, "permanent snow and ice", {236, 242, 248}},
	{15, "alpine grass / herbfield", {198, 202, 186}},
	{16, "gravel or rock", {158, 154, 148}},
	{20, "lake or pond", {40, 88, 138}},
	{21, "river", {54, 112, 168}},
	{22, "estuarine open water", {70, 128, 156}},
	{30, "short-rotation cropland", {216, 194, 100}},
	{33, "orchard, vineyard or other perennial crop", {184, 176, 88}},
	{40, "high producing exotic grassland", {172, 200, 112}},
	{41, "low producing grassland", {186, 194, 130}},
	{43, "tall tussock grassland", {198, 176, 116}},
	{44, "depleted grassland", {200, 190, 152}},
	{45, "herbaceous freshwater vegetation", {104, 156, 140}},
	{46, "herbaceous saline vegetation", {126, 150, 134}},
	{47, "flaxland", {112, 148, 108}},
	{50, "fernland", {130, 156, 96}},
	{51, "gorse and/or broom", {188, 190, 76}},
	{52, "manuka and/or kanuka", {124, 152, 96}},
	{54, "broadleaved indigenous hardwoods", {74, 134, 74}},
	{55, "sub alpine shrubland", {118, 140, 104}},
	{56, "mixed exotic shrubland", {142, 158, 96}},
	{58, "matagouri or grey scrub", {152, 152, 116}},
	{64, "forest - harvested", {150, 128, 102}},
	{68, "deciduous hardwoods", {132, 168, 74}},
	{69, "indigenous forest", {34, 92, 58}},
	{70, "mangrove", {58, 108, 96}},
	{71, "exotic forest", {80, 128, 84}},
}

// New Zealand tree groups, as fractions of basal area. This is the vocabulary
// `forest.composition_nz` uses; it replaces the engine's generic functional
// types with the groups a New Zealand stand is actually described by, because
// the bat models below key off specific ones -- podocarp and beech for large
// cavity-bearing stems, radiata pine for the plantation roosts long-tailed bats
// use in Hanmer and Kinleith.
@(rodata)
NZ_TREE_GROUPS := [?]Category {
	{0, "podocarp (rimu, kahikatea, matai, totara, miro)", {32, 84, 62}},
	{1, "beech (tawhai)", {58, 106, 70}},
	{2, "broadleaved hardwood (tawa, kamahi, hinau, rewarewa)", {74, 134, 74}},
	{3, "kauri", {46, 96, 84}},
	{4, "manuka / kanuka", {124, 152, 96}},
	{5, "tree fern (ponga, mamaku)", {96, 164, 110}},
	{6, "nikau and other palms", {84, 152, 120}},
	{7, "radiata pine", {88, 130, 92}},
	{8, "Douglas-fir", {70, 108, 88}},
	{9, "eucalypt and other exotic hardwood", {138, 156, 86}},
	{10, "willow / poplar riparian exotics", {150, 172, 102}},
}

// Who holds the land, in the terms New Zealand tenure is actually recorded in.
// Bat management turns on this: a roost stand on public conservation land is
// protected outright, the same stand on private farmland is not.
@(rodata)
NZ_TENURE_CLASSES := [?]Category {
	{0, "unknown", {56, 56, 60}},
	{1, "public conservation land (DOC)", {70, 140, 96}},
	{2, "other Crown land", {104, 132, 164}},
	{3, "council reserve", {112, 160, 140}},
	{4, "QEII open space covenant", {132, 176, 116}},
	{5, "Maori land / Nga Whenua Rahui", {186, 140, 108}},
	{6, "private plantation forest", {126, 152, 90}},
	{7, "private farmland", {206, 190, 116}},
	{8, "residential and urban", {168, 152, 156}},
	{9, "road or rail corridor", {120, 116, 118}},
}

// Which of the two surviving bat species a survey found. New Zealand has only
// these two native land mammals, and the automatic detectors that produce most
// of the national data separate them cleanly: long-tailed bats echolocate
// around 40 kHz, short-tailed around 28 kHz.
@(rodata)
NZ_BAT_SPECIES := [?]Category {
	{0, "none detected", {48, 48, 54}},
	{1, "long-tailed bat (pekapeka-tou-roa)", {226, 172, 74}},
	{2, "lesser short-tailed bat (pekapeka-tou-poto)", {150, 122, 214}},
	{3, "both species", {236, 226, 132}},
}

// Lesser short-tailed bat lineages. They are managed as separate units because
// they are genetically distinct and none of them can recolonise another's range.
@(rodata)
NZ_SHORT_TAILED_LINEAGES := [?]Category {
	{0, "absent", {48, 48, 54}},
	{1, "northern (M. t. aupourica)", {186, 140, 220}},
	{2, "central (M. t. rhyacobia)", {150, 122, 214}},
	{3, "southern (M. t. tuberculata)", {112, 100, 186}},
}

// What the bats are roosting in. Roost switching is near-daily, so a stand has
// to offer many of these, not one.
@(rodata)
NZ_ROOST_TYPES := [?]Category {
	{0, "no roost recorded", {48, 48, 54}},
	{1, "cavity in live indigenous tree", {58, 118, 76}},
	{2, "cavity in dead standing tree", {132, 116, 88}},
	{3, "under loose or flaking bark", {158, 136, 100}},
	{4, "epiphyte or vine tangle", {96, 154, 108}},
	{5, "cave or karst", {110, 108, 128}},
	{6, "rock crevice or scree", {146, 142, 138}},
	{7, "building, bridge or culvert", {170, 150, 150}},
	{8, "exotic conifer", {92, 128, 96}},
	{9, "tree fern crown", {104, 168, 116}},
}

// Predator control regimes, coarsest to most complete. The step from bait
// stations to a full aerial operation in a mast year is the difference between
// a bat colony persisting and not.
@(rodata)
NZ_PEST_CONTROL_CLASSES := [?]Category {
	{0, "none", {60, 56, 58}},
	{1, "ground trapping", {132, 128, 108}},
	{2, "ground bait stations", {158, 148, 100}},
	{3, "aerial 1080", {206, 156, 82}},
	{4, "self-resetting trap network", {174, 178, 120}},
	{5, "predator-proof fenced sanctuary", {110, 186, 138}},
	{6, "island or eradicated mainland", {140, 214, 168}},
}

// Plantation crop species. Radiata is about ninety per cent of the New Zealand
// estate; the rest matters because rotation length and canopy structure differ,
// and long-tailed bats roost in some of them.
@(rodata)
NZ_PLANTATION_SPECIES := [?]Category {
	{0, "none", {56, 56, 60}},
	{1, "radiata pine", {88, 130, 92}},
	{2, "Douglas-fir", {70, 108, 88}},
	{3, "eucalypt", {138, 156, 86}},
	{4, "cypress", {96, 140, 116}},
	{5, "other exotic softwood", {110, 138, 104}},
	{6, "indigenous plantation", {52, 108, 70}},
}

// Silvicultural regime, which sets canopy structure and so what a stand offers
// a foraging bat.
@(rodata)
NZ_SILVICULTURE_CLASSES := [?]Category {
	{0, "not managed", {60, 60, 64}},
	{1, "unthinned production", {104, 128, 96}},
	{2, "production thinned", {126, 152, 104}},
	{3, "pruned clearwood", {150, 174, 112}},
	{4, "continuous cover", {84, 138, 92}},
	{5, "carbon-only, unharvested", {70, 120, 100}},
	{6, "recently clearfelled", {150, 128, 102}},
}

// NES-PF erosion susceptibility classification. It governs what harvesting is
// permitted, so it is a constraint on the simulation as much as a description
// of the ground.
@(rodata)
NZ_EROSION_SUSCEPTIBILITY := [?]Category {
	{0, "green -- low", {110, 168, 110}},
	{1, "yellow -- moderate", {214, 208, 110}},
	{2, "orange -- high", {220, 160, 84}},
	{3, "red -- very high", {206, 96, 84}},
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

// Registers the New Zealand and bat layers. Called by `register_standard_layers`.
register_nz_layers :: proc(r: ^Registry) {
	register_nz_cover_layers(r)
	register_bat_layers(r)
	register_predator_layers(r)
	register_forestry_layers(r)
}

register_nz_cover_layers :: proc(r: ^Registry) {
	register(r, categorical_layer("nz.lcdb_class", "new zealand", NZ_LCDB_CLASSES[:],
		"Land Cover Database v5 class, with the codes Manaaki Whenua publishes."))
	register(r, categorical_layer("nz.tenure", "new zealand", NZ_TENURE_CLASSES[:],
		"Land tenure. Decides whether a roost stand has any legal protection."))
	register(r, composition_layer("forest.composition_nz", "vegetation", NZ_TREE_GROUPS[:],
		"Stand composition in New Zealand tree groups, as fractions of basal area."))
	register(r, scalar_layer("forest.emergent_height", "vegetation", "m", .U8, 80.0 / 254.0, 0, 0, 80, PALETTE_GREENS, .Max,
		"Height of the tallest emergent stems, not the mean canopy. Aggregates by maximum, because one 40 m rimu in a cell is what a bat is looking for."))
	register(r, scalar_layer("forest.cavity_tree_density", "vegetation", "stems/ha", .U8, 20.0 / 254.0, 0, 0, 20, PALETTE_GREENS, .Mean,
		"Density of stems large or decayed enough to hold a bat roost cavity: over about 60 cm diameter, or dead and standing."))
	register(r, scalar_layer("forest.edge_density", "vegetation", "m/ha", .U16, 0.02, 0, 0, 1000, PALETTE_VIRIDIS, .Mean,
		"Length of canopy edge per hectare. Derived, and the strongest single predictor of long-tailed bat activity."))
	register(r, fraction_layer("forest.old_growth", "vegetation", PALETTE_GREENS,
		"Fraction of the cell in unlogged indigenous forest."))
	register(r, color_layer("imagery.false_color", "imagery",
		"Near-infrared, red and green as an RGB triple: the standard aerial rendering for reading canopy condition."))
	register(r, scalar_layer("imagery.capture_year", "imagery", "year", .U16, 1, 0, 1930, 2100, PALETTE_VIRIDIS, .Max,
		"Year the imagery over this cell was flown. LINZ urban and rural programmes are years apart, and a bat model built on stale imagery misses recent clearfell."))
	register_log(r, scalar_layer("human.night_light", "human", "nW/cm2/sr", .U16, 0.05, 0, 0, 3000, PALETTE_HEAT, .Mean,
		"Night-time radiance. Long-tailed bats avoid lit ground, so street lighting fragments an otherwise continuous corridor."))
}

// The bat layers proper: what was observed, what the habitat offers, and what
// the model derives from the two.
register_bat_layers :: proc(r: ^Registry) {
	// ---- observation ---------------------------------------------------
	register(r, scalar_layer("bat.activity_long_tailed", "bats", "passes/night", .U16, 0.25, 0, 0, 4000, PALETTE_HEAT, .Mean,
		"Mean long-tailed bat passes per detector-night. The unit almost every New Zealand bat survey reports."))
	register(r, scalar_layer("bat.activity_short_tailed", "bats", "passes/night", .U16, 0.25, 0, 0, 4000, PALETTE_HEAT, .Mean,
		"Mean lesser short-tailed bat passes per detector-night."))
	register(r, categorical_layer("bat.species_present", "bats", NZ_BAT_SPECIES[:],
		"Which species detectors have picked up here."))
	register(r, categorical_layer("bat.short_tailed_lineage", "bats", NZ_SHORT_TAILED_LINEAGES[:],
		"Which short-tailed bat lineage this cell falls in. They are managed as separate units."))
	register(r, boolean_layer("bat.range_core", "bats",
		"Inside a mapped population range from the DOC Bat Distribution Database, as opposed to merely suitable."))
	register(r, scalar_layer("bat.survey_effort", "bats", "detector-nights", .U16, 1, 0, 0, 60000, PALETTE_VIRIDIS, .Sum,
		"Survey effort behind the activity figures. Absence in an unsurveyed cell is not absence."))
	register(r, scalar_layer("bat.last_detected_year", "bats", "year", .U16, 1, 0, 1900, 2100, PALETTE_VIRIDIS, .Max,
		"Most recent year a bat was confirmed here."))
	register(r, density_layer("bat.records", "bats", "records", .U16, 1, 0, 4000, PALETTE_HEAT,
		"Confirmed occurrence records. A count, so it sums when cells merge."))

	// ---- roosts --------------------------------------------------------
	register(r, density_layer("bat.roost_density", "bats", "roosts/km2", .U8, 40.0 / 254.0, 0, 40, PALETTE_HEAT,
		"Known roost trees per square kilometre."))
	register(r, categorical_layer("bat.roost_type", "bats", NZ_ROOST_TYPES[:],
		"Dominant roost structure recorded in the cell."))
	register(r, boolean_layer("bat.maternity_roost", "bats",
		"A communal maternity roost is known here. Felling one in December loses a season's young outright."))
	register(r, scalar_layer("bat.colony_size", "bats", "bats", .U16, 1, 0, 0, 5000, PALETTE_HEAT, .Sum,
		"Counted emergence from the roosts in this cell."))

	// ---- habitat, derived ----------------------------------------------
	register(r, fraction_layer("bat.roost_suitability", "bats", PALETTE_GREENS,
		"Modelled roost habitat quality: large old cavity-bearing stems, in enough density to support daily roost switching."))
	register(r, fraction_layer("bat.foraging_suitability", "bats", PALETTE_GREENS,
		"Modelled foraging quality: canopy edge, water, shelter from wind, and prey."))
	register(r, fraction_layer("bat.commuting_value", "bats", PALETTE_VIRIDIS,
		"Value of the cell as a commuting line between roost and foraging ground: forest margin, river channel, shelter belt, treelined road."))
	register(r, fraction_layer("bat.habitat_suitability", "bats", PALETTE_GREENS,
		"Combined habitat suitability for the focal species, roosting and foraging together, discounted for predation and disturbance."))
	register(r, fraction_layer("bat.habitat_suitability_short_tailed", "bats", PALETTE_GREENS,
		"The same index for the lesser short-tailed bat, which needs large unbroken old-growth rather than edge."))
	register(r, fraction_layer("bat.prey_abundance", "bats", PALETTE_GREENS,
		"Relative abundance of the nocturnal insects both species feed on."))
	register(r, fraction_layer("bat.predation_risk", "bats", PALETTE_HEAT,
		"Modelled probability that a roosting bat is taken by an introduced predator in a year."))
	register(r, fraction_layer("bat.disturbance_risk", "bats", PALETTE_HEAT,
		"Risk that the cell's roost habitat is lost to harvest, clearance or subdivision."))
}

// Introduced predators, in the units New Zealand monitoring actually reports:
// tracking tunnel indices and residual trap catch.
register_predator_layers :: proc(r: ^Registry) {
	register(r, scalar_layer("pest.rat_tracking_index", "predators", "%", .U8, 100.0 / 254.0, 0, 0, 100, PALETTE_HEAT, .Mean,
		"Ship rat tracking tunnel index. Above about 20% a bat colony is losing more animals than it replaces."))
	register(r, scalar_layer("pest.stoat_tracking_index", "predators", "%", .U8, 100.0 / 254.0, 0, 0, 100, PALETTE_HEAT, .Mean,
		"Mustelid tracking tunnel index."))
	register(r, scalar_layer("pest.possum_rtc", "predators", "%", .U8, 40.0 / 254.0, 0, 0, 40, PALETTE_HEAT, .Mean,
		"Possum residual trap catch. Possums compete for the same cavities and eat the same fruit."))
	register(r, fraction_layer("pest.cat_pressure", "predators", PALETTE_HEAT,
		"Feral and companion cat pressure. The reason urban Hamilton bats fare worse than their habitat suggests."))
	register(r, categorical_layer("pest.control_regime", "predators", NZ_PEST_CONTROL_CLASSES[:],
		"Predator control in force over the cell."))
	register(r, scalar_layer("pest.years_since_control", "predators", "years", .U8, 1, 0, 0, 60, PALETTE_HEAT, .Min,
		"Time since the last control operation. Rat numbers are back to pre-treatment within about two years."))
	register(r, fraction_layer("pest.mast_risk", "predators", PALETTE_HEAT,
		"Probability of a heavy beech or podocarp seedfall this year. A mast drives a rodent irruption, then a stoat irruption, then bat losses."))
	register(r, fraction_layer("pest.control_benefit", "predators", PALETTE_GREENS,
		"Modelled reduction in predation risk attributable to the control regime in force."))
}

// The plantation estate. Long-tailed bats roost and forage in it, harvesting
// removes their roosts, and the NES-PF rules that govern it are spatial, so the
// forestry side has to be modelled at the same resolution as the habitat.
register_forestry_layers :: proc(r: ^Registry) {
	register(r, categorical_layer("forestry.crop_species", "forestry", NZ_PLANTATION_SPECIES[:],
		"Planted crop species."))
	register(r, categorical_layer("forestry.silviculture", "forestry", NZ_SILVICULTURE_CLASSES[:],
		"Silvicultural regime, which sets canopy structure and so what the stand offers a foraging bat."))
	register(r, categorical_layer("forestry.erosion_class", "forestry", NZ_EROSION_SUSCEPTIBILITY[:],
		"NES-PF erosion susceptibility class, which governs what harvesting is permitted."))
	register(r, scalar_layer("forestry.planted_year", "forestry", "year", .U16, 1, 0, 1850, 2100, PALETTE_VIRIDIS, .Mean,
		"Year the current crop was established."))
	register(r, scalar_layer("forestry.rotation_length", "forestry", "years", .U8, 1, 0, 0, 120, PALETTE_VIRIDIS, .Mean,
		"Planned rotation. About 28 years for radiata, 45 or more for Douglas-fir."))
	register(r, scalar_layer("forestry.years_to_harvest", "forestry", "years", .I16, 1, 0, -40, 60, PALETTE_DIVERGING, .Mean,
		"Years until the crop reaches rotation age. Negative where it is standing past it."))
	register(r, scalar_layer("forestry.stems_per_ha", "forestry", "stems/ha", .U16, 1, 0, 0, 3000, PALETTE_GREENS, .Mean,
		"Stocking after thinning."))
	register(r, scalar_layer("forestry.mean_dbh", "forestry", "cm", .U8, 120.0 / 254.0, 0, 0, 120, PALETTE_GREENS, .Mean,
		"Mean diameter at breast height of the crop."))
	register(r, scalar_layer("forestry.recoverable_volume", "forestry", "m3/ha", .U16, 0.05, 0, 0, 1500, PALETTE_GREENS, .Mean,
		"Volume recoverable at the landing, after breakage and cull."))
	register(r, boolean_layer("forestry.riparian_setback", "forestry",
		"Inside a riparian setback retained under the NES-PF. These strips are also the best bat commuting lines in a plantation."))
	register(r, fraction_layer("forestry.retained_habitat", "forestry", PALETTE_GREENS,
		"Fraction of the cell held out of the harvest schedule as retained habitat."))
	register(r, fraction_layer("forestry.wilding_risk", "forestry", PALETTE_HEAT,
		"Risk of wilding conifer spread from this cell into open country."))
	register(r, fraction_layer("forestry.slash_risk", "forestry", PALETTE_HEAT,
		"Risk that harvest residue mobilises off this cell in a storm."))
	register(r, boolean_layer("forestry.certified", "forestry",
		"Under FSC or equivalent certification, which brings a bat survey obligation before clearfell."))
}

// ---------------------------------------------------------------------------
// Component indices into `forest.composition_nz`
// ---------------------------------------------------------------------------

// Named so that a model can ask for "the podocarp fraction" rather than
// component three, and so that reordering NZ_TREE_GROUPS is a compile error
// away from being caught rather than a silent change of meaning.
NZ_GROUP_PODOCARP :: 0
NZ_GROUP_BEECH :: 1
NZ_GROUP_BROADLEAF :: 2
NZ_GROUP_KAURI :: 3
NZ_GROUP_MANUKA :: 4
NZ_GROUP_TREE_FERN :: 5
NZ_GROUP_NIKAU :: 6
NZ_GROUP_RADIATA :: 7
NZ_GROUP_DOUGLAS_FIR :: 8
NZ_GROUP_EUCALYPT :: 9
NZ_GROUP_WILLOW :: 10
NZ_TREE_GROUP_COUNT :: 11
