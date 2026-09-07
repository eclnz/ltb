package layers

import "core:encoding/json"
import "core:os"
import "core:strings"

/*
Declaring layers from a file.

A layer can be declared in JSON with the same fields the Odin descriptors use,
so a world can add its own without a rebuild:

	{
	  "layers": [
	    {
	      "name": "logistics.haul_cost",
	      "group": "logistics",
	      "unit": "currency/t",
	      "description": "modelled cost to move a tonne to the nearest mill",
	      "type": "u16", "scale": 0.5,
	      "semantic": "scalar", "aggregate": "mean",
	      "min": 0, "max": 2000,
	      "palette": "heat"
	    },
	    {
	      "name": "forest.species_mix",
	      "type": "u8", "semantic": "composition", "scale": 0.00393700787,
	      "categories": [
	        {"name": "beech",  "color": [ 90, 130,  70]},
	        {"name": "podocarp","color": [ 40, 100,  80]},
	        {"name": "pine",   "color": [110, 160,  90]}
	      ]
	    }
	  ]
	}

A composition layer's component count comes from its category list, so the
second example declares three components.

Names already registered are left alone; a manifest adds layers, it never
redefines one.
*/

Manifest_Error :: enum {
	None,
	File_Not_Found,
	Bad_Json,
	Bad_Layer,
}

// Loads layer declarations from a JSON file. Strings are cloned into
// `allocator`, which must outlive the registry.
load_layer_manifest :: proc(
	r: ^Registry,
	path: string,
	allocator := context.allocator,
) -> (
	added: int,
	err: Manifest_Error,
) {
	src, ferr := os.read_entire_file(path, context.allocator)
	if ferr != nil {
		return 0, .File_Not_Found
	}
	defer delete(src, context.allocator)
	return parse_layer_manifest(r, string(src), allocator)
}

parse_layer_manifest :: proc(
	r: ^Registry,
	text: string,
	allocator := context.allocator,
) -> (
	added: int,
	err: Manifest_Error,
) {
	root, jerr := json.parse_string(text, json.DEFAULT_SPECIFICATION, false, context.allocator)
	if jerr != nil {
		return 0, .Bad_Json
	}
	defer json.destroy_value(root, context.allocator)

	list: json.Array
	switch v in root {
	case json.Array:
		list = v
	case json.Object:
		entry, has := v["layers"]
		if !has {
			return 0, .Bad_Layer
		}
		arr, is_arr := entry.(json.Array)
		if !is_arr {
			return 0, .Bad_Layer
		}
		list = arr
	case json.Null, json.Integer, json.Float, json.Boolean, json.String:
		return 0, .Bad_Layer
	}

	for item in list {
		obj, ok := item.(json.Object)
		if !ok {
			continue
		}
		desc, built := layer_from_json(obj, allocator)
		if !built {
			continue
		}
		if _, fresh := register(r, desc); fresh {
			added += 1
		}
	}
	return added, .None
}

// Builds one descriptor from a JSON object. Unspecified fields take the same
// defaults `desc_normalize` applies to a hand-written descriptor.
layer_from_json :: proc(obj: json.Object, allocator := context.allocator) -> (d: Layer_Desc, ok: bool) {
	name := json_string(obj, "name")
	if len(name) == 0 {
		return {}, false
	}
	d.name = strings.clone(name, allocator)
	d.group = strings.clone(json_string(obj, "group", "custom"), allocator)
	d.unit = strings.clone(json_string(obj, "unit"), allocator)
	d.description = strings.clone(json_string(obj, "description"), allocator)

	d.kind = element_kind_from_name(json_string(obj, "type", "f32"))
	d.semantic = semantic_from_name(json_string(obj, "semantic", "scalar"))
	d.scale = json_number(obj, "scale", 1)
	d.offset = json_number(obj, "offset", 0)
	d.min_value = json_number(obj, "min", 0)
	d.max_value = json_number(obj, "max", 1)
	d.components = u8(clamp(int(json_number(obj, "components", 1)), 1, 255))
	d.interp = json_string(obj, "interpolate", "linear") == "nearest" ? .Nearest : .Linear
	switch json_string(obj, "display", "linear") {
	case "log":
		d.display = .Log
	case "sqrt":
		d.display = .Sqrt
	case:
		d.display = .Linear
	}

	if agg := json_string(obj, "aggregate"); len(agg) > 0 {
		d.aggregate = aggregate_from_name(agg)
	} else {
		d.aggregate = default_aggregate(d.semantic)
	}

	if nd, has := obj["nodata"]; has {
		if v, is_num := json_value_number(nd); is_num {
			d.has_nodata = true
			d.nodata_raw = v
		}
	} else {
		// Give integer layers their top code, and floats NaN, matching the
		// standard catalogue.
		d.has_nodata = true
		switch d.kind {
		case .U8:
			d.nodata_raw = 255
		case .I8:
			d.nodata_raw = -128
		case .U16:
			d.nodata_raw = 65535
		case .I16:
			d.nodata_raw = -32768
		case .U32:
			d.nodata_raw = 4294967295
		case .I32:
			d.nodata_raw = -2147483648
		case .F32, .F64:
			d.nodata_raw = NAN
		}
	}

	if cats, has := obj["categories"]; has {
		if arr, is_arr := cats.(json.Array); is_arr {
			d.categories = categories_from_json(arr, allocator)
			// A composition layer has one component per category, so saying it
			// twice is a chance to disagree with yourself.
			if d.semantic == .Composition {
				d.components = u8(clamp(len(d.categories), 1, 255))
			}
		}
	}

	d.palette = palette_by_name(json_string(obj, "palette"), d.semantic)
	desc_normalize(&d)
	return d, true
}

@(private)
categories_from_json :: proc(arr: json.Array, allocator := context.allocator) -> []Category {
	out := make([dynamic]Category, 0, len(arr), allocator)
	for item, i in arr {
		obj, ok := item.(json.Object)
		if !ok {
			continue
		}
		c := Category {
			value = u32(json_number(obj, "value", f64(i))),
			name  = strings.clone(json_string(obj, "name", "class"), allocator),
			color = {128, 128, 128},
		}
		if col, has := obj["color"]; has {
			if ca, is_arr := col.(json.Array); is_arr && len(ca) >= 3 {
				for k in 0 ..< 3 {
					if v, is_num := json_value_number(ca[k]); is_num {
						c.color[k] = u8(clamp(v, 0, 255))
					}
				}
			}
		}
		append(&out, c)
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Name lookups
// ---------------------------------------------------------------------------

element_kind_from_name :: proc(s: string) -> Element_Kind {
	switch strings.to_lower(s, context.temp_allocator) {
	case "u8", "byte", "uint8":
		return .U8
	case "i8", "int8", "sbyte":
		return .I8
	case "u16", "uint16", "ushort":
		return .U16
	case "i16", "int16", "short":
		return .I16
	case "u32", "uint32", "uint":
		return .U32
	case "i32", "int32", "int":
		return .I32
	case "f64", "double", "float64":
		return .F64
	}
	return .F32
}

semantic_from_name :: proc(s: string) -> Semantic {
	switch strings.to_lower(s, context.temp_allocator) {
	case "fraction":
		return .Fraction
	case "categorical", "category", "class":
		return .Categorical
	case "composition", "mix":
		return .Composition
	case "vector":
		return .Vector
	case "density":
		return .Density
	case "direction", "bearing", "angle":
		return .Direction
	case "boolean", "bool", "flag":
		return .Boolean
	}
	return .Scalar
}

aggregate_from_name :: proc(s: string) -> Aggregate {
	switch strings.to_lower(s, context.temp_allocator) {
	case "sum":
		return .Sum
	case "min", "minimum":
		return .Min
	case "max", "maximum":
		return .Max
	case "majority", "mode":
		return .Majority
	case "composition", "composition_mean":
		return .Composition_Mean
	case "circular", "circular_mean":
		return .Circular_Mean
	case "any", "or":
		return .Any
	case "none":
		return .None
	}
	return .Mean
}

palette_by_name :: proc(s: string, semantic: Semantic) -> Palette {
	switch strings.to_lower(s, context.temp_allocator) {
	case "viridis":
		return PALETTE_VIRIDIS
	case "terrain":
		return PALETTE_TERRAIN
	case "greens", "green":
		return PALETTE_GREENS
	case "blues", "blue":
		return PALETTE_BLUES
	case "heat", "hot":
		return PALETTE_HEAT
	case "diverging", "anomaly":
		return PALETTE_DIVERGING
	case "cyclic", "direction":
		return PALETTE_CYCLIC
	case "moisture":
		return PALETTE_MOISTURE
	}
	// No palette named: pick one the semantic implies.
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

// ---------------------------------------------------------------------------
// Small JSON helpers, shared with the ingest manifest
// ---------------------------------------------------------------------------

json_string :: proc(obj: json.Object, key: string, default := "") -> string {
	v, has := obj[key]
	if !has {
		return default
	}
	s, ok := v.(json.String)
	return ok ? string(s) : default
}

json_number :: proc(obj: json.Object, key: string, default: f64 = 0) -> f64 {
	v, has := obj[key]
	if !has {
		return default
	}
	n, ok := json_value_number(v)
	return ok ? n : default
}

json_bool :: proc(obj: json.Object, key: string, default := false) -> bool {
	v, has := obj[key]
	if !has {
		return default
	}
	b, ok := v.(json.Boolean)
	return ok ? bool(b) : default
}

json_value_number :: proc(v: json.Value) -> (f64, bool) {
	switch n in v {
	case json.Float:
		return f64(n), true
	case json.Integer:
		return f64(n), true
	case json.Boolean:
		return n ? 1 : 0, true
	case json.Null, json.String, json.Array, json.Object:
		return 0, false
	}
	return 0, false
}
