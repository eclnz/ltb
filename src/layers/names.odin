package layers

import "core:strings"

/*
Turning the names in a manifest into the values they denote.

Every lookup here comes in two forms. `*_lookup` returns `ok`, and is what a
reader of a hand-written file should use: a name nobody recognises is a typo,
and a typo reported is a typo fixed. `*_from_name` is the lenient form that
takes the documented default, for the places where an unreadable field genuinely
should not refuse the whole file.

The distinction matters most for element kinds and semantics. A layer declared
`"type": "i15"` that quietly becomes f32 stores four bytes a cell instead of
two, with a different sentinel and a different range; `"semantic": "categorial"`
that quietly becomes a scalar aggregates category codes by arithmetic mean, and
the pyramid fills with averaged class ids that still colour and still inspect.
Neither announces itself.
*/

// One spelling of a value. Several rows may share a value, which is how "min"
// and "minimum" reach the same rule.
Named :: struct($T: typeid) {
	name:  string,
	value: T,
}

// The value a name denotes, case-insensitively and ignoring surrounding space.
lookup_name :: proc(s: string, table: []Named($T)) -> (value: T, ok: bool) {
	lower := strings.to_lower(strings.trim_space(s), context.temp_allocator)
	for entry in table {
		if entry.name == lower {
			return entry.value, true
		}
	}
	return {}, false
}

ELEMENT_KIND_NAMES := [?]Named(Element_Kind) {
	{"u8", .U8},
	{"byte", .U8},
	{"uint8", .U8},
	{"i8", .I8},
	{"int8", .I8},
	{"sbyte", .I8},
	{"u16", .U16},
	{"uint16", .U16},
	{"ushort", .U16},
	{"i16", .I16},
	{"int16", .I16},
	{"short", .I16},
	{"u32", .U32},
	{"uint32", .U32},
	{"uint", .U32},
	{"i32", .I32},
	{"int32", .I32},
	{"int", .I32},
	{"f32", .F32},
	{"float", .F32},
	{"float32", .F32},
	{"f64", .F64},
	{"double", .F64},
	{"float64", .F64},
}

SEMANTIC_NAMES := [?]Named(Semantic) {
	{"scalar", .Scalar},
	{"fraction", .Fraction},
	{"categorical", .Categorical},
	{"category", .Categorical},
	{"class", .Categorical},
	{"composition", .Composition},
	{"mix", .Composition},
	{"vector", .Vector},
	{"density", .Density},
	{"direction", .Direction},
	{"bearing", .Direction},
	{"angle", .Direction},
	{"boolean", .Boolean},
	{"bool", .Boolean},
	{"flag", .Boolean},
	{"color", .Color},
	{"colour", .Color},
	{"rgb", .Color},
}

AGGREGATE_NAMES := [?]Named(Aggregate) {
	{"mean", .Mean},
	{"average", .Mean},
	{"sum", .Sum},
	{"min", .Min},
	{"minimum", .Min},
	{"max", .Max},
	{"maximum", .Max},
	{"majority", .Majority},
	{"mode", .Majority},
	{"composition", .Composition_Mean},
	{"composition_mean", .Composition_Mean},
	{"circular", .Circular_Mean},
	{"circular_mean", .Circular_Mean},
	{"any", .Any},
	{"or", .Any},
	{"none", .None},
}

VALUE_SCALE_NAMES := [?]Named(Value_Scale) {
	{"linear", .Linear},
	{"log", .Log},
	{"sqrt", .Sqrt},
}

INTERPOLATION_NAMES := [?]Named(Interpolation) {
	{"linear", .Linear},
	{"nearest", .Nearest},
}

element_kind_lookup :: proc(s: string) -> (Element_Kind, bool) {
	return lookup_name(s, ELEMENT_KIND_NAMES[:])
}

semantic_lookup :: proc(s: string) -> (Semantic, bool) {
	return lookup_name(s, SEMANTIC_NAMES[:])
}

aggregate_lookup :: proc(s: string) -> (Aggregate, bool) {
	return lookup_name(s, AGGREGATE_NAMES[:])
}

value_scale_lookup :: proc(s: string) -> (Value_Scale, bool) {
	return lookup_name(s, VALUE_SCALE_NAMES[:])
}

interpolation_lookup :: proc(s: string) -> (Interpolation, bool) {
	return lookup_name(s, INTERPOLATION_NAMES[:])
}

element_kind_from_name :: proc(s: string) -> Element_Kind {
	k, _ := element_kind_lookup(s)
	return k
}

semantic_from_name :: proc(s: string) -> Semantic {
	sem, _ := semantic_lookup(s)
	return sem
}

aggregate_from_name :: proc(s: string) -> Aggregate {
	agg, _ := aggregate_lookup(s)
	return agg
}

// ---------------------------------------------------------------------------
// Palettes
// ---------------------------------------------------------------------------

PALETTE_NAMES := [?]Named(Palette) {
	{"viridis", PALETTE_VIRIDIS},
	{"terrain", PALETTE_TERRAIN},
	{"greens", PALETTE_GREENS},
	{"green", PALETTE_GREENS},
	{"blues", PALETTE_BLUES},
	{"blue", PALETTE_BLUES},
	{"heat", PALETTE_HEAT},
	{"hot", PALETTE_HEAT},
	{"diverging", PALETTE_DIVERGING},
	{"anomaly", PALETTE_DIVERGING},
	{"cyclic", PALETTE_CYCLIC},
	{"direction", PALETTE_CYCLIC},
	{"moisture", PALETTE_MOISTURE},
}

palette_lookup :: proc(s: string) -> (Palette, bool) {
	return lookup_name(s, PALETTE_NAMES[:])
}

// The palette a semantic implies, for a layer that names none.
palette_for_semantic :: proc(semantic: Semantic) -> Palette {
	#partial switch semantic {
	case .Categorical:
		return PALETTE_CATEGORICAL
	case .Composition:
		return PALETTE_COMPOSITION
	case .Direction:
		return PALETTE_CYCLIC
	}
	return PALETTE_VIRIDIS
}

palette_by_name :: proc(s: string, semantic: Semantic) -> Palette {
	if p, ok := palette_lookup(s); ok {
		return p
	}
	return palette_for_semantic(semantic)
}
