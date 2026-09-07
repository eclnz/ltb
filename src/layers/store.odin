package layers

import "core:mem"
import hex "ltb:hex"

/*
The store: chunks of cells, and the reads and writes that reach them.

Only chunks that have been written exist; everything else reads as "no data",
so a world can be far larger than the data covering it. Addressing lives in
`chunk.odin` and whole-layer queries in `query.odin`; what is left here is the
chunk's lifetime and the four access procedures every caller goes through.
*/

Store :: struct {
	registry:       ^Registry,
	chunks:         map[Chunk_Key]^Chunk,
	allocator:      mem.Allocator,
	bytes_resident: int,
	// Writes whose value did not fit the layer's element type and were pinned
	// to the end of its range. Every write goes through `set` or
	// `set_components`, so this counts all of them: an elevation layer quietly
	// clipping at the top of its i16 range shows up here rather than as a
	// mysteriously flat mountain.
	saturated:      int,
}

store_init :: proc(s: ^Store, registry: ^Registry, allocator := context.allocator) {
	s.registry = registry
	s.allocator = allocator
	s.chunks = make(map[Chunk_Key]^Chunk, 256, allocator)
}

store_destroy :: proc(s: ^Store) {
	for _, c in s.chunks {
		delete(c.data, s.allocator)
		free(c, s.allocator)
	}
	delete(s.chunks)
	s.bytes_resident = 0
}

// ---------------------------------------------------------------------------
// Chunk lifetime
// ---------------------------------------------------------------------------

find_chunk :: proc(s: ^Store, key: Chunk_Key) -> ^Chunk {
	c, ok := s.chunks[key]
	return ok ? c : nil
}

// Returns the chunk for `key`, allocating and filling it with the layer's
// nodata sentinel (or zero) if it does not exist yet.
get_or_create_chunk :: proc(s: ^Store, key: Chunk_Key) -> ^Chunk {
	if c := find_chunk(s, key); c != nil {
		return c
	}
	d := desc_of(s.registry, key.layer)
	if d == nil {
		return nil
	}
	stride := desc_element_stride(d)
	c := new(Chunk, s.allocator)
	c.key = key
	c.stride = stride
	c.data = make([]byte, CHUNK_AREA * stride, s.allocator)
	if d.has_nodata && d.nodata_raw != 0 {
		fill_chunk_raw(d, c, d.nodata_raw)
	}
	s.chunks[key] = c
	s.bytes_resident += len(c.data)
	return c
}

// Writes `raw` into every component of every cell of the chunk.
@(private)
fill_chunk_raw :: proc(d: ^Layer_Desc, c: ^Chunk, raw: f64) {
	nc := desc_components(d)
	esz := element_size(d.kind)
	for i in 0 ..< CHUNK_AREA * nc {
		write_element(d.kind, rawptr(uintptr(raw_data(c.data)) + uintptr(i * esz)), raw)
	}
}

// Drops every chunk of one layer at one level. Used when a pyramid level is
// about to be rebuilt from scratch.
drop_level :: proc(s: ^Store, layer: Layer_Id, level: u8) -> (dropped: int) {
	keys := make([dynamic]Chunk_Key, 0, 64, context.temp_allocator)
	defer delete(keys)
	for key, _ in s.chunks {
		if key.layer == layer && key.level == level {
			append(&keys, key)
		}
	}
	for key in keys {
		c := s.chunks[key]
		s.bytes_resident -= len(c.data)
		delete_key(&s.chunks, key)
		delete(c.data, s.allocator)
		free(c, s.allocator)
		dropped += 1
	}
	return
}

// ---------------------------------------------------------------------------
// Value access
// ---------------------------------------------------------------------------

// Reads the decoded value of a single-component layer. `ok` is false when the
// chunk is absent or the cell holds the nodata sentinel.
get :: proc(s: ^Store, layer: Layer_Id, level: u8, h: hex.Hex) -> (value: f64, ok: bool) {
	d := desc_of(s.registry, layer)
	if d == nil {
		return 0, false
	}
	cx, cy, idx := chunk_of(h)
	c := find_chunk(s, Chunk_Key{layer, level, cx, cy})
	if c == nil {
		return 0, false
	}
	raw := read_element(d.kind, rawptr(uintptr(raw_data(c.data)) + uintptr(idx * c.stride)))
	if is_nodata_raw(d, raw) {
		return 0, false
	}
	return decode_value(d, raw), true
}

// Reads the decoded value, substituting `fallback` where there is no data.
get_or :: proc(s: ^Store, layer: Layer_Id, level: u8, h: hex.Hex, fallback: f64) -> f64 {
	v, ok := get(s, layer, level, h)
	return ok ? v : fallback
}

// Reads all components of a multi-component layer into `out`, which must have
// room for `desc_components(desc)` values.
get_components :: proc(s: ^Store, layer: Layer_Id, level: u8, h: hex.Hex, out: []f64) -> bool {
	d := desc_of(s.registry, layer)
	if d == nil {
		return false
	}
	nc := desc_components(d)
	if len(out) < nc {
		return false
	}
	cx, cy, idx := chunk_of(h)
	c := find_chunk(s, Chunk_Key{layer, level, cx, cy})
	if c == nil {
		return false
	}
	esz := element_size(d.kind)
	base := uintptr(raw_data(c.data)) + uintptr(idx * c.stride)
	any_data := false
	for i in 0 ..< nc {
		raw := read_element(d.kind, rawptr(base + uintptr(i * esz)))
		if is_nodata_raw(d, raw) {
			out[i] = 0
		} else {
			out[i] = decode_value(d, raw)
			any_data = true
		}
	}
	return any_data
}

set :: proc(s: ^Store, layer: Layer_Id, level: u8, h: hex.Hex, value: f64) -> bool {
	d := desc_of(s.registry, layer)
	if d == nil {
		return false
	}
	cx, cy, idx := chunk_of(h)
	c := get_or_create_chunk(s, Chunk_Key{layer, level, cx, cy})
	if c == nil {
		return false
	}
	raw, saturated := encode_storable(d, value)
	if saturated {
		s.saturated += 1
	}
	write_element(d.kind, rawptr(uintptr(raw_data(c.data)) + uintptr(idx * c.stride)), raw)
	return true
}

set_components :: proc(s: ^Store, layer: Layer_Id, level: u8, h: hex.Hex, values: []f64) -> bool {
	d := desc_of(s.registry, layer)
	if d == nil {
		return false
	}
	nc := desc_components(d)
	if len(values) < nc {
		return false
	}
	cx, cy, idx := chunk_of(h)
	c := get_or_create_chunk(s, Chunk_Key{layer, level, cx, cy})
	if c == nil {
		return false
	}
	esz := element_size(d.kind)
	base := uintptr(raw_data(c.data)) + uintptr(idx * c.stride)
	for i in 0 ..< nc {
		raw, saturated := encode_storable(d, values[i])
		if saturated {
			s.saturated += 1
		}
		write_element(d.kind, rawptr(base + uintptr(i * esz)), raw)
	}
	return true
}

// ---------------------------------------------------------------------------
// Chunk-local access
// ---------------------------------------------------------------------------

// A chunk plus its descriptor, for tight loops that stay inside one chunk and
// want to skip the map lookup per cell.
Chunk_View :: struct {
	chunk: ^Chunk,
	desc:  ^Layer_Desc,
}

view :: proc(s: ^Store, layer: Layer_Id, level: u8, cx, cy: i32, create := false) -> (v: Chunk_View, ok: bool) {
	d := desc_of(s.registry, layer)
	if d == nil {
		return {}, false
	}
	key := Chunk_Key{layer, level, cx, cy}
	c := create ? get_or_create_chunk(s, key) : find_chunk(s, key)
	if c == nil {
		return {}, false
	}
	return Chunk_View{c, d}, true
}

view_get :: #force_inline proc "contextless" (v: Chunk_View, index: int) -> (f64, bool) {
	raw := read_element(v.desc.kind, rawptr(uintptr(raw_data(v.chunk.data)) + uintptr(index * v.chunk.stride)))
	if is_nodata_raw(v.desc, raw) {
		return 0, false
	}
	return decode_value(v.desc, raw), true
}

// Reads one component at a byte offset within a chunk, for aggregation loops
// that already know the cell's base offset.
view_component :: #force_inline proc "contextless" (v: Chunk_View, cell_base, comp_offset: uintptr) -> (f64, bool) {
	raw := read_element(v.desc.kind, rawptr(uintptr(raw_data(v.chunk.data)) + cell_base + comp_offset))
	if is_nodata_raw(v.desc, raw) {
		return 0, false
	}
	return decode_value(v.desc, raw), true
}
