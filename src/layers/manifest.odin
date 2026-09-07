package layers

import "core:encoding/json"
import "core:fmt"
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

// A declaration that did not become a layer, and why. A manifest of ten layers
// where three are malformed used to report seven added and nothing else; the
// three that vanished are exactly what the author needs to hear about.
Layer_Problem :: struct {
	// The declaration's "name", or "" when that is what was missing.
	name:   string,
	reason: string,
}

Layer_Manifest_Report :: struct {
	added:     int,
	// Declarations that could not be read. Owned by the report.
	skipped:   []Layer_Problem,
	// Names already registered. A manifest adds layers and never redefines one,
	// so these were ignored -- which is the intended policy, but not something
	// to do quietly.
	redefined: []string,
}

layer_manifest_report_destroy :: proc(rep: ^Layer_Manifest_Report, allocator := context.allocator) {
	for p in rep.skipped {
		delete(p.name, allocator)
		delete(p.reason, allocator)
	}
	delete(rep.skipped, allocator)
	for n in rep.redefined {
		delete(n, allocator)
	}
	delete(rep.redefined, allocator)
	rep^ = {}
}

// Loads layer declarations from a JSON file. Strings are cloned into
// `allocator`, which must outlive the registry.
load_layer_manifest :: proc(
	r: ^Registry,
	path: string,
	allocator := context.allocator,
) -> (
	report: Layer_Manifest_Report,
	err: Manifest_Error,
) {
	src, ferr := os.read_entire_file(path, context.allocator)
	if ferr != nil {
		return {}, .File_Not_Found
	}
	defer delete(src, context.allocator)
	return parse_layer_manifest(r, string(src), allocator)
}

parse_layer_manifest :: proc(
	r: ^Registry,
	text: string,
	allocator := context.allocator,
) -> (
	report: Layer_Manifest_Report,
	err: Manifest_Error,
) {
	root, jerr := json.parse_string(text, json.DEFAULT_SPECIFICATION, false, context.allocator)
	if jerr != nil {
		return {}, .Bad_Json
	}
	defer json.destroy_value(root, context.allocator)

	list: json.Array
	switch v in root {
	case json.Array:
		list = v
	case json.Object:
		entry, has := v["layers"]
		if !has {
			return {}, .Bad_Layer
		}
		arr, is_arr := entry.(json.Array)
		if !is_arr {
			return {}, .Bad_Layer
		}
		list = arr
	case json.Null, json.Integer, json.Float, json.Boolean, json.String:
		return {}, .Bad_Layer
	}

	skipped := make([dynamic]Layer_Problem, 0, 4, allocator)
	redefined := make([dynamic]string, 0, 4, allocator)
	for item in list {
		obj, is_obj := item.(json.Object)
		if !is_obj {
			append(&skipped, Layer_Problem{strings.clone("", allocator), strings.clone("not an object", allocator)})
			continue
		}
		desc, reason, built := layer_from_json(obj, allocator)
		if !built {
			append(
				&skipped,
				Layer_Problem {
					strings.clone(json_string(obj, "name"), allocator),
					strings.clone(reason, allocator),
				},
			)
			continue
		}
		if _, fresh := register(r, desc); fresh {
			report.added += 1
		} else {
			append(&redefined, strings.clone(desc.name, allocator))
		}
	}
	report.skipped = skipped[:]
	report.redefined = redefined[:]
	return report, .None
}

/*
Builds one descriptor from a JSON object.

Unspecified fields take the same defaults `desc_normalize` applies to a
hand-written descriptor. A field that is present but unreadable is refused
instead: a misspelled element type or semantic changes how every cell of the
layer is stored and combined, and silently taking the default produces a layer
that looks fine and holds the wrong thing.

`reason` says which field, for the report.
*/
layer_from_json :: proc(
	obj: json.Object,
	allocator := context.allocator,
) -> (
	d: Layer_Desc,
	reason: string,
	ok: bool,
) {
	name := json_string(obj, "name")
	if len(name) == 0 {
		return {}, "no \"name\"", false
	}
	d.name = strings.clone(name, allocator)
	d.group = strings.clone(json_string(obj, "group", "custom"), allocator)
	d.unit = strings.clone(json_string(obj, "unit"), allocator)
	d.description = strings.clone(json_string(obj, "description"), allocator)

	kind_name := json_string(obj, "type", "f32")
	kind_ok: bool
	if d.kind, kind_ok = element_kind_lookup(kind_name); !kind_ok {
		return {}, unknown_field(obj, "type", kind_name, allocator), false
	}
	semantic_name := json_string(obj, "semantic", "scalar")
	semantic_ok: bool
	if d.semantic, semantic_ok = semantic_lookup(semantic_name); !semantic_ok {
		return {}, unknown_field(obj, "semantic", semantic_name, allocator), false
	}
	display_name := json_string(obj, "display", "linear")
	display_ok: bool
	if d.display, display_ok = value_scale_lookup(display_name); !display_ok {
		return {}, unknown_field(obj, "display", display_name, allocator), false
	}
	interp_name := json_string(obj, "interpolate", "linear")
	interp_ok: bool
	if d.interp, interp_ok = interpolation_lookup(interp_name); !interp_ok {
		return {}, unknown_field(obj, "interpolate", interp_name, allocator), false
	}

	d.scale = json_number(obj, "scale", 1)
	d.offset = json_number(obj, "offset", 0)
	d.min_value = json_number(obj, "min", 0)
	d.max_value = json_number(obj, "max", 1)
	d.components = u8(clamp(int(json_number(obj, "components", 1)), 1, 255))

	if agg := json_string(obj, "aggregate"); len(agg) > 0 {
		agg_ok: bool
		if d.aggregate, agg_ok = aggregate_lookup(agg); !agg_ok {
			return {}, unknown_field(obj, "aggregate", agg, allocator), false
		}
	} else {
		d.aggregate = default_aggregate(d.semantic)
	}

	if nd, has := obj["nodata"]; has {
		if v, is_num := json_value_number(nd); is_num {
			d.has_nodata = true
			d.nodata_raw = v
		}
	} else {
		d.has_nodata = true
		d.nodata_raw = default_nodata_raw(d.kind)
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
	if d.semantic == .Color {
		d.components = 3
	}

	if pal := json_string(obj, "palette"); len(pal) > 0 {
		pal_ok: bool
		if d.palette, pal_ok = palette_lookup(pal); !pal_ok {
			return {}, unknown_field(obj, "palette", pal, allocator), false
		}
	} else {
		d.palette = palette_for_semantic(d.semantic)
	}
	desc_normalize(&d)
	return d, "", true
}

@(private = "file")
unknown_field :: proc(obj: json.Object, field, value: string, allocator := context.allocator) -> string {
	return fmt.aprintf("no %s called %q", field, value, allocator = allocator)
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
