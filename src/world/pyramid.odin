package world

import hex "ltb:hex"
import "ltb:layers"

/*
Pyramid construction: build each coarse level from the level below.

This runs once after ingest, and again for any layer the simulation writes to
during play. It is a single pass over the source level's resident chunks, so
cost is proportional to the data that actually exists, not to the world's index
space.
*/

// Builds level `source_level + 1` of one layer from level `source_level`, and
// returns how many coarse cells were written. Existing data at the destination
// level is discarded first, so a rebuild never mixes stale and fresh values.
build_level :: proc(w: ^World, layer: layers.Layer_Id, source_level: int) -> (written: int) {
	d := layers.desc_of(w.registry, layer)
	if d == nil || d.aggregate == .None {
		return 0
	}
	if source_level < 0 || source_level + 1 >= len(w.levels) {
		return 0
	}
	nc := layers.desc_components(d)
	if nc > layers.MAX_ACCUM_COMPONENTS {
		return 0
	}

	src := u8(source_level)
	dst := u8(source_level + 1)
	layers.drop_level(w.store, layer, dst)

	chunks := layers.collect_chunks(w.store, layer, src, context.temp_allocator)
	defer delete(chunks, context.temp_allocator)
	if len(chunks) == 0 {
		return 0
	}

	// A coarse cell covers four fine ones, so the destination is a quarter the
	// size of the source. Sizing the accumulator up front avoids regrowing it.
	a: layers.Accumulator
	layers.accum_init(&a, d, d.aggregate, context.allocator, len(chunks) * layers.CHUNK_AREA / 4)
	defer layers.accum_destroy(&a)

	values: [layers.MAX_ACCUM_COMPONENTS]f64
	esz := layers.element_size(d.kind)

	for c in chunks {
		v := layers.Chunk_View{c, d}
		for idx in 0 ..< layers.CHUNK_AREA {
			any_data := false
			cell_base := uintptr(idx * c.stride)
			for i in 0 ..< nc {
				val, ok := layers.view_component(v, cell_base, uintptr(i * esz))
				values[i] = val
				any_data ||= ok
			}
			if !any_data {
				continue
			}
			h := layers.hex_of_index(c.key.cx, c.key.cy, idx)
			layers.accum_add(&a, parent(h), values[:nc])
		}
	}

	return layers.accum_flush(&a, w.store, layer, dst)
}

// Builds every level above `from_level` for one layer.
build_pyramid :: proc(w: ^World, layer: layers.Layer_Id, from_level := 0) -> (written: int) {
	for l in from_level ..< len(w.levels) - 1 {
		written += build_level(w, layer, l)
	}
	return
}

// Builds the pyramid for every registered layer that has data.
build_all :: proc(w: ^World, from_level := 0) -> (written: int) {
	for i in 0 ..< layers.layer_count(w.registry) {
		written += build_pyramid(w, layers.Layer_Id(i), from_level)
	}
	return
}

// Reads a layer at `level`, falling back to progressively coarser levels when
// the requested one has no data there. This is what gameplay code should call:
// it always answers if the world knows anything about that ground at all.
sample :: proc(w: ^World, layer: layers.Layer_Id, level: int, h: hex.Hex) -> (value: f64, found_level: int, ok: bool) {
	cell := h
	for l := level; l < len(w.levels); l += 1 {
		if v, got := layers.get(w.store, layer, u8(l), cell); got {
			return v, l, true
		}
		cell = parent(cell)
	}
	return 0, -1, false
}
