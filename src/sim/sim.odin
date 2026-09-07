/*
Package sim is the tick machinery, not a game.

It owns a calendar, a list of systems and their cadences, and the bookkeeping
that keeps the LOD pyramid in step with whatever the systems write. It knows
nothing about forests, roads or people: a system carries its own layer bindings
and its own state, so adding a domain means adding a file, and the scheduler
never grows a field for it.

A system is three procs and a cadence:

	setup   resolve layer ids, allocate state, refuse to run if a layer is absent
	update  advance the world by the elapsed days it is handed
	teardown  release whatever setup allocated

`example_systems.odin` has two small ones to copy from.
*/
package sim

import "core:math"
import "core:math/rand"
import "ltb:layers"
import "ltb:world"

// Simulation calendar. One tick is `days_per_tick` days; systems declare their
// own cadence in days and run when enough time has accumulated.
Clock :: struct {
	tick:          u64,
	day:           f64, // days since the epoch
	days_per_tick: f64,
}

EPOCH_YEAR :: 2025
DAYS_PER_YEAR :: 365.2425

clock_year :: proc(c: Clock, epoch_year := EPOCH_YEAR) -> int {
	return epoch_year + int(c.day / DAYS_PER_YEAR)
}

// Day of year in [0, 365).
clock_day_of_year :: proc(c: Clock) -> f64 {
	return math.mod(c.day, DAYS_PER_YEAR)
}

// Position in the annual cycle, 0 at the start of the year and 1 at the end.
clock_year_phase :: proc(c: Clock) -> f64 {
	return clock_day_of_year(c) / DAYS_PER_YEAR
}

System_Setup :: proc(s: ^Sim, sys: ^System) -> bool
System_Update :: proc(s: ^Sim, sys: ^System, elapsed_days: f64)
System_Teardown :: proc(s: ^Sim, sys: ^System)

System :: struct {
	name:          string,
	description:   string,
	// Simulated days between runs. Zero runs the system every tick.
	interval_days: f64,
	enabled:       bool,

	setup:         System_Setup,
	update:        System_Update,
	teardown:      System_Teardown,
	// Whatever `setup` allocated. The scheduler never looks inside it.
	state:         rawptr,

	// Scheduler bookkeeping.
	accrued:       f64,
	runs:          u64,
	// Diagnostics for the HUD and the headless report; a system sets these.
	cells_touched: int,
	note:          string,
}

Sim :: struct {
	world:         ^world.World,
	clock:         Clock,
	systems:       [dynamic]System,
	// Pyramid level the systems operate on. Coarser levels are derived.
	level:         int,
	rng:           rand.Generator,
	rng_state:     rand.Default_Random_State,
	// Rebuild coarse levels for dirtied layers every N ticks. Coarse levels
	// only feed display and broad-phase queries, so they can lag behind.
	pyramid_every: u64,
	dirty:         map[layers.Layer_Id]bool,
	started:       bool,
}

init :: proc(s: ^Sim, w: ^world.World, level := 0, seed: u64 = 1, allocator := context.allocator) {
	s.world = w
	s.level = level
	s.clock = Clock {
		days_per_tick = 1.0,
	}
	s.systems = make([dynamic]System, allocator)
	s.dirty = make(map[layers.Layer_Id]bool, 32, allocator)
	s.pyramid_every = 64
	s.rng_state = rand.create(seed)
	s.rng = rand.default_random_generator(&s.rng_state)
}

destroy :: proc(s: ^Sim) {
	for &sys in s.systems {
		if sys.teardown != nil {
			sys.teardown(s, &sys)
		}
	}
	delete(s.systems)
	delete(s.dirty)
	s^ = {}
}

// Registers a system. It is not usable until `start` has run its setup.
add_system :: proc(s: ^Sim, sys: System) {
	sy := sys
	if sy.enabled == false && sy.setup == nil && sy.update == nil {
		return
	}
	append(&s.systems, sy)
}

// Convenience for the common case of a system with no setup or state.
add_simple_system :: proc(s: ^Sim, name: string, interval_days: f64, update: System_Update) {
	add_system(s, System{name = name, interval_days = interval_days, enabled = true, update = update})
}

// Runs every system's setup. A system whose setup fails -- usually because a
// layer it needs is not registered -- is disabled rather than fatal, so a world
// missing one dataset still runs everything else.
//
// Returns the number of systems that came up.
start :: proc(s: ^Sim) -> (ready: int) {
	for &sys in s.systems {
		if sys.setup != nil {
			if !sys.setup(s, &sys) {
				sys.enabled = false
				continue
			}
		}
		if sys.update != nil {
			sys.enabled = true
			ready += 1
		}
	}
	s.started = true
	return
}

find_system :: proc(s: ^Sim, name: string) -> ^System {
	for &sys in s.systems {
		if sys.name == name {
			return &sys
		}
	}
	return nil
}

// Marks a layer as changed, so its coarse levels get rebuilt at the next flush.
mark_dirty :: proc(s: ^Sim, id: layers.Layer_Id) {
	s.dirty[id] = true
}

// Advances the clock one tick and runs whichever systems are due.
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
		sys.update(s, &sys, elapsed)
		sys.runs += 1
	}

	if s.pyramid_every > 0 && s.clock.tick % s.pyramid_every == 0 {
		flush_pyramid(s)
	}
}

run :: proc(s: ^Sim, ticks: int) {
	for _ in 0 ..< ticks {
		step(s)
	}
}

// Rebuilds coarse levels for every layer a system has written since the last
// flush.
flush_pyramid :: proc(s: ^Sim) -> (rebuilt: int) {
	if len(s.dirty) == 0 {
		return 0
	}
	for id in s.dirty {
		world.build_pyramid(s.world, id, s.level)
		rebuilt += 1
	}
	clear(&s.dirty)
	return
}

// ---------------------------------------------------------------------------
// Helpers for writing systems
// ---------------------------------------------------------------------------

// The store level the systems run on, as the u8 the layer API wants.
level_of :: #force_inline proc "contextless" (s: ^Sim) -> u8 {
	return u8(s.level)
}

// Resolves a set of layer names in one go. Returns false and names the first
// missing layer, which is what a system's setup should report.
resolve_layers :: proc(s: ^Sim, names: []string, out: []layers.Layer_Id) -> (missing: string, ok: bool) {
	if len(out) < len(names) {
		return "", false
	}
	for name, i in names {
		id, found := layers.lookup(s.world.registry, name)
		if !found {
			return name, false
		}
		out[i] = id
	}
	return "", true
}
