package layers

import hex "ltb:hex"

/*
Reading a whole layer.

Every query here is the same two nested walks -- the chunks of one layer and
level, then the cells inside them -- and they differ only in what they keep per
cell. The important distinction is between the ones that fold as they go and
the one that materialises: on a million-cell imagery layer, folding costs three
f64s and materialising costs a hundred and eighty megabytes. Reach for
`value_stats` unless you actually need the cells.
*/

// Every resident chunk of one layer at one level. The returned slice is owned
// by the caller; iterating the store's map directly is fine too, but callers
// that mutate the store while iterating need this snapshot.
collect_chunks :: proc(s: ^Store, layer: Layer_Id, level: u8, allocator := context.allocator) -> []^Chunk {
	out := make([dynamic]^Chunk, 0, 64, allocator)
	for key, c in s.chunks {
		if key.layer == layer && key.level == level {
			append(&out, c)
		}
	}
	return out[:]
}

// Number of resident chunks of one layer at one level.
count_chunks :: proc(s: ^Store, layer: Layer_Id, level: u8) -> (n: int) {
	for key, _ in s.chunks {
		if key.layer == layer && key.level == level {
			n += 1
		}
	}
	return
}

/*
Resident chunks per layer, summed over every level, in one pass.

`out` is indexed by `Layer_Id` and must be at least `layer_count` long. This
exists because the obvious way to write that report -- `count_chunks` per layer
per level -- rescans every chunk in the store a few hundred times to answer a
question one pass can answer.
*/
chunk_counts :: proc(s: ^Store, out: []int) {
	for i in 0 ..< len(out) {
		out[i] = 0
	}
	for key, _ in s.chunks {
		if int(key.layer) < len(out) {
			out[int(key.layer)] += 1
		}
	}
}

// What a layer holds at one level, without materialising it.
Value_Stats :: struct {
	count:  int,
	lo, hi: f64,
	sum:    f64,
}

// Range and mean of one layer at one level. `ok` is false when the layer holds
// no data there.
value_stats :: proc(s: ^Store, layer: Layer_Id, level: u8) -> (stats: Value_Stats, ok: bool) {
	d := desc_of(s.registry, layer)
	if d == nil {
		return {}, false
	}
	chunks := collect_chunks(s, layer, level, context.temp_allocator)
	defer delete(chunks, context.temp_allocator)
	for c in chunks {
		v := Chunk_View{c, d}
		for idx in 0 ..< CHUNK_AREA {
			value, has := view_get(v, idx)
			if !has {
				continue
			}
			if stats.count == 0 {
				stats.lo, stats.hi = value, value
			} else {
				stats.lo = min(stats.lo, value)
				stats.hi = max(stats.hi, value)
			}
			stats.sum += value
			stats.count += 1
		}
	}
	return stats, stats.count > 0
}

value_mean :: proc(stats: Value_Stats) -> f64 {
	return stats.count > 0 ? stats.sum / f64(stats.count) : 0
}

Cell :: struct {
	hex:   hex.Hex,
	value: f64,
}

// Collects the cells of one layer at one level into a caller-owned slice.
//
// Only for callers that need to write the layer while reading it, which
// iterating the chunks would not allow. Anything that just reduces the cells
// wants `value_stats` instead, and none of this memory.
collect_cells :: proc(s: ^Store, layer: Layer_Id, level: u8, allocator := context.allocator) -> []Cell {
	d := desc_of(s.registry, layer)
	if d == nil {
		return nil
	}
	out := make([dynamic]Cell, 0, 4096, allocator)
	chunks := collect_chunks(s, layer, level, context.temp_allocator)
	defer delete(chunks, context.temp_allocator)
	for c in chunks {
		v := Chunk_View{c, d}
		for idx in 0 ..< CHUNK_AREA {
			value, has := view_get(v, idx)
			if !has {
				continue
			}
			append(&out, Cell{hex_of_index(c.key.cx, c.key.cy, idx), value})
		}
	}
	return out[:]
}
