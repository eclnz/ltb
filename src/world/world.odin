/*
Package world binds the hex grid to the Earth and stacks it into a pyramid.

A world is one projection plus one hex layout, repeated at N levels of detail.
Level 0 is the finest; each level up doubles the cell circumradius, so cell
area quadruples -- the same ratio as a texture mipmap.

The level-to-level relationship is exact and cheap. Every level shares an origin
and an orientation, and level L+1 has exactly twice the cell size of level L, so
a cell's parent is simply the rounding of its halved axial coordinates:

    parent(q, r) = hex.round(q/2, r/2)

That map is a partition: every fine cell has exactly one parent, no cell is
counted twice, and no ground is missed. Parents have three to five children,
four on average. The union of a parent's children is not exactly the parent
hexagon -- hexagons do not tile hexagons -- so treat coarse levels as a
resampling pyramid for display and broad-phase queries, and read level 0 when a
cell boundary has to be authoritative.
*/
package world

import "core:math"
import "core:mem"
import geo "ltb:geo"
import hex "ltb:hex"
import "ltb:layers"

// One level of detail.
Level :: struct {
	index:     int,
	layout:    hex.Layout,
	cell_area: f64, // m^2 of ground per cell (exact in an equal-area projection)
	pitch:     f64, // centre-to-centre distance between neighbours, metres
}

Config :: struct {
	name:            string,
	// Geographic extent the world is meant to cover. Used to centre the
	// projection and to size the level-0 index space.
	bounds:          geo.Geo_Bounds,
	// Ground area of one level-0 cell, in square metres. 1e6 is a cell of about
	// 1 km across; 1e4 is 100 m across.
	base_cell_area:  f64,
	level_count:     int,
	orientation:     hex.Orientation,
	// Leave zeroed to derive a Lambert Azimuthal Equal Area projection centred
	// on `bounds`, which is almost always the right choice.
	projection:      Maybe(geo.Projection),
}

World :: struct {
	name:        string,
	projection:  geo.Projection,
	bounds:      geo.Geo_Bounds,
	levels:      []Level,
	registry:    ^layers.Registry,
	store:       ^layers.Store,
	allocator:   mem.Allocator,
}

MAX_LEVELS :: 16

init :: proc(
	w: ^World,
	cfg: Config,
	registry: ^layers.Registry,
	store: ^layers.Store,
	allocator := context.allocator,
) -> bool {
	if cfg.level_count <= 0 || cfg.level_count > MAX_LEVELS {
		return false
	}
	if cfg.base_cell_area <= 0 {
		return false
	}

	w.name = cfg.name
	w.bounds = cfg.bounds
	w.registry = registry
	w.store = store
	w.allocator = allocator

	if p, has := cfg.projection.?; has {
		w.projection = p
	} else {
		c := geo.geo_bounds_center(cfg.bounds)
		w.projection = geo.proj_laea(c.lat, c.lon)
	}

	orientation := cfg.orientation
	if orientation.f0 == 0 && orientation.f3 == 0 {
		orientation = hex.POINTY
	}

	w.levels = make([]Level, cfg.level_count, allocator)
	base := hex.layout_for_area(orientation, cfg.base_cell_area)
	for i in 0 ..< cfg.level_count {
		s := math.pow(2.0, f64(i))
		l := hex.Layout {
			orientation = orientation,
			size        = {base.size.x * s, base.size.y * s},
			origin      = base.origin,
		}
		w.levels[i] = Level {
			index     = i,
			layout    = l,
			cell_area = hex.cell_area(l),
			pitch     = hex.cell_pitch(l),
		}
	}
	return true
}

destroy :: proc(w: ^World) {
	delete(w.levels, w.allocator)
	w.levels = nil
}

level_count :: proc(w: ^World) -> int {
	return len(w.levels)
}

layout :: proc(w: ^World, level: int) -> hex.Layout {
	return w.levels[clamp(level, 0, len(w.levels) - 1)].layout
}

// ---------------------------------------------------------------------------
// Coordinate conversions
// ---------------------------------------------------------------------------

// Projected metres for a cell centre.
cell_center :: proc(w: ^World, level: int, h: hex.Hex) -> geo.Point {
	return hex.to_world(layout(w, level), h)
}

cell_center_ll :: proc(w: ^World, level: int, h: hex.Hex) -> geo.Lat_Lon {
	return geo.inverse(w.projection, cell_center(w, level, h))
}

// The cell containing a projected point.
cell_at :: proc(w: ^World, level: int, p: geo.Point) -> hex.Hex {
	return hex.world_to_hex(layout(w, level), p)
}

cell_at_ll :: proc(w: ^World, level: int, ll: geo.Lat_Lon) -> hex.Hex {
	return cell_at(w, level, geo.forward(w.projection, ll))
}

// ---------------------------------------------------------------------------
// Pyramid navigation
// ---------------------------------------------------------------------------

// The cell one level coarser that contains `h`. Exact: the levels differ by a
// factor of two in cell size, so halving the axial coordinates and rounding is
// the same as re-projecting the centre through the coarser layout.
parent :: #force_inline proc "contextless" (h: hex.Hex) -> hex.Hex {
	return hex.round(hex.Fractional_Hex{f64(h.q) * 0.5, f64(h.r) * 0.5})
}

// The cell `steps` levels coarser.
ancestor :: proc "contextless" (h: hex.Hex, steps: int) -> hex.Hex {
	if steps <= 0 {
		return h
	}
	s := math.pow(2.0, f64(steps))
	return hex.round(hex.Fractional_Hex{f64(h.q) / s, f64(h.r) / s})
}

// Translates a cell between arbitrary levels. Coarse-to-fine picks the child
// nearest the parent's centre, which is the natural representative cell.
to_level :: proc "contextless" (h: hex.Hex, from_level, to_level: int) -> hex.Hex {
	d := to_level - from_level
	if d == 0 {
		return h
	}
	s := math.pow(2.0, f64(d))
	return hex.round(hex.Fractional_Hex{f64(h.q) / s, f64(h.r) / s})
}

MAX_CHILDREN :: 7

// Writes the finer cells whose parent is `h` into `out` and returns the filled
// slice. There are always between three and five, four on average.
children :: proc "contextless" (h: hex.Hex, out: ^[MAX_CHILDREN]hex.Hex) -> []hex.Hex {
	n := 0
	for dq in i32(-1) ..= 2 {
		for dr in i32(-1) ..= 2 {
			c := hex.Hex{h.q * 2 + dq, h.r * 2 + dr}
			if parent(c) == h && n < MAX_CHILDREN {
				out[n] = c
				n += 1
			}
		}
	}
	return out[:n]
}

// ---------------------------------------------------------------------------
// Level selection
// ---------------------------------------------------------------------------

// Picks the coarsest level whose cells still cover at least `min_pixels` on
// screen, given how many metres one pixel spans. This is the mipmap choice:
// zoom out and the world quietly switches to coarser, cheaper data.
// `min_pixels` is the caller's: the renderer owns the policy, so there is no
// second default here to disagree with it.
level_for_scale :: proc(w: ^World, metres_per_pixel: f64, min_pixels: f64) -> int {
	if metres_per_pixel <= 0 {
		return 0
	}
	want := metres_per_pixel * min_pixels
	best := 0
	for i in 0 ..< len(w.levels) {
		if w.levels[i].pitch <= want {
			best = i
		} else {
			break
		}
	}
	return best
}

// Ground resolution of a level, as the centre-to-centre cell spacing.
level_resolution :: proc(w: ^World, level: int) -> f64 {
	return w.levels[clamp(level, 0, len(w.levels) - 1)].pitch
}

// ---------------------------------------------------------------------------
// Region queries
// ---------------------------------------------------------------------------

// Axial bounds at `level` covering a projected rectangle.
bounds_for_rect :: proc(w: ^World, level: int, min, max: geo.Point) -> hex.Bounds {
	return hex.bounds_covering_rect(layout(w, level), min, max)
}

// Axial bounds at `level` covering a geographic box. The box corners are
// projected and the resulting rectangle is padded by one cell; for boxes small
// enough that the projection stays near-affine -- which is the regime an
// equal-area projection is used in -- this is a safe cover.
bounds_for_geo :: proc(w: ^World, level: int, b: geo.Geo_Bounds) -> hex.Bounds {
	pts := [4]geo.Point {
		geo.forward(w.projection, geo.lat_lon(b.lat_min, b.lon_min)),
		geo.forward(w.projection, geo.lat_lon(b.lat_min, b.lon_max)),
		geo.forward(w.projection, geo.lat_lon(b.lat_max, b.lon_min)),
		geo.forward(w.projection, geo.lat_lon(b.lat_max, b.lon_max)),
	}
	mn := pts[0]
	mx := pts[0]
	for i in 1 ..< 4 {
		mn.x = math.min(mn.x, pts[i].x)
		mn.y = math.min(mn.y, pts[i].y)
		mx.x = math.max(mx.x, pts[i].x)
		mx.y = math.max(mx.y, pts[i].y)
	}
	return hex.bounds_covering_rect(layout(w, level), mn, mx)
}

// The world's default extent at a level, from its configured geographic bounds.
extent :: proc(w: ^World, level: int) -> hex.Bounds {
	return bounds_for_geo(w, level, w.bounds)
}

// Projected-metre bounding box of the world's configured geographic extent.
world_extent_metres :: proc(w: ^World) -> (min, max: geo.Point) {
	b := w.bounds
	pts := [4]geo.Point {
		geo.forward(w.projection, geo.lat_lon(b.lat_min, b.lon_min)),
		geo.forward(w.projection, geo.lat_lon(b.lat_min, b.lon_max)),
		geo.forward(w.projection, geo.lat_lon(b.lat_max, b.lon_min)),
		geo.forward(w.projection, geo.lat_lon(b.lat_max, b.lon_max)),
	}
	min = pts[0]
	max = pts[0]
	for i in 1 ..< 4 {
		min.x = math.min(min.x, pts[i].x)
		min.y = math.min(min.y, pts[i].y)
		max.x = math.max(max.x, pts[i].x)
		max.y = math.max(max.y, pts[i].y)
	}
	return
}
