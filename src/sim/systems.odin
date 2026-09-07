package sim

import "core:math"
import "core:math/rand"
import hex "ltb:hex"
import "ltb:layers"
import "ltb:world"

/*
The built-in systems.

Each is a plain proc over the layer store. They are written to be readable
rather than clever: the models are the simplest thing that produces the right
shape of behaviour, and every constant that means something physical is named
and commented so it can be argued with.
*/

@(private)
lvl :: proc(s: ^Sim) -> u8 {
	return u8(s.level)
}

// Soil and fuel moisture relax towards the value the climate implies, at a rate
// set by how far they are from it. An exponential approach with a time constant
// of a few weeks is the standard first-order bucket model, and it is enough to
// give droughts a memory.
system_moisture :: proc(s: ^Sim, elapsed_days: f64) {
	cells := layers.collect_cells(s.world.store, s.ids.soil_moisture, lvl(s), context.temp_allocator)
	defer delete(cells, context.temp_allocator)

	SOIL_TAU_DAYS :: 45.0
	FUEL_TAU_DAYS :: 6.0 // fine fuels dry out in days, not weeks

	soil_k := 1.0 - math.exp(-elapsed_days / SOIL_TAU_DAYS)
	fuel_k := 1.0 - math.exp(-elapsed_days / FUEL_TAU_DAYS)

	// A crude annual cycle: drier in the second half of the year.
	season := 1.0 + 0.28 * math.sin(clock_day_of_year(s.clock) / 365.2425 * 2.0 * math.PI)

	n := 0
	for c in cells {
		precip := layers.get_or(s.world.store, s.ids.precip, lvl(s), c.hex, 800)
		temp := layers.get_or(s.world.store, s.ids.temp_mean, lvl(s), c.hex, 10)
		slope := layers.get_or(s.world.store, s.ids.slope, lvl(s), c.hex, 0)
		canopy := layers.get_or(s.world.store, s.ids.forest_density, lvl(s), c.hex, 0)

		// Equilibrium wetness: more rain wets, heat and slope dry, canopy shades.
		target := clamp(
			precip / 2400.0 * season - math.max(0.0, temp - 12.0) * 0.018 - slope * 0.005 + canopy * 0.10,
			0.02,
			1.0,
		)
		moisture := c.value + (target - c.value) * soil_k
		layers.set(s.world.store, s.ids.soil_moisture, lvl(s), c.hex, moisture)

		// Fine fuel moisture tracks the soil but swings much harder.
		fuel_target := clamp(moisture * 0.75 + 0.05, 0.02, 0.9)
		fm := layers.get_or(s.world.store, s.ids.fuel_moisture, lvl(s), c.hex, fuel_target)
		layers.set(s.world.store, s.ids.fuel_moisture, lvl(s), c.hex, fm + (fuel_target - fm) * fuel_k)
		n += 1
	}
	mark_dirty(s, s.ids.soil_moisture)
	mark_dirty(s, s.ids.fuel_moisture)
	set_last_cells(s, "moisture", n)
}

// Stand development. Canopy cover approaches the site's carrying capacity
// logistically, height follows a saturating curve with age, and biomass follows
// from the two. This is the shape a yield table has, without pretending to be
// one for any particular species.
system_forest_growth :: proc(s: ^Sim, elapsed_days: f64) {
	years := elapsed_days / 365.2425
	if years <= 0 {
		return
	}
	cells := layers.collect_cells(s.world.store, s.ids.forest_density, lvl(s), context.temp_allocator)
	defer delete(cells, context.temp_allocator)

	n := 0
	for c in cells {
		h := c.hex
		density := c.value
		gdd := layers.get_or(s.world.store, s.ids.gdd, lvl(s), h, 2000)
		moisture := layers.get_or(s.world.store, s.ids.soil_moisture, lvl(s), h, 0.4)
		soil_depth := layers.get_or(s.world.store, s.ids.soil_depth, lvl(s), h, 1.0)
		slope := layers.get_or(s.world.store, s.ids.slope, lvl(s), h, 0)
		fire := layers.get_or(s.world.store, s.ids.fire_state, lvl(s), h, 0)

		// Nothing grows while it is on fire.
		if fire == 2 || fire == 3 {
			continue
		}

		// Carrying capacity: the cover this site can hold at equilibrium.
		capacity := clamp(
			smoothstep(400, 3000, gdd) *
			smoothstep(0.08, 0.45, moisture) *
			smoothstep(0.10, 0.80, soil_depth) *
			(1.0 - smoothstep(35.0, 58.0, slope)),
			0.0,
			1.0,
		)
		if capacity < 0.02 {
			capacity = 0
		}

		// Logistic growth. r is per year; 0.11 gives a stand roughly 40 years to
		// close canopy from a light seedling stock, which is about right for a
		// productive temperate site.
		R :: 0.11
		if density < 0.001 && capacity > 0.05 {
			// Regeneration seeds new cover where there is none.
			regen := layers.get_or(s.world.store, s.ids.regeneration, lvl(s), h, 0)
			density = math.max(density, regen * 0.05)
			if density < 0.001 {
				density = 0.004 * capacity
			}
		}
		if capacity > 0 {
			growth := R * density * (1.0 - density / capacity) * years
			density = clamp(density + growth, 0, capacity)
		} else {
			density = math.max(0.0, density - 0.05 * years)
		}
		layers.set(s.world.store, s.ids.forest_density, lvl(s), h, density)

		age := layers.get_or(s.world.store, s.ids.stand_age, lvl(s), h, 0) + years
		layers.set(s.world.store, s.ids.stand_age, lvl(s), h, age)

		// Chapman-Richards height: fast early, asymptotic late.
		site_index := layers.get_or(s.world.store, s.ids.site_index, lvl(s), h, 12.0 + capacity * 26.0)
		if !layers.get_or_ok(s.world.store, s.ids.site_index, lvl(s), h) {
			layers.set(s.world.store, s.ids.site_index, lvl(s), h, site_index)
		}
		h_max := site_index * 1.35
		height := h_max * math.pow(1.0 - math.exp(-0.035 * age), 1.4)
		layers.set(s.world.store, s.ids.canopy_height, lvl(s), h, clamp(height, 0, 80))

		// Biomass from cover and height. The exponent above one reflects that a
		// tall stand holds more per unit of cover than a short one.
		biomass := density * math.pow(math.max(height, 0.5), 1.6) * 1.5
		layers.set(s.world.store, s.ids.biomass, lvl(s), h, biomass)

		// Health decays with drought stress and recovers slowly otherwise.
		health := layers.get_or(s.world.store, s.ids.health, lvl(s), h, 1.0)
		stress := math.max(0.0, 0.22 - moisture) * 4.0
		health = clamp(health + (0.12 - stress) * years, 0.0, 1.0)
		layers.set(s.world.store, s.ids.health, lvl(s), h, health)

		// Seedling stock builds up under a partly open canopy: too dark under a
		// closed one, too dry in the open.
		light := 1.0 - density
		regen := layers.get_or(s.world.store, s.ids.regeneration, lvl(s), h, 0)
		regen = clamp(regen + (capacity * light * 0.35 - regen * 0.10) * years, 0, 1)
		layers.set(s.world.store, s.ids.regeneration, lvl(s), h, regen)

		n += 1
	}
	mark_dirty(s, s.ids.forest_density)
	mark_dirty(s, s.ids.canopy_height)
	mark_dirty(s, s.ids.biomass)
	mark_dirty(s, s.ids.stand_age)
	set_last_cells(s, "forest growth", n)
}

// Litter and deadwood accumulate from the standing crop and decay at a rate set
// by warmth and moisture. Together they are the surface fuel the fire system
// burns.
system_fuel :: proc(s: ^Sim, elapsed_days: f64) {
	years := elapsed_days / 365.2425
	cells := layers.collect_cells(s.world.store, s.ids.forest_density, lvl(s), context.temp_allocator)
	defer delete(cells, context.temp_allocator)

	n := 0
	for c in cells {
		h := c.hex
		biomass := layers.get_or(s.world.store, s.ids.biomass, lvl(s), h, 0)
		temp := layers.get_or(s.world.store, s.ids.temp_mean, lvl(s), h, 10)
		moisture := layers.get_or(s.world.store, s.ids.soil_moisture, lvl(s), h, 0.4)
		health := layers.get_or(s.world.store, s.ids.health, lvl(s), h, 1)

		// Decomposition roughly doubles per 10 K, and stalls when dry.
		decay := 0.08 * math.pow(2.0, (temp - 10.0) / 10.0) * smoothstep(0.05, 0.35, moisture)

		litter := layers.get_or(s.world.store, s.ids.litter, lvl(s), h, 0)
		litter_in := biomass * 0.035 // annual leaf and fine branch fall
		litter = math.max(0.0, litter + (litter_in - litter * decay * 3.0) * years)
		layers.set(s.world.store, s.ids.litter, lvl(s), h, math.min(litter, 40))

		dead := layers.get_or(s.world.store, s.ids.deadwood, lvl(s), h, 0)
		// Unhealthy stands shed a lot more wood.
		dead_in := biomass * (0.004 + (1.0 - health) * 0.05)
		dead = math.max(0.0, dead + (dead_in - dead * decay) * years)
		layers.set(s.world.store, s.ids.deadwood, lvl(s), h, math.min(dead, 100))

		since := layers.get_or(s.world.store, s.ids.years_since_burn, lvl(s), h, 0) + years
		layers.set(s.world.store, s.ids.years_since_burn, lvl(s), h, math.min(since, 2000))
		n += 1
	}
	mark_dirty(s, s.ids.deadwood)
	mark_dirty(s, s.ids.litter)
	set_last_cells(s, "fuel", n)
}

// Fire: ignition, spread and burn-out on the hex graph.
//
// Spread is evaluated per neighbour so wind and slope act directionally, which
// is the whole reason to run fire on a grid rather than as a statistic. Uphill
// and downwind cells catch far more readily, as they do in the field.
system_fire :: proc(s: ^Sim, elapsed_days: f64) {
	store := s.world.store
	level := lvl(s)

	// Base chance per cell per day of an ignition in fully cured fuel. Small,
	// because there are a great many cells.
	IGNITION_BASE :: 2.0e-7

	cells := layers.collect_cells(store, s.ids.fuel_moisture, level, context.temp_allocator)
	defer delete(cells, context.temp_allocator)

	// Cells to change after the sweep, so a fire cannot race across the map
	// within a single tick.
	Change :: struct {
		h:         hex.Hex,
		state:     f64,
		intensity: f64,
	}
	changes := make([dynamic]Change, 0, 256, context.temp_allocator)
	defer delete(changes)

	burning := 0
	for c in cells {
		h := c.hex
		state := layers.get_or(store, s.ids.fire_state, level, h, 0)
		fuel_moisture := c.value
		density := layers.get_or(store, s.ids.forest_density, level, h, 0)
		litter := layers.get_or(store, s.ids.litter, level, h, 0)
		dead := layers.get_or(store, s.ids.deadwood, level, h, 0)
		fuel_load := litter + dead * 0.6 + density * 12.0

		if state == 2 || state == 3 {
			burning += 1
			// A cell burns out in a few days, faster with less fuel.
			burn_days := 1.0 + fuel_load * 0.08
			if elapsed_days >= burn_days || rand.float64(s.rng) < elapsed_days / burn_days {
				append(&changes, Change{h, 4, 0})
			}
			continue
		}
		if state == 4 {
			// Burnt out: reset once the fuel moisture has recovered.
			if fuel_moisture > 0.35 {
				append(&changes, Change{h, 0, 0})
			}
			continue
		}
		if fuel_load < 0.5 {
			continue
		}

		// Dryness is what turns fuel into a hazard.
		dryness := 1.0 - smoothstep(0.06, 0.32, fuel_moisture)
		if dryness <= 0.01 {
			continue
		}

		// Spread from burning neighbours.
		wind_speed := layers.get_or(store, s.ids.wind_speed, level, h, 4)
		wind_dir := layers.get_or(store, s.ids.wind_direction, level, h, 270)
		elev := layers.get_or(store, s.ids.elevation, level, h, 0)
		p_catch := 0.0
		for d in 0 ..< 6 {
			nh := hex.neighbor(h, hex.Direction(d))
			ns := layers.get_or(store, s.ids.fire_state, level, nh, 0)
			if ns != 2 && ns != 3 {
				continue
			}
			// Bearing from the neighbour to this cell.
			lay := world.layout(s.world, s.level)
			np := hex.to_world(lay, nh)
			cp := hex.to_world(lay, h)
			bearing := math.atan2(cp.x - np.x, cp.y - np.y) * 180.0 / math.PI
			if bearing < 0 {bearing += 360.0}
			align := math.cos((bearing - wind_dir) * math.PI / 180.0)
			wind_factor := 1.0 + math.max(0.0, align) * wind_speed * 0.22

			nelev := layers.get_or(store, s.ids.elevation, level, nh, elev)
			// Fire runs uphill: flames lean into the slope and preheat it.
			slope_factor := 1.0 + clamp((elev - nelev) / 60.0, -0.6, 2.0)

			p_catch += 0.16 * dryness * wind_factor * slope_factor * clamp(fuel_load / 20.0, 0.1, 2.0)
		}
		p_catch = clamp(p_catch * elapsed_days, 0, 0.95)

		// Fresh ignitions, from lightning or people.
		p_ignite := IGNITION_BASE * dryness * dryness * elapsed_days * clamp(fuel_load / 10.0, 0.1, 3.0)

		if rand.float64(s.rng) < p_catch + p_ignite {
			// Crown fire when there is a canopy and the fuel is very dry.
			crown := density > 0.35 && dryness > 0.75
			intensity := fuel_load * 300.0 * dryness * (crown ? 3.0 : 1.0)
			append(&changes, Change{h, crown ? 3 : 2, intensity})
		}
	}

	consumed := 0
	for ch in changes {
		layers.set(store, s.ids.fire_state, level, ch.h, ch.state)
		layers.set(store, s.ids.fire_intensity, level, ch.h, ch.intensity)
		if ch.state == 4 {
			// Burning consumes the surface fuel and part of the canopy.
			layers.set(store, s.ids.litter, level, ch.h, 0)
			dead := layers.get_or(store, s.ids.deadwood, level, ch.h, 0)
			layers.set(store, s.ids.deadwood, level, ch.h, dead * 0.25)
			density := layers.get_or(store, s.ids.forest_density, level, ch.h, 0)
			was_crown := layers.get_or(store, s.ids.fire_intensity, level, ch.h, 0) > 8000
			layers.set(store, s.ids.forest_density, level, ch.h, density * (was_crown ? 0.05 : 0.55))
			layers.set(store, s.ids.stand_age, level, ch.h, was_crown ? 0 : layers.get_or(store, s.ids.stand_age, level, ch.h, 0))
			layers.set(store, s.ids.years_since_burn, level, ch.h, 0)
			layers.set(store, s.ids.health, level, ch.h, was_crown ? 0.0 : 0.6)
			consumed += 1
		}
	}
	if len(changes) > 0 {
		mark_dirty(s, s.ids.fire_state)
		mark_dirty(s, s.ids.fire_intensity)
		mark_dirty(s, s.ids.forest_density)
	}
	set_last_cells(s, "fire", burning + len(changes))
}

// Carbon accounting over the whole stock: live biomass, deadwood and litter,
// converted at the usual 0.47 carbon fraction of dry matter.
system_carbon :: proc(s: ^Sim, elapsed_days: f64) {
	CARBON_FRACTION :: 0.47
	years := math.max(elapsed_days / 365.2425, 1e-6)

	cells := layers.collect_cells(s.world.store, s.ids.biomass, lvl(s), context.temp_allocator)
	defer delete(cells, context.temp_allocator)

	n := 0
	for c in cells {
		h := c.hex
		dead := layers.get_or(s.world.store, s.ids.deadwood, lvl(s), h, 0)
		litter := layers.get_or(s.world.store, s.ids.litter, lvl(s), h, 0)
		stock := (c.value + dead + litter) * CARBON_FRACTION
		previous := layers.get_or(s.world.store, s.ids.carbon_stock, lvl(s), h, stock)
		layers.set(s.world.store, s.ids.carbon_stock, lvl(s), h, stock)
		layers.set(s.world.store, s.ids.carbon_flux, lvl(s), h, (stock - previous) / years)
		n += 1
	}
	mark_dirty(s, s.ids.carbon_stock)
	set_last_cells(s, "carbon", n)
}

// ---------------------------------------------------------------------------

@(private)
smoothstep :: proc "contextless" (edge0, edge1, x: f64) -> f64 {
	if edge1 == edge0 {
		return x < edge0 ? 0 : 1
	}
	t := clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3.0 - 2.0 * t)
}

@(private)
set_last_cells :: proc(s: ^Sim, name: string, n: int) {
	for &sys in s.systems {
		if sys.name == name {
			sys.last_cells = n
			return
		}
	}
}
