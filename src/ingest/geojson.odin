package ingest

import "core:encoding/json"
import "core:os"
import "core:strings"
import geo "ltb:geo"

/*
GeoJSON reader.

GeoJSON is what almost every vector export offers, and what Overpass and most
open-data portals hand out directly, so it is the path of least resistance for
getting a road network or a set of building footprints into a world.

RFC 7946 fixes the coordinate reference system: longitude and latitude on WGS84,
in that order. Files in the wild sometimes carry a "crs" member from the older
2008 draft; `crs_override` is there for those.
*/

Geojson_Error :: enum {
	None,
	File_Not_Found,
	Bad_Json,
	Not_A_Feature_Collection,
	Unsupported_Geometry,
}

read_geojson :: proc(
	path: string,
	crs_override: Maybe(geo.Projection) = nil,
	allocator := context.allocator,
) -> (
	fc: Feature_Collection,
	err: Geojson_Error,
) {
	src, ferr := os.read_entire_file(path, context.allocator)
	if ferr != nil {
		return {}, .File_Not_Found
	}
	defer delete(src, context.allocator)
	fc, err = parse_geojson(string(src), crs_override, allocator)
	if err == .None {
		fc.name = path
	}
	return
}

parse_geojson :: proc(
	text: string,
	crs_override: Maybe(geo.Projection) = nil,
	allocator := context.allocator,
) -> (
	fc: Feature_Collection,
	err: Geojson_Error,
) {
	root, jerr := json.parse_string(text, json.DEFAULT_SPECIFICATION, false, context.allocator)
	if jerr != nil {
		return {}, .Bad_Json
	}
	defer json.destroy_value(root, context.allocator)

	obj, is_obj := root.(json.Object)
	if !is_obj {
		return {}, .Not_A_Feature_Collection
	}

	features_init(&fc, crs_override.? or_else geo.proj_geographic(), allocator)

	type_name := object_string(obj, "type")
	switch type_name {
	case "FeatureCollection":
		arr, has := obj["features"]
		if !has {
			return fc, .Not_A_Feature_Collection
		}
		list, is_arr := arr.(json.Array)
		if !is_arr {
			return fc, .Not_A_Feature_Collection
		}
		for item in list {
			if fobj, ok := item.(json.Object); ok {
				add_geojson_feature(&fc, fobj)
			}
		}
	case "Feature":
		add_geojson_feature(&fc, obj)
	case "GeometryCollection":
		if arr, has := obj["geometries"]; has {
			if list, is_arr := arr.(json.Array); is_arr {
				for item in list {
					if gobj, ok := item.(json.Object); ok {
						add_geojson_geometry(&fc, gobj, nil)
					}
				}
			}
		}
	case:
		// A bare geometry object is legal GeoJSON too.
		add_geojson_geometry(&fc, obj, nil)
	}
	return fc, .None
}

@(private)
object_string :: proc(o: json.Object, key: string) -> string {
	v, has := o[key]
	if !has {
		return ""
	}
	s, ok := v.(json.String)
	return ok ? string(s) : ""
}

@(private)
add_geojson_feature :: proc(fc: ^Feature_Collection, obj: json.Object) {
	geom, has := obj["geometry"]
	if !has {
		return
	}
	gobj, ok := geom.(json.Object)
	if !ok {
		return
	}
	props: json.Object
	if p, hasp := obj["properties"]; hasp {
		if po, isobj := p.(json.Object); isobj {
			props = po
		}
	}
	add_geojson_geometry(fc, gobj, props)
}

@(private)
add_geojson_geometry :: proc(fc: ^Feature_Collection, gobj: json.Object, props: json.Object) {
	coords, has := gobj["coordinates"]
	kind_name := object_string(gobj, "type")

	// MultiGeometries become one feature per part, each carrying a copy of the
	// attributes. Keeping them together would only complicate every consumer.
	switch kind_name {
	case "Point":
		if !has {return}
		if p, ok := read_position(coords); ok {
			start := u32(len(fc.points))
			append(&fc.points, p)
			emit_feature(fc, .Point, start, 1, false, props)
		}
	case "MultiPoint":
		if !has {return}
		if arr, ok := coords.(json.Array); ok {
			for item in arr {
				if p, got := read_position(item); got {
					start := u32(len(fc.points))
					append(&fc.points, p)
					emit_feature(fc, .Point, start, 1, false, props)
				}
			}
		}
	case "LineString":
		if !has {return}
		emit_ring_feature(fc, .Line, coords, props)
	case "MultiLineString":
		if !has {return}
		if arr, ok := coords.(json.Array); ok {
			for item in arr {
				emit_ring_feature(fc, .Line, item, props)
			}
		}
	case "Polygon":
		if !has {return}
		emit_polygon(fc, coords, props)
	case "MultiPolygon":
		if !has {return}
		if arr, ok := coords.(json.Array); ok {
			for item in arr {
				emit_polygon(fc, item, props)
			}
		}
	case "GeometryCollection":
		if inner, hasg := gobj["geometries"]; hasg {
			if arr, ok := inner.(json.Array); ok {
				for item in arr {
					if o, isobj := item.(json.Object); isobj {
						add_geojson_geometry(fc, o, props)
					}
				}
			}
		}
	}
}

@(private)
read_position :: proc(v: json.Value) -> (p: [2]f64, ok: bool) {
	arr := v.(json.Array) or_return
	if len(arr) < 2 {
		return {}, false
	}
	x := number_of(arr[0]) or_return
	y := number_of(arr[1]) or_return
	// GeoJSON is longitude, latitude. Everything downstream works in
	// projection-plane x, y, and for geographic coordinates x is longitude.
	return [2]f64{x, y}, true
}

@(private)
number_of :: proc(v: json.Value) -> (f64, bool) {
	switch n in v {
	case json.Float:
		return f64(n), true
	case json.Integer:
		return f64(n), true
	case json.Boolean:
		return n ? 1 : 0, true
	case json.String:
		return parse_number(string(n))
	case json.Null, json.Array, json.Object:
		return 0, false
	}
	return 0, false
}

@(private)
emit_ring_feature :: proc(fc: ^Feature_Collection, kind: Geometry_Kind, coords: json.Value, props: json.Object) {
	arr, ok := coords.(json.Array)
	if !ok || len(arr) == 0 {
		return
	}
	start := u32(len(fc.points))
	n := u32(0)
	for item in arr {
		if p, got := read_position(item); got {
			append(&fc.points, p)
			n += 1
		}
	}
	if n == 0 {
		return
	}
	emit_feature(fc, kind, start, n, false, props)
}

@(private)
emit_polygon :: proc(fc: ^Feature_Collection, coords: json.Value, props: json.Object) {
	rings, ok := coords.(json.Array)
	if !ok || len(rings) == 0 {
		return
	}
	first_ring := u32(len(fc.rings))
	ring_count := u32(0)
	for ring, i in rings {
		arr, is_arr := ring.(json.Array)
		if !is_arr || len(arr) < 3 {
			continue
		}
		start := u32(len(fc.points))
		n := u32(0)
		for item in arr {
			if p, got := read_position(item); got {
				append(&fc.points, p)
				n += 1
			}
		}
		if n < 3 {
			resize(&fc.points, int(start))
			continue
		}
		// The first ring is the outer boundary; the rest are holes.
		append(&fc.rings, Ring{start = start, count = n, hole = i > 0})
		ring_count += 1
	}
	if ring_count == 0 {
		return
	}
	f := Feature {
		kind       = .Polygon,
		first_ring = first_ring,
		ring_count = ring_count,
	}
	copy_props(fc, &f, props)
	append(&fc.features, f)
}

@(private)
emit_feature :: proc(
	fc: ^Feature_Collection,
	kind: Geometry_Kind,
	start, count: u32,
	hole: bool,
	props: json.Object,
) {
	first_ring := u32(len(fc.rings))
	append(&fc.rings, Ring{start = start, count = count, hole = hole})
	f := Feature {
		kind       = kind,
		first_ring = first_ring,
		ring_count = 1,
	}
	copy_props(fc, &f, props)
	append(&fc.features, f)
}

// Attributes are cloned out of the JSON document so the collection outlives it.
@(private)
copy_props :: proc(fc: ^Feature_Collection, f: ^Feature, props: json.Object) {
	if props == nil || len(props) == 0 {
		return
	}
	f.props = make(map[string]Attr, len(props) * 2, fc.allocator)
	for key, value in props {
		attr: Attr
		switch v in value {
		case json.Float:
			attr = f64(v)
		case json.Integer:
			attr = f64(v)
		case json.Boolean:
			attr = bool(v)
		case json.String:
			attr = strings.clone(string(v), fc.allocator)
		case json.Null, json.Array, json.Object:
			continue // nested attributes have no place on a raster cell
		}
		f.props[strings.clone(key, fc.allocator)] = attr
	}
}
