package ingest

import "core:math"
import geo "ltb:geo"
import hex "ltb:hex"
import "ltb:layers"
import "ltb:world"

/*
Resampling vector features onto the hex grid.

Roads, footprints and boundaries have to become cell values before the
simulation can read them, and how they should is not obvious: a road is a line
with no area, a building footprint covers part of a cell, and a boundary is a
label. So the caller says what it wants measured:

	Presence      is there one of these here at all
	Count         how many
	Density       how many, or how many metres, per square kilometre
	Value         the attribute value, combined by the layer's rule
	Coverage      what fraction of the cell the polygons cover

and where the number comes from -- a constant, a numeric attribute, or a
classification of a text attribute such as OSM's `highway` tag.
*/

Measure :: enum u8 {
	Presence, // 1 where any matching feature touches the cell
	Count,    // number of matching features touching the cell
	Density,  // features (or metres of line) per square kilometre
	Value,    // the feature's value, combined by `rule`
	Coverage, // fraction of the cell covered by matching polygons
}

// Maps a text attribute to a number, for tag vocabularies like OSM's.
Class_Rule :: struct {
	match: string,
	value: f64,
}

Source_Kind :: enum u8 {
	Constant,
	Number_Field,
	Classified_Field,
}

// Where a feature's value comes from.
Value_Source :: struct {
	kind:     Source_Kind,
	// For .Number_Field and .Classified_Field.
	field:    string,
	// For .Constant, and the fallback when a field is absent or unmatched.
	constant: f64,
	// For .Number_Field: value = attribute * scale + offset.
	scale:    f64,
	offset:   f64,
	// For .Classified_Field.
	classes:  []Class_Rule,
	// Skip features whose class is not listed, rather than using `constant`.
	skip_unclassified: bool,
}

constant_value :: proc(v: f64) -> Value_Source {
	return Value_Source{kind = .Constant, constant = v, scale = 1}
}

number_field :: proc(field: string, scale: f64 = 1, offset: f64 = 0, fallback: f64 = 0) -> Value_Source {
	return Value_Source{kind = .Number_Field, field = field, scale = scale, offset = offset, constant = fallback}
}

classified_field :: proc(field: string, classes: []Class_Rule, fallback: f64 = 0, skip_unclassified := true) -> Value_Source {
	return Value_Source {
		kind = .Classified_Field,
		field = field,
		classes = classes,
		constant = fallback,
		scale = 1,
		skip_unclassified = skip_unclassified,
	}
}

Vector_Options :: struct {
	level:    int,
	measure:  Measure,
	value:    Value_Source,
	// How several features in one cell combine. `.None` uses the layer's rule.
	rule:     layers.Aggregate,
	// Only features satisfying every clause are used.
	filter:   []Filter_Clause,
	// Restricts the write. Defaults to the features' own extent.
	limit:    Maybe(hex.Bounds),
	// Samples per cell when measuring polygon coverage: 1 tests the centre
	// only, 7 adds a ring, 19 adds another. More is slower and smoother.
	coverage_samples: int,
	// Step along a line as a fraction of the cell pitch. Smaller is more
	// accurate about which cells a road passes through, and slower.
	line_step_fraction: f64,
	// Multiplies every contribution before it is accumulated. Converts the
	// natural unit of a measure into the layer's: `.Density` accumulates metres
	// per square kilometre, so a layer in km/km2 wants 0.001.
	unit_scale: f64,
	max_cells: int,
}

Vector_Result :: struct {
	cells_written:    int,
	features_used:    int,
	features_skipped: int,
	line_metres:      f64,
}

// Resamples `fc` onto `w`'s hex grid and writes it into `layer`.
vectorize :: proc(
	w: ^world.World,
	fc: ^Feature_Collection,
	layer: layers.Layer_Id,
	opts := Vector_Options{},
) -> (
	res: Vector_Result,
	err: Error,
) {
	d := layers.desc_of(w.registry, layer)
	if d == nil {
		return {}, .Unknown_Layer
	}
	if len(fc.features) == 0 {
		return {}, .None
	}

	o := opts
	if o.coverage_samples <= 0 {
		o.coverage_samples = 7
	}
	if o.line_step_fraction <= 0 {
		o.line_step_fraction = 0.25
	}
	if o.max_cells == 0 {
		o.max_cells = DEFAULT_MAX_CELLS
	}
	if o.value.scale == 0 {
		o.value.scale = 1
	}
	if o.unit_scale == 0 {
		o.unit_scale = 1
	}

	rule := o.rule
	if rule == .None {
		rule = measure_rule(o.measure, d)
	}

	// Project every vertex into the world frame once.
	pts := make([]geo.Point, len(fc.points), context.allocator)
	defer delete(pts, context.allocator)
	same_frame := fc.projection == w.projection
	for p, i in fc.points {
		src := geo.Point{p.x, p.y}
		pts[i] = same_frame ? src : geo.forward(w.projection, geo.inverse(fc.projection, src))
	}

	lay := world.layout(w, o.level)
	cell_area_km2 := lay_cell_area_km2(lay)
	bounds := o.limit.? or_else world_bounds_of(pts, lay)
	if hex.bounds_count(bounds) > o.max_cells {
		return {}, .Too_Many_Cells
	}

	a: layers.Accumulator
	layers.accum_init(&a, d, rule, context.allocator, 4096)
	defer layers.accum_destroy(&a)

	value_buf: [1]f64
	pitch := hex.cell_pitch(lay)
	step := math.max(pitch * o.line_step_fraction, 1.0)

	for f in fc.features {
		if len(o.filter) > 0 && !feature_matches(f, o.filter) {
			res.features_skipped += 1
			continue
		}
		v, has_value := feature_value(f, o.value)
		if !has_value {
			res.features_skipped += 1
			continue
		}
		res.features_used += 1

		switch f.kind {
		case .Point:
			for r in feature_rings(fc, f) {
				for i in r.start ..< r.start + r.count {
					h := hex.world_to_hex(lay, pts[i])
					if !hex.bounds_contains(bounds, h) {
						continue
					}
					value_buf[0] = point_contribution(o.measure, v, cell_area_km2) * o.unit_scale
					layers.accum_add(&a, h, value_buf[:])
				}
			}

		case .Line:
			for r in feature_rings(fc, f) {
				if r.count < 2 {
					continue
				}
				for i in r.start ..< r.start + r.count - 1 {
					res.line_metres += walk_segment(
						&a,
						lay,
						bounds,
						pts[i],
						pts[i + 1],
						step,
						o.measure,
						v,
						cell_area_km2,
						o.unit_scale,
						&value_buf,
					)
				}
			}

		case .Polygon:
			rings := feature_rings(fc, f)
			fill_polygon(&a, fc, pts, rings, lay, bounds, o, v, cell_area_km2, &value_buf)
		}
	}

	post: proc(value: f64) -> f64 = nil
	if o.measure == .Coverage {
		post = proc(value: f64) -> f64 {
			return clamp(value, 0, 1)
		}
	}
	res.cells_written = layers.accum_flush(&a, w.store, layer, u8(o.level), post)
	return res, .None
}

// ---------------------------------------------------------------------------

@(private)
measure_rule :: proc(m: Measure, d: ^layers.Layer_Desc) -> layers.Aggregate {
	switch m {
	case .Presence:
		return .Any
	case .Count, .Density, .Coverage:
		return .Sum
	case .Value:
		// The layer's own rule: road class takes the maximum, a region id the
		// majority.
		return d.aggregate == .None ? layers.default_aggregate(d.semantic) : d.aggregate
	}
	return .Sum
}

@(private)
point_contribution :: proc(m: Measure, value, cell_area_km2: f64) -> f64 {
	switch m {
	case .Presence:
		return 1
	case .Count:
		return 1
	case .Density:
		return 1.0 / cell_area_km2
	case .Value, .Coverage:
		return value
	}
	return value
}

@(private)
lay_cell_area_km2 :: proc(lay: hex.Layout) -> f64 {
	return math.max(hex.cell_area(lay) / 1e6, 1e-9)
}

@(private)
world_bounds_of :: proc(pts: []geo.Point, lay: hex.Layout) -> hex.Bounds {
	if len(pts) == 0 {
		return hex.Bounds{0, 0, -1, -1}
	}
	mn, mx := pts[0], pts[0]
	for p in pts[1:] {
		mn.x = math.min(mn.x, p.x)
		mn.y = math.min(mn.y, p.y)
		mx.x = math.max(mx.x, p.x)
		mx.y = math.max(mx.y, p.y)
	}
	return hex.bounds_covering_rect(lay, mn, mx)
}

@(private)
feature_value :: proc(f: Feature, src: Value_Source) -> (value: f64, ok: bool) {
	switch src.kind {
	case .Constant:
		return src.constant, true
	case .Number_Field:
		if n, got := attr_number(f, src.field); got {
			return n * src.scale + src.offset, true
		}
		return src.constant, true
	case .Classified_Field:
		if text, got := attr_text(f, src.field); got {
			for c in src.classes {
				if c.match == text {
					return c.value, true
				}
			}
		}
		return src.constant, !src.skip_unclassified
	}
	return 0, false
}

// Walks a segment cell by cell, crediting each cell the length that falls
// inside it. Returns the segment length.
//
// Each step is attributed to the cell holding its midpoint, so the length
// credited across a cell boundary is off by at most one step.
@(private)
walk_segment :: proc(
	a: ^layers.Accumulator,
	lay: hex.Layout,
	bounds: hex.Bounds,
	p0, p1: geo.Point,
	step: f64,
	measure: Measure,
	value, cell_area_km2, unit_scale: f64,
	buf: ^[1]f64,
) -> (
	length: f64,
) {
	dx := p1.x - p0.x
	dy := p1.y - p0.y
	length = math.sqrt(dx * dx + dy * dy)
	if length <= 0 {
		return 0
	}
	steps := max(1, int(math.ceil(length / step)))
	seg_len := length / f64(steps)

	for i in 0 ..< steps {
		t := (f64(i) + 0.5) / f64(steps)
		mid := geo.Point{p0.x + dx * t, p0.y + dy * t}
		h := hex.world_to_hex(lay, mid)
		if !hex.bounds_contains(bounds, h) {
			continue
		}
		switch measure {
		case .Presence, .Count:
			buf[0] = 1
		case .Density:
			buf[0] = seg_len / cell_area_km2 * unit_scale
		case .Value, .Coverage:
			buf[0] = value
		}
		layers.accum_add(a, h, buf[:])
	}
	return
}

@(private)
fill_polygon :: proc(
	a: ^layers.Accumulator,
	fc: ^Feature_Collection,
	pts: []geo.Point,
	rings: []Ring,
	lay: hex.Layout,
	bounds: hex.Bounds,
	o: Vector_Options,
	value, cell_area_km2: f64,
	buf: ^[1]f64,
) {
	// Bounding box of this polygon only, not the whole dataset's extent.
	mn, mx := geo.Point{math.INF_F64, math.INF_F64}, geo.Point{-math.INF_F64, -math.INF_F64}
	for r in rings {
		for i in r.start ..< r.start + r.count {
			p := pts[i]
			mn.x = math.min(mn.x, p.x)
			mn.y = math.min(mn.y, p.y)
			mx.x = math.max(mx.x, p.x)
			mx.y = math.max(mx.y, p.y)
		}
	}
	local := hex.bounds_covering_rect(lay, mn, mx)
	local.q0 = max(local.q0, bounds.q0)
	local.r0 = max(local.r0, bounds.r0)
	local.q1 = min(local.q1, bounds.q1)
	local.r1 = min(local.r1, bounds.r1)
	if hex.bounds_is_empty(local) {
		return
	}

	samples: [19][2]f64
	n_samples := sample_pattern(lay, o.coverage_samples, &samples)

	for rr in local.r0 ..= local.r1 {
		for qq in local.q0 ..= local.q1 {
			h := hex.Hex{qq, rr}
			c := hex.to_world(lay, h)
			inside := 0
			for i in 0 ..< n_samples {
				p := geo.Point{c.x + samples[i].x, c.y + samples[i].y}
				if point_in_rings(pts, rings, p) {
					inside += 1
				}
			}
			if inside == 0 {
				continue
			}
			frac := f64(inside) / f64(n_samples)
			switch o.measure {
			case .Presence, .Count:
				buf[0] = 1
			case .Density:
				buf[0] = o.unit_scale / cell_area_km2
			case .Value:
				buf[0] = value
			case .Coverage:
				buf[0] = frac
			}
			layers.accum_add(a, h, buf[:])
		}
	}
}

// Sample offsets within a cell: the centre, then rings of six.
@(private)
sample_pattern :: proc(lay: hex.Layout, wanted: int, out: ^[19][2]f64) -> int {
	r := math.sqrt(lay.size.x * lay.size.y)
	out[0] = {0, 0}
	if wanted <= 1 {
		return 1
	}
	n := 1
	for ring in 1 ..= 3 {
		radius := r * (0.35 * f64(ring))
		phase := ring % 2 == 0 ? math.PI / 6.0 : 0.0
		for k in 0 ..< 6 {
			if n >= wanted || n >= 19 {
				return n
			}
			ang := phase + f64(k) * math.PI / 3.0
			out[n] = {radius * math.cos(ang), radius * math.sin(ang)}
			n += 1
		}
	}
	return n
}

// Even-odd crossing test against every ring at once, which handles holes
// correctly whichever way they are wound. Real exports are inconsistent about
// winding.
@(private)
point_in_rings :: proc(pts: []geo.Point, rings: []Ring, p: geo.Point) -> bool {
	inside := false
	for r in rings {
		if r.count < 3 {
			continue
		}
		j := r.start + r.count - 1
		for i in r.start ..< r.start + r.count {
			a := pts[i]
			b := pts[j]
			if (a.y > p.y) != (b.y > p.y) {
				x := (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
				if p.x < x {
					inside = !inside
				}
			}
			j = i
		}
	}
	return inside
}
