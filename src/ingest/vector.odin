/*
Vector geospatial data: points, lines and polygons with attributes.

Rasters describe fields -- elevation, rainfall, canopy cover. Roads, buildings,
parcels, administrative boundaries and river centrelines are features with
attributes instead, and arrive as GeoJSON or shapefiles. This is the in-memory
form they decode into; `vectorize.odin` resamples it onto the hex grid.

Geometry lives in flat arrays with ranges into them, so walking a whole
collection is a linear scan.
*/
package ingest

import "core:math"
import "core:mem"
import "core:strings"
import geo "ltb:geo"

Geometry_Kind :: enum u8 {
	Point,
	Line,    // a polyline; one part per ring entry
	Polygon, // first ring is the outer boundary, the rest are holes
}

// A contiguous run of vertices in `Feature_Collection.points`.
Ring :: struct {
	start: u32,
	count: u32,
	hole:  bool,
}

// An attribute value. Vector formats carry numbers, strings and flags, and
// which one a field holds varies between publishers of the same dataset.
Attr :: union {
	f64,
	string,
	bool,
}

Feature :: struct {
	kind:       Geometry_Kind,
	first_ring: u32,
	ring_count: u32,
	props:      map[string]Attr,
}

Feature_Collection :: struct {
	// CRS the coordinates are in. GeoJSON is defined to be WGS84 longitude and
	// latitude, so readers of that format set `proj_geographic`.
	projection: geo.Projection,
	points:     [dynamic][2]f64,
	rings:      [dynamic]Ring,
	features:   [dynamic]Feature,
	name:       string,
	allocator:  mem.Allocator,
}

features_init :: proc(fc: ^Feature_Collection, projection: geo.Projection, allocator := context.allocator) {
	fc.projection = projection
	fc.allocator = allocator
	fc.points = make([dynamic][2]f64, allocator)
	fc.rings = make([dynamic]Ring, allocator)
	fc.features = make([dynamic]Feature, allocator)
}

features_destroy :: proc(fc: ^Feature_Collection) {
	// Keys and string values were cloned into the collection's allocator when
	// the feature was read, so they are freed here rather than by the reader.
	for &f in fc.features {
		for k, v in f.props {
			delete(k, fc.allocator)
			if s, is_string := v.(string); is_string {
				delete(s, fc.allocator)
			}
		}
		delete(f.props)
	}
	delete(fc.points)
	delete(fc.rings)
	delete(fc.features)
	fc^ = {}
}

feature_rings :: proc(fc: ^Feature_Collection, f: Feature) -> []Ring {
	return fc.rings[f.first_ring:f.first_ring + f.ring_count]
}

ring_points :: proc(fc: ^Feature_Collection, r: Ring) -> [][2]f64 {
	return fc.points[r.start:r.start + r.count]
}

// ---------------------------------------------------------------------------
// Attributes
// ---------------------------------------------------------------------------

// Reads an attribute as a number, converting a numeric string if that is what
// the publisher used. `ok` is false for an absent or non-numeric field.
attr_number :: proc(f: Feature, key: string) -> (value: f64, ok: bool) {
	a := f.props[key] or_return
	switch v in a {
	case f64:
		return v, true
	case bool:
		return v ? 1 : 0, true
	case string:
		return parse_number(v)
	}
	return 0, false
}

attr_text :: proc(f: Feature, key: string) -> (value: string, ok: bool) {
	a := f.props[key] or_return
	if s, is_string := a.(string); is_string {
		return s, true
	}
	return "", false
}

@(private)
parse_number :: proc(s: string) -> (f64, bool) {
	// Accepts the shapes DBF and CSV attribute fields arrive in: leading and
	// trailing padding, a leading sign, and a comma as the decimal separator.
	t := strings.trim_space(s)
	if len(t) == 0 {
		return 0, false
	}
	neg := false
	i := 0
	if t[0] == '+' || t[0] == '-' {
		neg = t[0] == '-'
		i = 1
	}
	whole, frac, scale := 0.0, 0.0, 1.0
	digits := 0
	for i < len(t) && t[i] >= '0' && t[i] <= '9' {
		whole = whole * 10 + f64(t[i] - '0')
		i += 1
		digits += 1
	}
	if i < len(t) && (t[i] == '.' || t[i] == ',') {
		i += 1
		for i < len(t) && t[i] >= '0' && t[i] <= '9' {
			scale *= 0.1
			frac += f64(t[i] - '0') * scale
			i += 1
			digits += 1
		}
	}
	if digits == 0 || i != len(t) {
		return 0, false
	}
	v := whole + frac
	return neg ? -v : v, true
}

// ---------------------------------------------------------------------------
// Filtering
// ---------------------------------------------------------------------------

// A filter clause: the feature passes if its `key` attribute equals any of
// `any_of`. An empty `any_of` means the key merely has to be present.
Filter_Clause :: struct {
	key:    string,
	any_of: []string,
	// Inverts the clause, for "everything except these".
	negate: bool,
}

// A feature passes when it satisfies every clause.
feature_matches :: proc(f: Feature, clauses: []Filter_Clause) -> bool {
	for c in clauses {
		text, has := attr_text(f, c.key)
		if !has {
			// A numeric or boolean attribute still counts as present.
			_, present := f.props[c.key]
			if !present {
				if !c.negate {
					return false
				}
				continue
			}
		}
		hit := len(c.any_of) == 0
		for want in c.any_of {
			if text == want {
				hit = true
				break
			}
		}
		if hit == c.negate {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Extents
// ---------------------------------------------------------------------------

features_geo_bounds :: proc(fc: ^Feature_Collection) -> geo.Geo_Bounds {
	b := geo.Geo_Bounds {
		lat_min = 90,
		lat_max = -90,
		lon_min = 180,
		lon_max = -180,
	}
	for p in fc.points {
		ll := geo.inverse(fc.projection, geo.Point{p.x, p.y})
		b.lat_min = math.min(b.lat_min, ll.lat)
		b.lat_max = math.max(b.lat_max, ll.lat)
		b.lon_min = math.min(b.lon_min, ll.lon)
		b.lon_max = math.max(b.lon_max, ll.lon)
	}
	return b
}

feature_count_by_kind :: proc(fc: ^Feature_Collection) -> (points, lines, polygons: int) {
	for f in fc.features {
		switch f.kind {
		case .Point:
			points += 1
		case .Line:
			lines += 1
		case .Polygon:
			polygons += 1
		}
	}
	return
}
