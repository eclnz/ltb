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
	key:       Chunk_Key,
	data:      []byte,
	stride:    int, // bytes per cell
	last_used: u64,
	dirty:     bool,
}

// Sparse chunk store. Only chunks that have been written exist; everything else
// reads as "no data", so a world can be far larger than the data covering it.
Store :: struct {
	registry:       ^Registry,
	chunks:         map[Chunk_Key]^Chunk,
	allocator:      mem.Allocator,
	tick:           u64,
	bytes_resident: int,
	// Soft cap on resident chunk bytes. Zero means unbounded. Chunks are only
	// evicted by an explicit `store_trim` call, never underneath a caller.
	budget_bytes:   int,
	// Called before a dirty chunk is dropped, so generated or edited data can
	// be persisted instead of lost.
	on_evict:       proc(store: ^Store, chunk: ^Chunk),
	user_data:      rawptr,
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
write_element :: proc "contextless" (kind: Element_Kind, p: rawptr, v: f64) {
	switch kind {
	case .U8:
		intrinsics.unaligned_store((^u8)(p), u8(clamp(v, 0, 255)))
	case .I8:
		intrinsics.unaligned_store((^i8)(p), i8(clamp(v, -128, 127)))
	case .U16:
		intrinsics.unaligned_store((^u16)(p), u16(clamp(v, 0, 65535)))
	case .I16:
		intrinsics.unaligned_store((^i16)(p), i16(clamp(v, -32768, 32767)))
	case .U32:
		intrinsics.unaligned_store((^u32)(p), u32(clamp(v, 0, 4294967295)))
	case .I32:
		intrinsics.unaligned_store((^i32)(p), i32(clamp(v, -2147483648, 2147483647)))
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
	if !ok {
		return nil
	}
	c.last_used = s.tick
	return c
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
	c.last_used = s.tick
	if d.has_nodata && d.nodata_raw != 0 {
		fill_chunk_raw(d, c, d.nodata_raw)
	}
	s.chunks[key] = c
	s.bytes_resident += len(c.data)
	return c
}

// Writes `raw` into every component of every cell of the chunk.
fill_chunk_raw :: proc(d: ^Layer_Desc, c: ^Chunk, raw: f64) {
	nc := desc_components(d)
	esz := element_size(d.kind)
	for i in 0 ..< CHUNK_AREA * nc {
		write_element(d.kind, rawptr(uintptr(raw_data(c.data)) + uintptr(i * esz)), raw)
	}
}

// Drops least-recently-used chunks until the store is inside its byte budget.
// Dirty chunks are handed to `on_evict` first; without a handler they are kept,
// because dropping generated data silently is worse than exceeding the budget.
store_trim :: proc(s: ^Store) -> (evicted: int) {
	if s.budget_bytes <= 0 || s.bytes_resident <= s.budget_bytes {
		return 0
	}
	candidates := make([dynamic]^Chunk, 0, len(s.chunks), context.temp_allocator)
	defer delete(candidates)
	for _, c in s.chunks {
		append(&candidates, c)
	}
	slice.sort_by(candidates[:], proc(a, b: ^Chunk) -> bool {
		return a.last_used < b.last_used
	})
	for c in candidates {
		if s.bytes_resident <= s.budget_bytes {
			break
		}
		if c.dirty {
			if s.on_evict == nil {
				continue
			}
			s.on_evict(s, c)
			c.dirty = false
		}
		s.bytes_resident -= len(c.data)
		delete_key(&s.chunks, c.key)
		delete(c.data, s.allocator)
		free(c, s.allocator)
		evicted += 1
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
	write_element(d.kind, rawptr(uintptr(raw_data(c.data)) + uintptr(idx * c.stride)), encode_value(d, value))
	c.dirty = true
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
		write_element(d.kind, rawptr(base + uintptr(i * esz)), encode_value(d, values[i]))
	}
	c.dirty = true
	return true
}

// Marks a cell as having no data. Only meaningful for layers with a sentinel.
clear_cell :: proc(s: ^Store, layer: Layer_Id, level: u8, h: hex.Hex) -> bool {
	d := desc_of(s.registry, layer)
	if d == nil || !d.has_nodata {
		return false
	}
	cx, cy, idx := chunk_of(h)
	c := find_chunk(s, Chunk_Key{layer, level, cx, cy})
	if c == nil {
		return true // already absent
	}
	esz := element_size(d.kind)
	base := uintptr(raw_data(c.data)) + uintptr(idx * c.stride)
	for i in 0 ..< desc_components(d) {
		write_element(d.kind, rawptr(base + uintptr(i * esz)), d.nodata_raw)
	}
	c.dirty = true
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

view_set :: #force_inline proc "contextless" (v: Chunk_View, index: int, value: f64) {
	write_element(
		v.desc.kind,
		rawptr(uintptr(raw_data(v.chunk.data)) + uintptr(index * v.chunk.stride)),
		encode_value(v.desc, value),
	)
	v.chunk.dirty = true
}

// Reinterprets a chunk's storage as a typed slice. Only valid when the layer's
// element kind matches T; returns nil otherwise.
typed :: proc(v: Chunk_View, $T: typeid) -> []T {
	expect: Element_Kind
	when T == u8 {expect = .U8} else when T == i8 {expect = .I8} else when T == u16 {expect = .U16} else when T == i16 {expect = .I16} else when T == u32 {expect = .U32} else when T == i32 {expect = .I32} else when T == f32 {expect = .F32} else when T == f64 {expect = .F64} else {
		#panic("layers.typed: unsupported element type")
	}
	if v.desc.kind != expect {
		return nil
	}
	return slice.reinterpret([]T, v.chunk.data)
}

// ---------------------------------------------------------------------------
// Enumeration
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

// Drops every chunk of one layer at one level without consulting `on_evict`.
// Used when a pyramid level is about to be rebuilt from scratch.
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

// Visits every cell of one layer at one level that holds data.
//
// Iterating the resident chunks is the only sane way to sweep a sparse world:
// it touches the cells that exist, in memory order, instead of walking an index
// space that is mostly empty.
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

// Collects the cells of one layer at one level into a caller-owned slice.
// Useful where a system needs to write while it reads, which iterating the
// chunks directly would not allow.
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
			value, ok := view_get(v, idx)
			if !ok {
				continue
			}
			append(&out, Cell{hex_of_index(c.key.cx, c.key.cy, idx), value})
		}
	}
	return out[:]
}

// True when a cell holds data, without decoding it.
get_or_ok :: proc(s: ^Store, layer: Layer_Id, level: u8, h: hex.Hex) -> bool {
	_, ok := get(s, layer, level, h)
	return ok
}
