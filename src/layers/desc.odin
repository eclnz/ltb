/*
Package layers is the data model of the world: an open-ended set of named
raster layers, all sharing one hex coordinate system and one LOD pyramid.

A layer is described by data, not by code. `Layer_Desc` says how values are
stored (element type, component count, linear scale/offset), what they mean
(semantic, unit, categories), how they combine when the pyramid is built
(aggregate rule) and how they are drawn (palette). Adding "canopy height" or
"soil pH" or "deer per square kilometre" is a registry entry, not a new type.
*/
package layers

import "core:math"

// How a single component is stored in a chunk buffer.
Element_Kind :: enum u8 {
	U8,
	I8,
	U16,
	I16,
	U32,
	I32,
	F32,
	F64,
}

element_size :: proc "contextless" (k: Element_Kind) -> int {
	switch k {
	case .U8, .I8:
		return 1
	case .U16, .I16:
		return 2
	case .U32, .I32, .F32:
		return 4
	case .F64:
		return 8
	}
	return 0
}

// What the numbers mean. This drives aggregation defaults, interpolation
// legality and colouring.
Semantic :: enum u8 {
	Scalar,      // a continuous quantity: metres, degrees C, kg
	Fraction,    // 0..1 coverage or probability
	Categorical, // an index into `categories`; never interpolate
	Composition, // `components` fractions summing to 1 (species mix, soil texture)
	Vector,      // `components` signed components (wind, flow)
	Density,     // a per-area quantity; sums when cells merge
	Direction,   // an angle in degrees; averages circularly
	Boolean,     // 0 or 1
	Color,       // 3 components, raw 0..255 RGB; drawn directly, never through a palette
}

// How child cells combine into a parent cell one level up the pyramid.
Aggregate :: enum u8 {
	Mean,
	Sum,
	Min,
	Max,
	Majority,         // most common category, ties broken by lowest value
	Composition_Mean, // per-component mean, renormalised to sum to 1
	Circular_Mean,    // for .Direction
	Any,              // boolean OR
	None,             // do not build coarser levels; caller fills them
}

// How a value is positioned along its palette. Quantities that span orders of
// magnitude -- drainage area, population, land value -- are unreadable on a
// linear ramp.
Value_Scale :: enum u8 {
	Linear,
	Log,  // log10(1 + v) normalised over the range
	Sqrt,
}

// How values are read between cell centres.
Interpolation :: enum u8 {
	Nearest,
	Linear, // barycentric across the three nearest cell centres
}

// A named class for a categorical layer.
Category :: struct {
	value: u32,
	name:  string,
	color: [3]u8,
}

Palette_Kind :: enum u8 {
	Sequential,
	Diverging,
	Cyclic,
	Categorical, // colours come from `Layer_Desc.categories`
	Composition, // colours come from per-component category colours, blended
}

Palette_Stop :: struct {
	t:     f64, // 0..1 across [min_value, max_value]
	color: [3]u8,
}

Palette :: struct {
	kind:  Palette_Kind,
	stops: []Palette_Stop,
}

// The full description of one layer.
//
// Stored values are raw; callers see decoded values, where
// decoded = raw * scale + offset. Keeping an integer store with a scale is how
// a 30 m elevation grid fits in 2 bytes a cell instead of 4.
Layer_Desc :: struct {
	name:        string,
	description: string,
	unit:        string,
	group:       string, // "terrain", "climate", ... purely for UI grouping

	kind:        Element_Kind,
	components:  u8,
	semantic:    Semantic,
	aggregate:   Aggregate,
	interp:      Interpolation,
	display:     Value_Scale,

	scale:       f64,
	offset:      f64,

	has_nodata:  bool,
	nodata_raw:  f64, // sentinel compared against the raw stored value

	min_value:   f64, // decoded, for palette normalisation and validation
	max_value:   f64,

	categories:  []Category,
	palette:     Palette,
}

// Bytes occupied by one cell of this layer.
desc_element_stride :: proc "contextless" (d: ^Layer_Desc) -> int {
	return element_size(d.kind) * int(max(u8(1), d.components))
}

desc_components :: proc "contextless" (d: ^Layer_Desc) -> int {
	return int(max(u8(1), d.components))
}

decode_value :: #force_inline proc "contextless" (d: ^Layer_Desc, raw: f64) -> f64 {
	return raw * d.scale + d.offset
}

encode_value :: #force_inline proc "contextless" (d: ^Layer_Desc, v: f64) -> f64 {
	if d.scale == 0 {
		return v - d.offset
	}
	return (v - d.offset) / d.scale
}

// True when a raw stored value is the layer's "no data here" sentinel.
// A NaN sentinel is compared reflexively, since NaN never equals itself.
is_nodata_raw :: #force_inline proc "contextless" (d: ^Layer_Desc, raw: f64) -> bool {
	if !d.has_nodata {
		return false
	}
	if d.nodata_raw != d.nodata_raw {
		return raw != raw
	}
	return raw == d.nodata_raw
}

// Lowest and highest raw values the layer's element type can hold. Float types
// are unbounded.
raw_range :: proc "contextless" (k: Element_Kind) -> (lo, hi: f64) {
	switch k {
	case .U8:
		return 0, 255
	case .I8:
		return -128, 127
	case .U16:
		return 0, 65535
	case .I16:
		return -32768, 32767
	case .U32:
		return 0, 4294967295
	case .I32:
		return -2147483648, 2147483647
	case .F32, .F64:
		return min(f64), max(f64)
	}
	return 0, 0
}

// Encodes a value to its raw form, clamped to a value the layer can store and
// distinguish from its nodata sentinel.
//
// `saturated` reports that the value did not fit and was pinned to the end of
// the range.
encode_storable :: proc "contextless" (d: ^Layer_Desc, v: f64) -> (raw: f64, saturated: bool) {
	raw = encode_value(d, v)
	if raw != raw {
		return raw, false
	}
	lo, hi := raw_range(d.kind)
	if d.has_nodata {
		if d.nodata_raw == hi {
			hi -= 1
		} else if d.nodata_raw == lo {
			lo += 1
		}
	}
	if raw < lo {
		return lo, true
	}
	if raw > hi {
		return hi, true
	}
	return raw, false
}

// Where a value sits along its palette, in 0..1, honouring the display scale.
palette_position :: proc "contextless" (d: ^Layer_Desc, value, lo, hi: f64) -> f64 {
	if hi <= lo {
		return 0
	}
	switch d.display {
	case .Log:
		// Shifted so a zero value maps to zero rather than negative infinity.
		base := math.max(0.0, -lo)
		num := math.ln(1.0 + math.max(0.0, value + base))
		den := math.ln(1.0 + math.max(1e-9, hi + base))
		return clamp(num / den, 0, 1)
	case .Sqrt:
		return clamp(math.sqrt(clamp((value - lo) / (hi - lo), 0, 1)), 0, 1)
	case .Linear:
	}
	return clamp((value - lo) / (hi - lo), 0, 1)
}

// A sensible aggregate rule when a descriptor does not name one.
default_aggregate :: proc "contextless" (s: Semantic) -> Aggregate {
	switch s {
	case .Categorical:
		return .Majority
	case .Composition:
		return .Composition_Mean
	case .Density:
		return .Sum
	case .Direction:
		return .Circular_Mean
	case .Boolean:
		return .Any
	case .Scalar, .Fraction, .Vector, .Color:
		return .Mean
	}
	return .Mean
}

// Fills in the derived defaults a hand-written descriptor is allowed to omit.
desc_normalize :: proc(d: ^Layer_Desc) {
	if d.components == 0 {
		d.components = 1
	}
	if d.scale == 0 {
		d.scale = 1
	}
	if d.aggregate == .Mean && d.semantic != .Scalar && d.semantic != .Fraction && d.semantic != .Vector {
		d.aggregate = default_aggregate(d.semantic)
	}
	if d.semantic == .Categorical || d.semantic == .Boolean {
		d.interp = .Nearest
	}
	if d.min_value == 0 && d.max_value == 0 {
		d.max_value = 1
	}
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

Layer_Id :: distinct u16

INVALID_LAYER :: Layer_Id(0xFFFF)

// The set of layers a world knows about. Ids are indices, so they are stable
// for the lifetime of the registry and cheap to store in chunk keys.
Registry :: struct {
	descs:  [dynamic]Layer_Desc,
	by_name: map[string]Layer_Id,
}

registry_init :: proc(r: ^Registry, allocator := context.allocator) {
	r.descs = make([dynamic]Layer_Desc, allocator)
	r.by_name = make(map[string]Layer_Id, 64, allocator)
}

registry_destroy :: proc(r: ^Registry) {
	delete(r.descs)
	delete(r.by_name)
}

// Registers a layer. Re-registering a name returns the existing id and leaves
// the original descriptor in place.
register :: proc(r: ^Registry, desc: Layer_Desc) -> (id: Layer_Id, fresh: bool) {
	if existing, found := r.by_name[desc.name]; found {
		return existing, false
	}
	d := desc
	desc_normalize(&d)
	id = Layer_Id(len(r.descs))
	append(&r.descs, d)
	r.by_name[d.name] = id
	return id, true
}

lookup :: proc(r: ^Registry, name: string) -> (id: Layer_Id, ok: bool) {
	id, ok = r.by_name[name]
	return
}

desc_of :: proc(r: ^Registry, id: Layer_Id) -> ^Layer_Desc {
	if int(id) >= len(r.descs) {
		return nil
	}
	return &r.descs[int(id)]
}

layer_count :: proc(r: ^Registry) -> int {
	return len(r.descs)
}
