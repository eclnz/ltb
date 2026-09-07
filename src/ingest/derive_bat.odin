package ingest

import "core:math"
import hex "ltb:hex"
import "ltb:layers"
import "ltb:world"

/*
The bat habitat model.

New Zealand has two surviving bats and they want opposite things from a
landscape, which is why they get one model with two answers rather than a single
"suitability" number.

The long-tailed bat is a fast open-flying aerial hawker. It roosts in cavities in
big old trees -- indigenous or, increasingly, exotic conifers -- switches roost
almost every day, and forages along the *edges* of the canopy: forest margins,
river channels, shelter belts, treelined roads, the boundary between a pine
compartment and a paddock. A landscape of solid unbroken forest suits it less
well than the same forest cut through with rivers and margins. It persists in
farmland and in a few cities, Hamilton among them, wherever enough old trees and
enough dark linear structure survive together.

The lesser short-tailed bat wants the opposite: large tracts of unbroken
old-growth indigenous forest with very large emergent podocarps, because it
forages on the forest floor as much as in the air. Edge does nothing for it and
fragmentation is fatal. It is also far more exposed to predation, since a bat
that crawls on the ground meets everything that hunts there.

Both are held below carrying capacity by introduced predators, so the model
carries a predation term rather than treating habitat as if it were enough.

None of the inputs are mandatory. Whatever a region's manifest managed to ingest
is used; the rest is estimated from what is there, and the estimate is written
back into the corresponding layer only where nothing was ingested, so a real
survey is never overwritten by a guess.
*/

// Reference values the model is scaled against. They are separated out because
// they are the part a user with local data would want to re-fit.
BAT_ROOST_TREES_FOR_FULL_HABITAT :: 6.0 // cavity stems/ha for a full roost network
BAT_SHORT_TAILED_ROOST_TREES :: 10.0 // the short-tailed bat needs more, and bigger
BAT_WATER_DECAY_M :: 600.0 // foraging value halves about every 400 m from water
BAT_COMMUTE_DECAY_M :: 300.0 // commuting lines are tighter to the channel
BAT_LIGHT_HALF_RADIANCE :: 25.0 // nW/cm2/sr at which lighting costs most of its penalty

// Layer ids the model reads and writes. `layers.INVALID_LAYER` marks one that
// this world does not have, and every read goes through `opt` so a missing
// input costs a default rather than a crash.
Bat_Layers :: struct {
	// inputs: structure
	canopy, canopy_height, emergent, stand_age, composition: layers.Layer_Id,
	cavity, old_growth, lcdb:                                layers.Layer_Id,
	// inputs: setting
	temp_mean, wind, humidity:                               layers.Layer_Id,
	distance_to_water, water_permanent:                      layers.Layer_Id,
	built_up, night_light, tenure:                           layers.Layer_Id,
	// inputs: pressure
	rat, stoat, control_regime, years_since_control, mast:   layers.Layer_Id,
	years_to_harvest, riparian_setback, retained_habitat:    layers.Layer_Id,
	// outputs
	edge_density, prey, roost, forage, commute:              layers.Layer_Id,
	hsi_long_tailed, hsi_short_tailed:                       layers.Layer_Id,
	predation, disturbance, control_benefit:                 layers.Layer_Id,
}

// Resolves every layer the model touches. `ok` is false only when
// `forest.density` is missing, since without canopy cover there is nothing to
// model from.
resolve_bat_layers :: proc(r: ^layers.Registry) -> (ids: Bat_Layers, ok: bool) {
	opt :: proc(reg: ^layers.Registry, name: string) -> layers.Layer_Id {
		id, found := layers.lookup(reg, name)
		return found ? id : layers.INVALID_LAYER
	}
	ids.canopy = opt(r, "forest.density")
	ids.canopy_height = opt(r, "forest.canopy_height")
	ids.emergent = opt(r, "forest.emergent_height")
	ids.stand_age = opt(r, "forest.stand_age")
	ids.composition = opt(r, "forest.composition_nz")
	ids.cavity = opt(r, "forest.cavity_tree_density")
	ids.old_growth = opt(r, "forest.old_growth")
	ids.lcdb = opt(r, "nz.lcdb_class")

	ids.temp_mean = opt(r, "climate.temp_mean_annual")
	ids.wind = opt(r, "climate.wind_speed")
	ids.humidity = opt(r, "climate.humidity")
	ids.distance_to_water = opt(r, "water.distance_to_water")
	ids.water_permanent = opt(r, "water.permanent")
	ids.built_up = opt(r, "human.built_up")
	ids.night_light = opt(r, "human.night_light")
	ids.tenure = opt(r, "nz.tenure")

	ids.rat = opt(r, "pest.rat_tracking_index")
	ids.stoat = opt(r, "pest.stoat_tracking_index")
	ids.control_regime = opt(r, "pest.control_regime")
	ids.years_since_control = opt(r, "pest.years_since_control")
	ids.mast = opt(r, "pest.mast_risk")
	ids.years_to_harvest = opt(r, "forestry.years_to_harvest")
	ids.riparian_setback = opt(r, "forestry.riparian_setback")
	ids.retained_habitat = opt(r, "forestry.retained_habitat")

	ids.edge_density = opt(r, "forest.edge_density")
	ids.prey = opt(r, "bat.prey_abundance")
	ids.roost = opt(r, "bat.roost_suitability")
	ids.forage = opt(r, "bat.foraging_suitability")
	ids.commute = opt(r, "bat.commuting_value")
	ids.hsi_long_tailed = opt(r, "bat.habitat_suitability")
	ids.hsi_short_tailed = opt(r, "bat.habitat_suitability_short_tailed")
	ids.predation = opt(r, "bat.predation_risk")
	ids.disturbance = opt(r, "bat.disturbance_risk")
	ids.control_benefit = opt(r, "pest.control_benefit")

	ok = ids.canopy != layers.INVALID_LAYER
	return
}

// ---------------------------------------------------------------------------
// Small numeric helpers
// ---------------------------------------------------------------------------

// A linear response that saturates: 0 at or below `lo`, 1 at or above `hi`.
@(private)
ramp :: proc "contextless" (v, lo, hi: f64) -> f64 {
	if hi <= lo {
		return v >= hi ? 1 : 0
	}
	return clamp((v - lo) / (hi - lo), 0, 1)
}

// Reads an optional layer, falling back when the layer or the cell is missing.
@(private)
opt_get :: proc(w: ^world.World, id: layers.Layer_Id, level: u8, h: hex.Hex, fallback: f64) -> f64 {
	if id == layers.INVALID_LAYER {
		return fallback
	}
	v, ok := layers.get(w.store, id, level, h)
	return ok ? v : fallback
}

// True when the layer exists and already holds a value here, which is how the
// model tells an ingested measurement from a gap it is free to fill.
@(private)
has_value :: proc(w: ^world.World, id: layers.Layer_Id, level: u8, h: hex.Hex) -> bool {
	if id == layers.INVALID_LAYER {
		return false
	}
	_, ok := layers.get(w.store, id, level, h)
	return ok
}

@(private)
set_opt :: proc(w: ^world.World, id: layers.Layer_Id, level: u8, h: hex.Hex, v: f64) {
	if id != layers.INVALID_LAYER {
		layers.set(w.store, id, level, h, v)
	}
}

// ---------------------------------------------------------------------------
// Edge density
// ---------------------------------------------------------------------------

/*
Canopy edge per hectare, from the contrast in canopy cover across each of a
cell's six shared sides.

A hex cell shares a full side with each neighbour, so the edge contributed by
one neighbour is the side length times how much the canopy changes across it.
A closed-canopy cell surrounded by pasture scores the maximum, six sides' worth;
a cell inside continuous forest scores nothing.

The absolute number depends on cell size, as every edge density measure does --
halve the cell and you double the edge per hectare of the same boundary -- so
the habitat model normalises against the maximum the layout can produce rather
than against a fixed figure.
*/
derive_edge_density :: proc(
	w: ^world.World,
	canopy, edge: layers.Layer_Id,
	level := 0,
	bounds: Maybe(hex.Bounds) = nil,
) -> (
	cells: int,
) {
	if canopy == layers.INVALID_LAYER || edge == layers.INVALID_LAYER {
		return 0
	}
	lay := world.layout(w, level)
	region := bounds.? or_else world.extent(w, level)
	lvl := u8(level)

	// For a regular hexagon the circumradius equals the side length, and the
	// side is what two neighbours share.
	side_m := lay.size.x
	area_ha := hex.cell_area(lay) / 10_000.0
	if area_ha <= 0 {
		return 0
	}

	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			c0, ok := layers.get(w.store, canopy, lvl, h)
			if !ok {
				continue
			}
			total := 0.0
			for dir in 0 ..< 6 {
				// A neighbour with no data is treated as matching this cell,
				// so the edge of the ingested area is not read as habitat edge.
				cn := opt_get(w, canopy, lvl, hex.neighbor(h, hex.Direction(dir)), c0)
				total += side_m * abs(c0 - cn)
			}
			layers.set(w.store, edge, lvl, h, total / area_ha)
			cells += 1
		}
	}
	return
}

// The largest edge density this layout can produce: one cell of closed canopy
// with open ground on all six sides. Used to turn metres per hectare into a
// resolution-independent 0..1 response.
@(private)
max_edge_density :: proc(w: ^world.World, level: int) -> f64 {
	lay := world.layout(w, level)
	area_ha := hex.cell_area(lay) / 10_000.0
	if area_ha <= 0 {
		return 1
	}
	return 6.0 * lay.size.x / area_ha
}

// ---------------------------------------------------------------------------
// Distance to water
// ---------------------------------------------------------------------------

/*
Straight-line distance from every cell to the nearest permanent water, by
breadth-first search out from the water itself.

Rivers are the backbone of long-tailed bat foraging -- the insects are over the
channel and the canopy that lines it is the commuting route -- so the model needs
this layer, and a world assembled from ingested data alone has no generator to
produce it.

Distance is counted in cell pitches, so it is a hex-grid distance rather than a
true Euclidean one: along a grid axis it is exact, and off-axis it overstates by
up to about a seventh. At the range that matters here, a few hundred metres, that
is well inside the error in the input.

The search only enters cells that `present` has data for, which keeps it inside
the ingested footprint instead of flooding the whole world.
*/
derive_distance_to_water :: proc(
	w: ^world.World,
	water, distance, present: layers.Layer_Id,
	level := 0,
	max_metres := 20_000.0,
	bounds: Maybe(hex.Bounds) = nil,
) -> (
	cells: int,
) {
	if water == layers.INVALID_LAYER || distance == layers.INVALID_LAYER {
		return 0
	}
	lay := world.layout(w, level)
	region := bounds.? or_else world.extent(w, level)
	lvl := u8(level)
	pitch := hex.cell_pitch(lay)
	if pitch <= 0 {
		return 0
	}

	queue := make([dynamic]hex.Hex, 0, 4096)
	defer delete(queue)

	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			if opt_get(w, water, lvl, h, 0) > 0.5 {
				layers.set(w.store, distance, lvl, h, 0)
				append(&queue, h)
				cells += 1
			}
		}
	}

	// A plain FIFO: every step costs the same pitch, so the first time a cell is
	// reached is by its shortest path and it never needs revisiting.
	head := 0
	for head < len(queue) {
		h := queue[head]
		head += 1
		next := layers.get_or(w.store, distance, lvl, h, 0) + pitch
		if next > max_metres {
			continue
		}
		for dir in 0 ..< 6 {
			n := hex.neighbor(h, hex.Direction(dir))
			if !hex.bounds_contains(region, n) {
				continue
			}
			if _, seen := layers.get(w.store, distance, lvl, n); seen {
				continue
			}
			if present != layers.INVALID_LAYER && !has_value(w, present, lvl, n) {
				continue
			}
			layers.set(w.store, distance, lvl, n, next)
			append(&queue, n)
			cells += 1
		}
	}
	return
}

// ---------------------------------------------------------------------------
// The habitat model
// ---------------------------------------------------------------------------

Bat_Stats :: struct {
	cells:            int,
	long_tailed_good: int, // cells scoring over 0.5 for the long-tailed bat
	short_tailed_good: int,
}

/*
Fills the bat layers over `bounds`.

Three passes, because the answer is not local: a bat roosts in one cell and
forages in another, so the combined index has to see its neighbours' roost
values, which do not exist until the first pass has run.

  1. edge density, from canopy cover
  2. per-cell terms: prey, roost, foraging, commuting, predation, disturbance
  3. the combined indices, which read the roost surface around each cell
*/
derive_bat_habitat :: proc(
	w: ^world.World,
	level := 0,
	bounds: Maybe(hex.Bounds) = nil,
) -> (
	stats: Bat_Stats,
	ok: bool,
) {
	ids := resolve_bat_layers(w.registry) or_return
	region := bounds.? or_else world.extent(w, level)
	lvl := u8(level)

	derive_edge_density(w, ids.canopy, ids.edge_density, level, region)
	edge_max := max_edge_density(w, level)

	// Distance to water, unless something already produced it: the generator
	// does when it runs, and an ingest of a real hydrological distance grid
	// would too.
	if ids.distance_to_water != layers.INVALID_LAYER {
		if layers.count_chunks(w.store, ids.distance_to_water, lvl) == 0 {
			derive_distance_to_water(w, ids.water_permanent, ids.distance_to_water, ids.canopy, level, 20_000, region)
		}
	}

	// ---- pass two: everything a cell can answer on its own --------------
	comps: [layers.NZ_TREE_GROUP_COUNT]f64
	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			canopy, has_canopy := layers.get(w.store, ids.canopy, lvl, h)
			if !has_canopy {
				continue
			}
			stats.cells += 1

			// -- setting --------------------------------------------------
			temp := opt_get(w, ids.temp_mean, lvl, h, 11)
			// Both species thin out as the mean annual temperature falls; by
			// the treeline there is not enough insect flying time in a summer
			// night to keep a colony fed.
			thermal := ramp(temp, 2, 9)

			water_m := opt_get(w, ids.distance_to_water, lvl, h, 2000)
			if opt_get(w, ids.water_permanent, lvl, h, 0) > 0.5 {
				water_m = 0
			}
			water_near := math.exp(-water_m / BAT_WATER_DECAY_M)
			channel_near := math.exp(-water_m / BAT_COMMUTE_DECAY_M)

			light := opt_get(w, ids.night_light, lvl, h, 0)
			// Long-tailed bats will not cross a well-lit gap, so lighting cuts
			// the value of ground that is otherwise fine.
			light_factor := 1.0 - 0.55 * ramp(light, 0.5, BAT_LIGHT_HALF_RADIANCE)

			wind := opt_get(w, ids.wind, lvl, h, 4)
			shelter := 1.0 - 0.45 * ramp(wind, 4, 12)

			// Canopy in reach, not just in the cell: a bat crossing a paddock
			// is still in habitat if there are trees on the far side.
			canopy_ctx := canopy
			for dir in 0 ..< 6 {
				canopy_ctx = math.max(canopy_ctx, opt_get(w, ids.canopy, lvl, hex.neighbor(h, hex.Direction(dir)), 0))
			}

			// -- stand structure ------------------------------------------
			height := opt_get(w, ids.canopy_height, lvl, h, 0)
			emergent := opt_get(w, ids.emergent, lvl, h, height)
			age := opt_get(w, ids.stand_age, lvl, h, 0)

			indigenous, exotic_roostable, beech := 0.0, 0.0, 0.0
			has_composition := ids.composition != layers.INVALID_LAYER
			if has_composition && layers.get_components(w.store, ids.composition, lvl, h, comps[:]) {
				indigenous =
					comps[layers.NZ_GROUP_PODOCARP] +
					comps[layers.NZ_GROUP_BEECH] +
					comps[layers.NZ_GROUP_BROADLEAF] +
					comps[layers.NZ_GROUP_KAURI]
				exotic_roostable =
					comps[layers.NZ_GROUP_RADIATA] +
					comps[layers.NZ_GROUP_DOUGLAS_FIR] +
					comps[layers.NZ_GROUP_EUCALYPT] +
					comps[layers.NZ_GROUP_WILLOW]
				beech = comps[layers.NZ_GROUP_BEECH]
			} else {
				// With no composition ingested, read the split off land cover:
				// LCDB tells indigenous forest from exotic outright.
				lcdb := opt_get(w, ids.lcdb, lvl, h, -1)
				switch int(lcdb) {
				case 69, 54, 70:
					indigenous = 1
				case 52, 55, 58, 50:
					indigenous = 0.6
				case 71, 64, 68:
					exotic_roostable = 1
				case:
					indigenous = 0.5
					exotic_roostable = 0.5
				}
			}

			// Cavities are what a roost is. Indigenous stems take a century and
			// a half to grow them; a pine grows something usable by its second
			// rotation, which is why long-tailed bats turn up in Hanmer and
			// Kinleith at all.
			cavity, cavity_measured := layers.get(w.store, ids.cavity, lvl, h)
			if !cavity_measured {
				cavity =
					canopy *
					(12.0 * indigenous * ramp(age, 40, 160) +
						5.0 * exotic_roostable * ramp(age, 18, 32))
				if !has_value(w, ids.stand_age, lvl, h) {
					// No stand age either: fall back on height, which at least
					// separates a mature stand from a recent cutover.
					cavity = canopy * (12.0 * indigenous + 5.0 * exotic_roostable) * ramp(emergent, 12, 32)
				}
				set_opt(w, ids.cavity, lvl, h, cavity)
			}

			// -- prey ------------------------------------------------------
			prey, prey_measured := layers.get(w.store, ids.prey, lvl, h)
			if !prey_measured {
				humidity := opt_get(w, ids.humidity, lvl, h, 0.75)
				prey = clamp(
					0.12 +
					0.42 * ramp(temp, 4, 14) +
					0.24 * water_near +
					0.14 * canopy_ctx +
					0.16 * humidity,
					0,
					1,
				)
				set_opt(w, ids.prey, lvl, h, prey)
			}

			// -- roosting --------------------------------------------------
			// Roost switching every day or two means a colony needs many
			// options within a few hundred metres, not one good tree.
			roost :=
				clamp(cavity / BAT_ROOST_TREES_FOR_FULL_HABITAT, 0, 1) *
				(0.45 + 0.55 * ramp(emergent, 12, 28)) *
				thermal
			set_opt(w, ids.roost, lvl, h, roost)

			// -- foraging, long-tailed -------------------------------------
			edge_frac := clamp(opt_get(w, ids.edge_density, lvl, h, 0) / math.max(1e-6, edge_max), 0, 1)
			// A hump, not a ramp. Solid forest and bare paddock are both poor;
			// the mosaic between them is where this bat feeds.
			edge_response := clamp(0.25 + 0.75 * 4.0 * edge_frac * (1.0 - edge_frac), 0, 1)
			forage :=
				(0.40 * edge_response + 0.28 * water_near + 0.32 * prey) *
				clamp(canopy_ctx / 0.35, 0, 1) *
				shelter *
				light_factor *
				thermal
			forage = clamp(forage, 0, 1)
			set_opt(w, ids.forage, lvl, h, forage)

			// -- commuting -------------------------------------------------
			// The linear structure that joins roost to foraging ground: a
			// forest margin, a river with trees on it, a shelter belt.
			commute :=
				clamp(0.65 * edge_frac + 0.65 * channel_near, 0, 1) *
				clamp(canopy_ctx / 0.25, 0, 1) *
				light_factor
			set_opt(w, ids.commute, lvl, h, commute)

			// -- predation -------------------------------------------------
			// Rat and stoat indices where they were surveyed; otherwise the
			// standing assumption for uncontrolled New Zealand forest, which is
			// that rats are abundant.
			default_rat := 12.0 + 18.0 * indigenous + 12.0 * opt_get(w, ids.built_up, lvl, h, 0)
			rat := opt_get(w, ids.rat, lvl, h, default_rat)
			stoat := opt_get(w, ids.stoat, lvl, h, 5.0 + 6.0 * indigenous)
			// A beech mast feeds a rodent irruption, and the stoats follow a
			// season later. This is the mechanism behind most recorded bat
			// colony collapses.
			mast := opt_get(w, ids.mast, lvl, h, 0.06 + 0.22 * beech)

			benefit := control_benefit_for(
				int(opt_get(w, ids.control_regime, lvl, h, 0)),
				opt_get(w, ids.years_since_control, lvl, h, 0),
			)
			set_opt(w, ids.control_benefit, lvl, h, benefit)

			predation := clamp(
				(0.10 + 0.55 * clamp(rat / 100, 0, 1) + 0.30 * clamp(stoat / 100, 0, 1) + 0.25 * mast) *
				(1.0 - benefit),
				0,
				1,
			)
			set_opt(w, ids.predation, lvl, h, predation)

			// -- disturbance -----------------------------------------------
			disturbance := disturbance_risk(w, &ids, lvl, h, exotic_roostable)
			set_opt(w, ids.disturbance, lvl, h, disturbance)
		}
	}

	// ---- pass three: the combined indices --------------------------------
	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			canopy, has_canopy := layers.get(w.store, ids.canopy, lvl, h)
			if !has_canopy {
				continue
			}
			roost := opt_get(w, ids.roost, lvl, h, 0)
			forage := opt_get(w, ids.forage, lvl, h, 0)
			predation := opt_get(w, ids.predation, lvl, h, 0.4)
			disturbance := opt_get(w, ids.disturbance, lvl, h, 0.2)

			// A roost one cell away still serves this cell, at a discount:
			// long-tailed bats commute kilometres between roost and feeding
			// ground every night.
			roost_reach := roost
			for dir in 0 ..< 6 {
				n := opt_get(w, ids.roost, lvl, hex.neighbor(h, hex.Direction(dir)), 0)
				roost_reach = math.max(roost_reach, 0.75 * n)
			}

			// Geometric, not additive: a cell with roosts and no food is no
			// more use than a cell with food and nowhere to sleep.
			hsi := math.sqrt(roost_reach * forage) * (1.0 - 0.6 * predation) * (1.0 - 0.5 * disturbance)
			set_opt(w, ids.hsi_long_tailed, lvl, h, clamp(hsi, 0, 1))
			if hsi > 0.5 {
				stats.long_tailed_good += 1
			}

			// The short-tailed bat: interior forest, very large stems, and no
			// tolerance at all for fragmentation or predators.
			intact := neighbourhood_mean(w, ids.canopy, lvl, h, canopy)
			emergent := opt_get(w, ids.emergent, lvl, h, opt_get(w, ids.canopy_height, lvl, h, 0))
			cavity := opt_get(w, ids.cavity, lvl, h, 0)
			old_growth := opt_get(w, ids.old_growth, lvl, h, canopy)
			st_roost :=
				clamp(cavity / BAT_SHORT_TAILED_ROOST_TREES, 0, 1) *
				ramp(emergent, 18, 34) *
				intact * intact
			st_forage := clamp(0.55 * intact + 0.25 * old_growth + 0.20 * opt_get(w, ids.prey, lvl, h, 0.4), 0, 1)
			st := math.sqrt(st_roost * st_forage) * (1.0 - 0.8 * predation) * (1.0 - 0.5 * disturbance)
			set_opt(w, ids.hsi_short_tailed, lvl, h, clamp(st, 0, 1))
			if st > 0.5 {
				stats.short_tailed_good += 1
			}
		}
	}
	return stats, true
}

// Mean of a layer over a cell and its six neighbours, skipping cells with no
// data so the edge of an ingested area is not dragged towards zero.
@(private)
neighbourhood_mean :: proc(
	w: ^world.World,
	id: layers.Layer_Id,
	level: u8,
	h: hex.Hex,
	fallback: f64,
) -> f64 {
	if id == layers.INVALID_LAYER {
		return fallback
	}
	sum, n := 0.0, 0
	if v, got := layers.get(w.store, id, level, h); got {
		sum += v
		n += 1
	}
	for dir in 0 ..< 6 {
		if v, got := layers.get(w.store, id, level, hex.neighbor(h, hex.Direction(dir))); got {
			sum += v
			n += 1
		}
	}
	if n == 0 {
		return fallback
	}
	return sum / f64(n)
}

// How much of the predation risk a control regime removes, and how fast that
// decays. Ship rats are back to pre-treatment densities within about three
// years of a knockdown, so an operation is only as good as its last visit --
// except behind a fence, which does not decay.
@(private)
control_benefit_for :: proc(regime: int, years_since: f64) -> f64 {
	base := 0.0
	decays := true
	switch regime {
	case 1:
		base = 0.25 // ground trapping
	case 2:
		base = 0.35 // ground bait stations
	case 3:
		base = 0.70 // aerial 1080
	case 4:
		base = 0.55 // self-resetting trap network
		decays = false
	case 5:
		base = 0.95 // predator-proof fence
		decays = false
	case 6:
		base = 0.98 // island or eradicated mainland
		decays = false
	case:
		return 0
	}
	if !decays {
		return base
	}
	return base * clamp(1.0 - years_since / 3.0, 0, 1)
}

// The chance this cell's roost habitat is gone within a planning horizon.
// Tenure decides most of it: the same stand is safe on conservation land and
// a consent application away from felling on private land.
@(private)
disturbance_risk :: proc(
	w: ^world.World,
	ids: ^Bat_Layers,
	level: u8,
	h: hex.Hex,
	exotic_fraction: f64,
) -> f64 {
	risk := 0.20
	switch int(opt_get(w, ids.tenure, level, h, 0)) {
	case 1, 4:
		risk = 0.04 // public conservation land, QEII covenant
	case 2, 3:
		risk = 0.08 // other Crown, council reserve
	case 5:
		risk = 0.15
	case 6:
		risk = 0.55 // private plantation: the crop is there to be cut
	case 7:
		risk = 0.35 // private farmland: remnants and shelter belts go first
	case 8:
		risk = 0.40 // subdivision and tree removal
	case 9:
		risk = 0.30
	}

	// A crop close to rotation age is the specific risk, not the estate.
	if ids.years_to_harvest != layers.INVALID_LAYER {
		if yrs, got := layers.get(w.store, ids.years_to_harvest, level, h); got {
			risk = math.max(risk, 0.85 * exotic_fraction * ramp(-yrs, -10, 0))
		}
	}
	// Retention takes it back off again.
	if opt_get(w, ids.riparian_setback, level, h, 0) > 0.5 {
		risk *= 0.35
	}
	risk *= 1.0 - 0.6 * opt_get(w, ids.retained_habitat, level, h, 0)
	risk += 0.25 * opt_get(w, ids.built_up, level, h, 0)
	return clamp(risk, 0, 1)
}
