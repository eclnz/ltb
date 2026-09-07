package layers

import "core:math"
import hex "ltb:hex"

/*
Sparse accumulation of many source values into hex cells.

Visits a stream of (cell, values) pairs in arbitrary order, combines them per the
layer's rule, and writes one value per touched cell. Building a coarse pyramid
level feeds it finer cells; ingesting a raster feeds it source pixels.

Only touched cells are stored, so cost scales with the data rather than with the
world.
*/

MAX_ACCUM_COMPONENTS :: 64

// Counter slots per cell for `.Majority`. This is a Misra-Gries summary: with
// K slots, any value making up more than 1/K of a cell's samples is guaranteed
// to survive to the end, so a true majority is never missed.
ACCUM_CAT_SLOTS :: 16

Cat_Slot :: struct {
	value: f32,
	count: u32,
}

Accumulator :: struct {
	desc:    ^Layer_Desc,
	rule:    Aggregate,
	nc:      int,
	index:   map[hex.Hex]int,
	sums:    [dynamic]f64, // nc per cell; sin-sums under .Circular_Mean
	aux:     [dynamic]f64, // nc per cell; cos-sums under .Circular_Mean
	counts:  [dynamic]i32,
	cats:    [dynamic]Cat_Slot, // ACCUM_CAT_SLOTS per cell
	use_cat: bool,
	use_aux: bool,
}

// `rule` overrides the descriptor's aggregate; pass the descriptor's own rule
// to keep it.
//
// An accumulator over a large region holds tens of megabytes, so `allocator`
// should be one that reclaims on `accum_destroy`. `expect_cells` sizes the
// tables up front.
accum_init :: proc(a: ^Accumulator, d: ^Layer_Desc, rule: Aggregate, allocator := context.allocator, expect_cells := 1024) {
	a.desc = d
	a.rule = rule
	a.nc = min(desc_components(d), MAX_ACCUM_COMPONENTS)
	a.use_cat = rule == .Majority
	a.use_aux = rule == .Circular_Mean
	n := max(expect_cells, 64)
	a.index = make(map[hex.Hex]int, n * 2, allocator)
	a.sums = make([dynamic]f64, 0, n * a.nc, allocator)
	a.counts = make([dynamic]i32, 0, n, allocator)
	if a.use_aux {
		a.aux = make([dynamic]f64, 0, n * a.nc, allocator)
	}
	if a.use_cat {
		a.cats = make([dynamic]Cat_Slot, 0, n * ACCUM_CAT_SLOTS, allocator)
	}
}

accum_destroy :: proc(a: ^Accumulator) {
	delete(a.index)
	delete(a.sums)
	delete(a.counts)
	if a.use_aux {delete(a.aux)}
	if a.use_cat {delete(a.cats)}
	a^ = {}
}

accum_cell_count :: proc(a: ^Accumulator) -> int {
	return len(a.counts)
}

@(private)
accum_slot :: proc(a: ^Accumulator, h: hex.Hex) -> int {
	if i, ok := a.index[h]; ok {
		return i
	}
	i := len(a.counts)
	a.index[h] = i
	append(&a.counts, 0)
	for _ in 0 ..< a.nc {
		append(&a.sums, 0)
	}
	if a.use_aux {
		for _ in 0 ..< a.nc {
			append(&a.aux, 0)
		}
	}
	if a.use_cat {
		for _ in 0 ..< ACCUM_CAT_SLOTS {
			append(&a.cats, Cat_Slot{})
		}
	}
	return i
}

// Adds one sample. `values` must hold at least `a.nc` components.
accum_add :: proc(a: ^Accumulator, h: hex.Hex, values: []f64) {
	slot := accum_slot(a, h)
	base := slot * a.nc
	first := a.counts[slot] == 0

	switch a.rule {
	case .Mean, .Sum, .Composition_Mean:
		for i in 0 ..< a.nc {
			a.sums[base + i] += values[i]
		}
	case .Min:
		for i in 0 ..< a.nc {
			a.sums[base + i] = first ? values[i] : math.min(a.sums[base + i], values[i])
		}
	case .Max:
		for i in 0 ..< a.nc {
			a.sums[base + i] = first ? values[i] : math.max(a.sums[base + i], values[i])
		}
	case .Any:
		for i in 0 ..< a.nc {
			if values[i] != 0 {
				a.sums[base + i] = 1
			}
		}
	case .Circular_Mean:
		for i in 0 ..< a.nc {
			rad := values[i] * math.PI / 180.0
			a.sums[base + i] += math.sin(rad)
			a.aux[base + i] += math.cos(rad)
		}
	case .Majority:
		accum_add_category(a, slot, f32(values[0]))
	case .None:
	// nothing to accumulate; the layer opts out of derived levels
	}
	a.counts[slot] += 1
}

// One step of the Misra-Gries frequent-element summary.
@(private)
accum_add_category :: proc(a: ^Accumulator, slot: int, v: f32) {
	base := slot * ACCUM_CAT_SLOTS
	free_slot := -1
	for k in 0 ..< ACCUM_CAT_SLOTS {
		s := &a.cats[base + k]
		if s.count > 0 && s.value == v {
			s.count += 1
			return
		}
		if s.count == 0 && free_slot < 0 {
			free_slot = k
		}
	}
	if free_slot >= 0 {
		a.cats[base + free_slot] = Cat_Slot{v, 1}
		return
	}
	// Every slot is taken by a different value: decrement them all. Whichever
	// value truly dominates the cell outlives this.
	for k in 0 ..< ACCUM_CAT_SLOTS {
		a.cats[base + k].count -= 1
	}
}

// Computes the final value(s) for one cell into `out`.
@(private)
accum_finish :: proc(a: ^Accumulator, slot: int, out: []f64) {
	base := slot * a.nc
	n := f64(max(i32(1), a.counts[slot]))
	switch a.rule {
	case .Mean:
		for i in 0 ..< a.nc {out[i] = a.sums[base + i] / n}
	case .Sum, .Min, .Max, .Any:
		for i in 0 ..< a.nc {out[i] = a.sums[base + i]}
	case .Composition_Mean:
		total := 0.0
		for i in 0 ..< a.nc {
			out[i] = a.sums[base + i] / n
			total += out[i]
		}
		if total > 1e-12 {
			for i in 0 ..< a.nc {out[i] /= total}
		}
	case .Circular_Mean:
		for i in 0 ..< a.nc {
			ang := math.atan2(a.sums[base + i], a.aux[base + i]) * 180.0 / math.PI
			if ang < 0 {ang += 360.0}
			out[i] = ang
		}
	case .Majority:
		cbase := slot * ACCUM_CAT_SLOTS
		best := Cat_Slot{}
		for k in 0 ..< ACCUM_CAT_SLOTS {
			s := a.cats[cbase + k]
			if s.count > best.count || (s.count == best.count && s.count > 0 && s.value < best.value) {
				best = s
			}
		}
		out[0] = f64(best.value)
	case .None:
		for i in 0 ..< a.nc {out[i] = 0}
	}
}

// Writes every accumulated cell into the store and returns how many were
// written.
//
// `post` runs on each finished component before it is stored, which is how a
// caller turns accumulated metres into a density, or clamps overlapping
// coverage back into [0, 1], without a second pass over the cells.
accum_flush :: proc(
	a: ^Accumulator,
	s: ^Store,
	layer: Layer_Id,
	level: u8,
	post: proc(value: f64) -> f64 = nil,
) -> (
	written: int,
) {
	out: [MAX_ACCUM_COMPONENTS]f64
	for h, slot in a.index {
		accum_finish(a, slot, out[:a.nc])
		if post != nil {
			for i in 0 ..< a.nc {
				out[i] = post(out[i])
			}
		}
		if a.nc == 1 {
			set(s, layer, level, h, out[0])
		} else {
			set_components(s, layer, level, h, out[:a.nc])
		}
		written += 1
	}
	return
}

// True where `h` received at least one sample.
accum_has :: proc(a: ^Accumulator, h: hex.Hex) -> bool {
	_, ok := a.index[h]
	return ok
}
