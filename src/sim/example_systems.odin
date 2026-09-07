package sim

import "core:math"
import "ltb:layers"

/*
Example systems, kept as templates for the pattern: bind layers in `setup`,
write cells in `update`, mark what you wrote dirty.

Neither is a model of anything in particular. Domain systems replace them.
*/

// ---------------------------------------------------------------------------
// Soil moisture
// ---------------------------------------------------------------------------

@(private)
Moisture_State :: struct {
	soil_moisture: layers.Layer_Id,
	precip:        layers.Layer_Id,
	temp:          layers.Layer_Id,
	slope:         layers.Layer_Id,
}

// Relaxes soil moisture towards the value the climate implies.
//
// A first-order bucket: the gap to equilibrium closes exponentially with a time
// constant of a few weeks, so the landscape carries a memory of recent weather.
moisture_system :: proc() -> System {
	return System {
		name = "moisture",
		description = "relaxes soil moisture towards its climatic equilibrium",
		interval_days = 7,
		setup = proc(s: ^Sim, sys: ^System) -> bool {
			ids: [4]layers.Layer_Id
			missing, ok := resolve_layers(
				s,
				{"soil.moisture", "climate.precip_annual", "climate.temp_mean_annual", "terrain.slope"},
				ids[:],
			)
			if !ok {
				sys.note = missing
				return false
			}
			st := new(Moisture_State)
			st.soil_moisture, st.precip, st.temp, st.slope = ids[0], ids[1], ids[2], ids[3]
			sys.state = st
			return true
		},
		teardown = proc(s: ^Sim, sys: ^System) {
			if sys.state != nil {
				free((^Moisture_State)(sys.state))
				sys.state = nil
			}
		},
		update = proc(s: ^Sim, sys: ^System, elapsed_days: f64) {
			st := (^Moisture_State)(sys.state)
			store := s.world.store
			level := level_of(s)

			TAU_DAYS :: 45.0
			k := 1.0 - math.exp(-elapsed_days / TAU_DAYS)
			// A crude annual cycle, so summers dry out.
			season := 1.0 + 0.28 * math.sin(clock_year_phase(s.clock) * 2.0 * math.PI)

			cells := layers.collect_cells(store, st.soil_moisture, level, context.temp_allocator)
			defer delete(cells, context.temp_allocator)

			for c in cells {
				precip := layers.get_or(store, st.precip, level, c.hex, 800)
				temp := layers.get_or(store, st.temp, level, c.hex, 10)
				slope := layers.get_or(store, st.slope, level, c.hex, 0)

				target := clamp(
					precip / 2400.0 * season - math.max(0.0, temp - 12.0) * 0.018 - slope * 0.005,
					0.02,
					1.0,
				)
				layers.set(store, st.soil_moisture, level, c.hex, c.value + (target - c.value) * k)
			}
			sys.cells_touched = len(cells)
			mark_dirty(s, st.soil_moisture)
		},
	}
}

// ---------------------------------------------------------------------------
// Forest cover
// ---------------------------------------------------------------------------

@(private)
Growth_State :: struct {
	density:  layers.Layer_Id,
	gdd:      layers.Layer_Id,
	moisture: layers.Layer_Id,
	depth:    layers.Layer_Id,
	slope:    layers.Layer_Id,
	age:      layers.Layer_Id,
}

// Grows canopy cover logistically towards what the site can support.
//
// Carrying capacity comes from warmth, water, rooting depth and steepness;
// cover then approaches it at about 11% a year, closing a canopy in roughly
// four decades on a productive site.
forest_growth_system :: proc() -> System {
	return System {
		name = "forest growth",
		description = "logistic canopy growth towards the site's carrying capacity",
		interval_days = 30,
		setup = proc(s: ^Sim, sys: ^System) -> bool {
			ids: [6]layers.Layer_Id
			missing, ok := resolve_layers(
				s,
				{
					"forest.density",
					"climate.growing_degree_days",
					"soil.moisture",
					"soil.depth",
					"terrain.slope",
					"forest.stand_age",
				},
				ids[:],
			)
			if !ok {
				sys.note = missing
				return false
			}
			st := new(Growth_State)
			st.density, st.gdd, st.moisture, st.depth, st.slope, st.age =
				ids[0], ids[1], ids[2], ids[3], ids[4], ids[5]
			sys.state = st
			return true
		},
		teardown = proc(s: ^Sim, sys: ^System) {
			if sys.state != nil {
				free((^Growth_State)(sys.state))
				sys.state = nil
			}
		},
		update = proc(s: ^Sim, sys: ^System, elapsed_days: f64) {
			st := (^Growth_State)(sys.state)
			store := s.world.store
			level := level_of(s)
			years := elapsed_days / DAYS_PER_YEAR
			if years <= 0 {
				return
			}
			RATE :: 0.11 // per year

			cells := layers.collect_cells(store, st.density, level, context.temp_allocator)
			defer delete(cells, context.temp_allocator)

			for c in cells {
				gdd := layers.get_or(store, st.gdd, level, c.hex, 2000)
				moisture := layers.get_or(store, st.moisture, level, c.hex, 0.4)
				depth := layers.get_or(store, st.depth, level, c.hex, 1.0)
				slope := layers.get_or(store, st.slope, level, c.hex, 0)

				capacity := clamp(
					smoothstep(400, 3000, gdd) *
					smoothstep(0.08, 0.45, moisture) *
					smoothstep(0.10, 0.80, depth) *
					(1.0 - smoothstep(35.0, 58.0, slope)),
					0.0,
					1.0,
				)

				density := c.value
				if capacity < 0.02 {
					density = math.max(0.0, density - 0.05 * years)
				} else {
					if density < 0.004 {
						density = 0.004 * capacity // seed an empty site
					}
					density = clamp(density + RATE * density * (1.0 - density / capacity) * years, 0, capacity)
				}
				layers.set(store, st.density, level, c.hex, density)
				layers.set(store, st.age, level, c.hex, layers.get_or(store, st.age, level, c.hex, 0) + years)
			}
			sys.cells_touched = len(cells)
			mark_dirty(s, st.density)
			mark_dirty(s, st.age)
		},
	}
}

// Registers the example systems. A real game would not call this.
add_example_systems :: proc(s: ^Sim) {
	add_system(s, moisture_system())
	add_system(s, forest_growth_system())
}

@(private)
smoothstep :: proc "contextless" (edge0, edge1, x: f64) -> f64 {
	if edge1 == edge0 {
		return x < edge0 ? 0 : 1
	}
	t := clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3.0 - 2.0 * t)
}
