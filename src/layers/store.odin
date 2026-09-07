package layers

import "base:intrinsics"
import "core:mem"
import "core:slice"
import hex "ltb:hex"

// Cells per chunk edge, in axial index space. A chunk is a parallelogram in
// world space, which is fine: chunks exist for storage and culling, not for
// geometry.
CHUNK_SIZE :: 64
CHUNK_AREA :: CHUNK_SIZE * CHUNK_SIZE

// Identifies one chunk of one layer at one pyramid level.
Chunk_Key :: struct {
	layer:  Layer_Id,
	level:  u8,
	cx, cy: i32,
}

Chunk :: struct {
	key:    Chunk_Key,
	data:   []byte,
	stride: int, // bytes per cell
}

// Sparse chunk store. Only chunks that have been written exist; everything else
// reads as "no data", so a world can be far larger than the data covering it.
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
// Chunk addressing
// ---------------------------------------------------------------------------

@(private)
floor_div :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) {
		q -= 1
	}
	return q
}

@(private)
floor_mod :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	m := a % b
	if m != 0 && ((m < 0) != (b < 0)) {
		m += b
	}
	return m
}

// The chunk containing `h`, and the cell's index within that chunk.
chunk_of :: #force_inline proc "contextless" (h: hex.Hex) -> (cx, cy: i32, index: int) {
	cx = floor_div(h.q, CHUNK_SIZE)
	cy = floor_div(h.r, CHUNK_SIZE)
	lq := floor_mod(h.q, CHUNK_SIZE)
	lr := floor_mod(h.r, CHUNK_SIZE)
	index = int(lr) * CHUNK_SIZE + int(lq)
	return
}

// Inverse of `chunk_of`.
hex_of_index :: #force_inline proc "contextless" (cx, cy: i32, index: int) -> hex.Hex {
	lq := i32(index % CHUNK_SIZE)
	lr := i32(index / CHUNK_SIZE)
	return hex.Hex{cx * CHUNK_SIZE + lq, cy * CHUNK_SIZE + lr}
}

chunk_bounds :: proc "contextless" (cx, cy: i32) -> hex.Bounds {
	return hex.Bounds {
		q0 = cx * CHUNK_SIZE,
		r0 = cy * CHUNK_SIZE,
		q1 = cx * CHUNK_SIZE + CHUNK_SIZE - 1,
		r1 = cy * CHUNK_SIZE + CHUNK_SIZE - 1,
	}
}

// Chunk index range covering an axial bounds, inclusive.
chunk_range :: proc "contextless" (b: hex.Bounds) -> (cx0, cy0, cx1, cy1: i32) {
	cx0 = floor_div(b.q0, CHUNK_SIZE)
	cy0 = floor_div(b.r0, CHUNK_SIZE)
	cx1 = floor_div(b.q1, CHUNK_SIZE)
	cy1 = floor_div(b.r1, CHUNK_SIZE)
	return
}

// ---------------------------------------------------------------------------
// Raw element access
// ---------------------------------------------------------------------------

// Reads one stored element as a f64. Public because ingest needs to decode
// source rasters that use the same element vocabulary.
read_element :: proc "contextless" (kind: Element_Kind, p: rawptr) -> f64 {
	switch kind {
	case .U8:
		return f64(intrinsics.unaligned_load((^u8)(p)))
	case .I8:
		return f64(intrinsics.unaligned_load((^i8)(p)))
	case .U16:
		return f64(intrinsics.unaligned_load((^u16)(p)))
	case .I16:
		return f64(intrinsics.unaligned_load((^i16)(p)))
	case .U32:
		return f64(intrinsics.unaligned_load((^u32)(p)))
	case .I32:
		return f64(intrinsics.unaligned_load((^i32)(p)))
	case .F32:
		return f64(intrinsics.unaligned_load((^f32)(p)))
	case .F64:
		return intrinsics.unaligned_load((^f64)(p))
	}
	return 0
}

// Writes one element, clamping to the destination type's range.
//
// The bounds come from `ELEMENT_TRAITS`, so this cannot disagree with
// `encode_storable` about what an element type can hold.
write_element :: proc "contextless" (kind: Element_Kind, p: rawptr, v: f64) {
	t := ELEMENT_TRAITS[kind]
	c := clamp(v, t.lo, t.hi)
	switch kind {
	case .U8:
		intrinsics.unaligned_store((^u8)(p), u8(c))
	case .I8:
		intrinsics.unaligned_store((^i8)(p), i8(c))
	case .U16:
		intrinsics.unaligned_store((^u16)(p), u16(c))
	case .I16:
		intrinsics.unaligned_store((^i16)(p), i16(c))
	case .U32:
		intrinsics.unaligned_store((^u32)(p), u32(c))
	case .I32:
		intrinsics.unaligned_store((^i32)(p), i32(c))
	case .F32:
		intrinsics.unaligned_store((^f32)(p), f32(v))
	case .F64:
		intrinsics.unaligned_store((^f64)(p), v)
	}
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

// ---------------------------------------------------------------------------
// Enumeration
//
// Every query below is the same two nested walks -- chunks of one layer and
// level, then the cells inside them -- so they are written once here and the
// callers differ only in what they do per cell.
// ---------------------------------------------------------------------------

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

// Reads one component at a byte offset within a chunk, for aggregation loops
// that already know the cell's base offset.
view_component :: #force_inline proc "contextless" (v: Chunk_View, cell_base, comp_offset: uintptr) -> (f64, bool) {
	raw := read_element(v.desc.kind, rawptr(uintptr(raw_data(v.chunk.data)) + cell_base + comp_offset))
	if is_nodata_raw(v.desc, raw) {
		return 0, false
	}
	return decode_value(v.desc, raw), true
}

// Visits every cell of one layer at one level that holds data, in chunk memory
// order. Cost is proportional to the data present, not to the index space.
for_each_cell :: proc(
	s: ^Store,
	layer: Layer_Id,
	level: u8,
	user: rawptr,
	visit: proc(user: rawptr, h: hex.Hex, value: f64),
) -> (
	visited: int,
) {
	d := desc_of(s.registry, layer)
	if d == nil {
		return 0
	}
	chunks := collect_chunks(s, layer, level, context.temp_allocator)
	defer delete(chunks, context.temp_allocator)
	for c in chunks {
		v := Chunk_View{c, d}
		for idx in 0 ..< CHUNK_AREA {
			value, ok := view_get(v, idx)
			if !ok {
				continue
			}
			visit(user, hex_of_index(c.key.cx, c.key.cy, idx), value)
			visited += 1
		}
	}
	return
}

// What a layer holds at one level, without materialising it.
Value_Stats :: struct {
	count:  int,
	lo, hi: f64,
	sum:    f64,
}

/*
Range and mean of one layer at one level.

Every caller that wanted this used to `collect_cells` and reduce the slice,
which allocates sixteen bytes per cell to compute three numbers -- on a
million-cell imagery layer that is a hundred and eighty megabytes of temporary
to find a minimum. `ok` is false when the layer holds no data at that level.
*/
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

// Collects the cells of one layer at one level into a caller-owned slice.
//
// Only for callers that need to write the layer while reading it, which
// iterating the chunks would not allow. Anything that just reduces the cells
// wants `value_stats` or `for_each_cell` instead, and none of this memory.
Cell :: struct {
	hex:   hex.Hex,
	value: f64,
}

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
