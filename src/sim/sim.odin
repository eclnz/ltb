/*
Package sim runs the world forward.

Systems are the unit of simulation: each one reads some layers, writes others,
and declares how often it wants to run. They share no state beyond the layer
store, so adding a system is adding a file, and a system can be disabled at
runtime without disturbing the rest.

Every system here works cell-wise over the layers that already exist, sweeping
resident chunks rather than an index space, so a world costs what its data
costs.
*/
package sim

import "core:math"
import "core:math/rand"
import hex "ltb:hex"
import "ltb:layers"
import "ltb:world"

// Simulation calendar. One tick is `days_per_tick` days; systems declare their
// own cadence in days and are run when enough time has accumulated.
Clock :: struct {
	tick:          u64,
	day:           f64, // days since epoch
	days_per_tick: f64,
}

clock_year :: proc(c: Clock, epoch_year := 2025) -> int {
	return epoch_year + int(c.day / 365.2425)
}

// Day of year in [0, 365).
clock_day_of_year :: proc(c: Clock) -> f64 {
	return math.mod(c.day, 365.2425)
}

System_Proc :: proc(s: ^Sim, elapsed_days: f64)

System :: struct {
	name:          string,
	// How many simulated days between runs. Zero runs it every tick.
	interval_days: f64,
	enabled:       bool,
	update:        System_Proc,
	// Days accumulated since this system last ran.
	accrued:       f64,
	// Diagnostics, so the UI can show what the simulation is actually doing.
	last_cells:    int,
	runs:          u64,
}

// Layer ids the built-in systems use, resolved once at startup.
Sim_Layers :: struct {
	elevation, slope, aspect:                       layers.Layer_Id,
	temp_mean, precip, humidity, gdd:               layers.Layer_Id,
	wind_speed, wind_direction:                     layers.Layer_Id,
	soil_moisture, soil_depth:                      layers.Layer_Id,
	forest_density, canopy_height, biomass:         layers.Layer_Id,
	stand_age, health, regeneration, site_index:    layers.Layer_Id,
	deadwood, litter:                               layers.Layer_Id,
	fuel_moisture, fire_state, fire_intensity:      layers.Layer_Id,
	years_since_burn:                               layers.Layer_Id,
	carbon_stock, carbon_flux:                      layers.Layer_Id,
	landcover, water_permanent:                     layers.Layer_Id,
}

Sim :: struct {
	world:        ^world.World,
	clock:        Clock,
	systems:      [dynamic]System,
	ids:          Sim_Layers,
	level:        int, // level the systems operate on
	rng:          rand.Generator,
	rng_state:    rand.Default_Random_State,
	// Rebuild the pyramid for layers the systems write, every N ticks. Coarse
	// levels only feed display and broad-phase queries, so they can lag.
	pyramid_every: u64,
	dirty_layers: map[layers.Layer_Id]bool,
}

init :: proc(s: ^Sim, w: ^world.World, level := 0, seed: u64 = 1, allocator := context.allocator) -> bool {
	s.world = w
	s.level = level
	s.clock = Clock {
		days_per_tick = 1.0,
	}
	s.systems = make([dynamic]System, allocator)
	s.dirty_layers = make(map[layers.Layer_Id]bool, 32, allocator)
	s.pyramid_every = 64
	s.rng_state = rand.create(seed)
	s.rng = rand.default_random_generator(&s.rng_state)
	return resolve(s)
}

destroy :: proc(s: ^Sim) {
	delete(s.systems)
	delete(s.dirty_layers)
}

@(private)
resolve :: proc(s: ^Sim) -> bool {
	ok := true
	get :: proc(r: ^layers.Registry, name: string, ok: ^bool) -> layers.Layer_Id {
		id, found := layers.lookup(r, name)
		if !found {
			ok^ = false
		}
		return id
	}
	r := s.world.registry
	s.ids.elevation = get(r, "terrain.elevation", &ok)
	s.ids.slope = get(r, "terrain.slope", &ok)
	s.ids.aspect = get(r, "terrain.aspect", &ok)
	s.ids.temp_mean = get(r, "climate.temp_mean_annual", &ok)
	s.ids.precip = get(r, "climate.precip_annual", &ok)
	s.ids.humidity = get(r, "climate.humidity", &ok)
	s.ids.gdd = get(r, "climate.growing_degree_days", &ok)
	s.ids.wind_speed = get(r, "climate.wind_speed", &ok)
	s.ids.wind_direction = get(r, "climate.wind_direction", &ok)
	s.ids.soil_moisture = get(r, "soil.moisture", &ok)
	s.ids.soil_depth = get(r, "soil.depth", &ok)
	s.ids.forest_density = get(r, "forest.density", &ok)
	s.ids.canopy_height = get(r, "forest.canopy_height", &ok)
	s.ids.biomass = get(r, "forest.biomass_above_ground", &ok)
	s.ids.stand_age = get(r, "forest.stand_age", &ok)
	s.ids.health = get(r, "forest.health", &ok)
	s.ids.regeneration = get(r, "forest.regeneration", &ok)
	s.ids.site_index = get(r, "forest.site_index", &ok)
	s.ids.deadwood = get(r, "forest.deadwood_load", &ok)
	s.ids.litter = get(r, "forest.litter_load", &ok)
	s.ids.fuel_moisture = get(r, "fire.fuel_moisture", &ok)
	s.ids.fire_state = get(r, "fire.state", &ok)
	s.ids.fire_intensity = get(r, "fire.intensity", &ok)
	s.ids.years_since_burn = get(r, "fire.years_since_burn", &ok)
	s.ids.carbon_stock = get(r, "sim.carbon_stock", &ok)
	s.ids.carbon_flux = get(r, "sim.carbon_flux", &ok)
	s.ids.landcover = get(r, "land.cover", &ok)
	s.ids.water_permanent = get(r, "water.permanent", &ok)
	return ok
}

add_system :: proc(s: ^Sim, name: string, interval_days: f64, update: System_Proc, enabled := true) {
	append(&s.systems, System{name = name, interval_days = interval_days, enabled = enabled, update = update})
}

// Registers the built-in systems in the order they should run: the physical
// environment first, then vegetation, then disturbance.
add_default_systems :: proc(s: ^Sim) {
	add_system(s, "moisture", 7, system_moisture)
	add_system(s, "forest growth", 30, system_forest_growth)
	add_system(s, "fuel", 30, system_fuel)
	add_system(s, "fire", 1, system_fire)
	add_system(s, "carbon", 365, system_carbon)
}

// Marks a layer as changed, so its coarse levels get rebuilt.
mark_dirty :: proc(s: ^Sim, id: layers.Layer_Id) {
	s.dirty_layers[id] = true
}

// Advances the clock by one tick and runs whichever systems are due.
step :: proc(s: ^Sim) {
	dt := s.clock.days_per_tick
	s.clock.tick += 1
	s.clock.day += dt

	for &sys in s.systems {
		if !sys.enabled || sys.update == nil {
			continue
		}
		sys.accrued += dt
		if sys.interval_days > 0 && sys.accrued < sys.interval_days {
			continue
		}
		elapsed := sys.accrued
		sys.accrued = 0
		sys.update(s, elapsed)
		sys.runs += 1
	}

	if s.pyramid_every > 0 && s.clock.tick % s.pyramid_every == 0 {
		flush_pyramid(s)
	}
}

// Rebuilds coarse levels for every layer a system has written since the last
// flush.
flush_pyramid :: proc(s: ^Sim) -> (rebuilt: int) {
	if len(s.dirty_layers) == 0 {
		return 0
	}
	for id in s.dirty_layers {
		world.build_pyramid(s.world, id, s.level)
		rebuilt += 1
	}
	clear(&s.dirty_layers)
	return
}

// Runs `n` ticks.
run :: proc(s: ^Sim, n: int) {
	for _ in 0 ..< n {
		step(s)
	}
}
