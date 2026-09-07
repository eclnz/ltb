/*
Package hex implements exact integer hexagonal grid mathematics.

Coordinates are axial (q, r) with the implied cube coordinate s = -q - r.
All grid arithmetic is integer and therefore exact; only the conversion to and
from continuous world space uses floating point.

The layout formulation (forward/inverse basis matrices plus a start angle)
follows the standard treatment in Amit Patel's hexagonal grid reference.
*/
package hex

import "core:math"

// Axial hex coordinate. The third cube axis is implicit: s == -q - r.
Hex :: struct {
	q, r: i32,
}

// Continuous hex coordinate, produced by inverse layout transforms before rounding.
Fractional_Hex :: struct {
	q, r: f64,
}

Vec2 :: [2]f64

s_of :: #force_inline proc "contextless" (h: Hex) -> i32 {
	return -h.q - h.r
}

// Cube coordinate triple, useful for rotations, reflections and interpolation.
cube :: #force_inline proc "contextless" (h: Hex) -> [3]i32 {
	return {h.q, h.r, -h.q - h.r}
}

from_cube :: #force_inline proc "contextless" (c: [3]i32) -> Hex {
	return Hex{c.x, c.y}
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

add :: #force_inline proc "contextless" (a, b: Hex) -> Hex {
	return Hex{a.q + b.q, a.r + b.r}
}

sub :: #force_inline proc "contextless" (a, b: Hex) -> Hex {
	return Hex{a.q - b.q, a.r - b.r}
}

scale :: #force_inline proc "contextless" (a: Hex, k: i32) -> Hex {
	return Hex{a.q * k, a.r * k}
}

// Ring distance from the origin, i.e. the number of steps to reach (0, 0).
length :: #force_inline proc "contextless" (h: Hex) -> i32 {
	q, r, s := abs(h.q), abs(h.r), abs(-h.q - h.r)
	return max(q, max(r, s))
}

distance :: #force_inline proc "contextless" (a, b: Hex) -> i32 {
	return length(sub(a, b))
}

// ---------------------------------------------------------------------------
// Neighbourhood
// ---------------------------------------------------------------------------

// Direction indices are counter-clockwise starting at "east" in axial space.
// The world-space bearing of a direction depends on the layout orientation.
Direction :: distinct int

DIRECTION_COUNT :: 6

DIRECTIONS := [DIRECTION_COUNT]Hex {
	{+1, 0},
	{+1, -1},
	{0, -1},
	{-1, 0},
	{-1, +1},
	{0, +1},
}

// The six vertex-adjacent (but not edge-adjacent) cells, two rings out.
DIAGONALS := [DIRECTION_COUNT]Hex {
	{+2, -1},
	{+1, -2},
	{-1, -1},
	{-2, +1},
	{-1, +2},
	{+1, +1},
}

direction :: #force_inline proc "contextless" (d: Direction) -> Hex {
	return DIRECTIONS[int(d) %% DIRECTION_COUNT]
}

neighbor :: #force_inline proc "contextless" (h: Hex, d: Direction) -> Hex {
	return add(h, direction(d))
}

diagonal_neighbor :: #force_inline proc "contextless" (h: Hex, d: Direction) -> Hex {
	return add(h, DIAGONALS[int(d) %% DIRECTION_COUNT])
}

// Fills `out` with the six edge neighbours and returns the slice actually written.
neighbors :: proc "contextless" (h: Hex, out: ^[DIRECTION_COUNT]Hex) -> []Hex {
	for d in 0 ..< DIRECTION_COUNT {
		out[d] = add(h, DIRECTIONS[d])
	}
	return out[:]
}

// 60 degree rotations about the origin, in cube space.
rotate_left :: #force_inline proc "contextless" (h: Hex) -> Hex {
	c := cube(h)
	return from_cube({-c.z, -c.x, -c.y})
}

rotate_right :: #force_inline proc "contextless" (h: Hex) -> Hex {
	c := cube(h)
	return from_cube({-c.y, -c.z, -c.x})
}

// ---------------------------------------------------------------------------
// Rounding and interpolation
// ---------------------------------------------------------------------------

// Rounds a continuous hex coordinate to the nearest cell, preserving q+r+s == 0
// by discarding the component with the largest rounding error.
round :: proc "contextless" (f: Fractional_Hex) -> Hex {
	fs := -f.q - f.r
	q := math.round(f.q)
	r := math.round(f.r)
	s := math.round(fs)

	dq := abs(q - f.q)
	dr := abs(r - f.r)
	ds := abs(s - fs)

	if dq > dr && dq > ds {
		q = -r - s
	} else if dr > ds {
		r = -q - s
	}
	return Hex{i32(q), i32(r)}
}

lerp :: #force_inline proc "contextless" (a, b: Hex, t: f64) -> Fractional_Hex {
	return Fractional_Hex{
		f64(a.q) + (f64(b.q) - f64(a.q)) * t,
		f64(a.r) + (f64(b.r) - f64(a.r)) * t,
	}
}

// Appends the cells along the straight line from `a` to `b` (inclusive) to `out`.
// The small epsilon nudge keeps the walk off exact edge ties, which would
// otherwise round unpredictably.
line :: proc(a, b: Hex, out: ^[dynamic]Hex) {
	n := distance(a, b)
	if n == 0 {
		append(out, a)
		return
	}
	ax := Fractional_Hex{f64(a.q) + 1e-6, f64(a.r) + 1e-6}
	bx := Fractional_Hex{f64(b.q) + 1e-6, f64(b.r) + 1e-6}
	step := 1.0 / f64(n)
	for i in 0 ..= n {
		t := step * f64(i)
		f := Fractional_Hex{
			ax.q + (bx.q - ax.q) * t,
			ax.r + (bx.r - ax.r) * t,
		}
		append(out, round(f))
	}
}

// ---------------------------------------------------------------------------
// Ranges
// ---------------------------------------------------------------------------

// Appends the `radius`-step ring around `center`. A radius of 0 appends only
// the centre cell.
ring :: proc(center: Hex, radius: i32, out: ^[dynamic]Hex) {
	if radius <= 0 {
		append(out, center)
		return
	}
	h := add(center, scale(DIRECTIONS[4], radius))
	for d in 0 ..< DIRECTION_COUNT {
		for _ in 0 ..< radius {
			append(out, h)
			h = neighbor(h, Direction(d))
		}
	}
}

// Appends every cell within `radius` steps of `center`, innermost ring first.
spiral :: proc(center: Hex, radius: i32, out: ^[dynamic]Hex) {
	for k in 0 ..= radius {
		ring(center, k, out)
	}
}

// Number of cells within `radius` steps of a centre cell.
range_count :: #force_inline proc "contextless" (radius: i32) -> i32 {
	if radius < 0 {
		return 0
	}
	return 3 * radius * (radius + 1) + 1
}

// ---------------------------------------------------------------------------
// Layout: mapping between hex indices and continuous world space
// ---------------------------------------------------------------------------

// Forward (f) and inverse (b) 2x2 basis matrices plus the angle, in sixths of a
// turn, of the first corner.
Orientation :: struct {
	f0, f1, f2, f3: f64,
	b0, b1, b2, b3: f64,
	start_angle:    f64,
}

@(rodata)
POINTY := Orientation {
	f0          = math.SQRT_THREE,
	f1          = math.SQRT_THREE / 2.0,
	f2          = 0.0,
	f3          = 3.0 / 2.0,
	b0          = math.SQRT_THREE / 3.0,
	b1          = -1.0 / 3.0,
	b2          = 0.0,
	b3          = 2.0 / 3.0,
	start_angle = 0.5,
}

@(rodata)
FLAT := Orientation {
	f0          = 3.0 / 2.0,
	f1          = 0.0,
	f2          = math.SQRT_THREE / 2.0,
	f3          = math.SQRT_THREE,
	b0          = 2.0 / 3.0,
	b1          = 0.0,
	b2          = -1.0 / 3.0,
	b3          = math.SQRT_THREE / 3.0,
	start_angle = 0.0,
}

// A hex grid embedded in continuous world space.
//
// `size` is the circumradius (centre to corner) along each world axis; equal
// components give regular hexagons. `origin` is the world position of cell
// (0, 0).
Layout :: struct {
	orientation: Orientation,
	size:        Vec2,
	origin:      Vec2,
}

// Builds a layout of regular hexagons with the given circumradius.
layout_regular :: proc "contextless" (orientation: Orientation, circumradius: f64, origin := Vec2{0, 0}) -> Layout {
	return Layout{orientation, Vec2{circumradius, circumradius}, origin}
}

// Builds a layout of regular hexagons of a given area, which is how grids are
// specified in equal-area projections.
layout_for_area :: proc "contextless" (orientation: Orientation, area: f64, origin := Vec2{0, 0}) -> Layout {
	// area = (3*sqrt(3)/2) * R^2
	r := math.sqrt(area / (1.5 * math.SQRT_THREE))
	return layout_regular(orientation, r, origin)
}

to_world :: proc "contextless" (l: Layout, h: Hex) -> Vec2 {
	o := l.orientation
	x := (o.f0 * f64(h.q) + o.f1 * f64(h.r)) * l.size.x
	y := (o.f2 * f64(h.q) + o.f3 * f64(h.r)) * l.size.y
	return Vec2{x + l.origin.x, y + l.origin.y}
}

to_world_fractional :: proc "contextless" (l: Layout, f: Fractional_Hex) -> Vec2 {
	o := l.orientation
	x := (o.f0 * f.q + o.f1 * f.r) * l.size.x
	y := (o.f2 * f.q + o.f3 * f.r) * l.size.y
	return Vec2{x + l.origin.x, y + l.origin.y}
}

from_world :: proc "contextless" (l: Layout, p: Vec2) -> Fractional_Hex {
	o := l.orientation
	px := (p.x - l.origin.x) / l.size.x
	py := (p.y - l.origin.y) / l.size.y
	return Fractional_Hex{o.b0 * px + o.b1 * py, o.b2 * px + o.b3 * py}
}

// Convenience: world position straight to the containing cell.
world_to_hex :: proc "contextless" (l: Layout, p: Vec2) -> Hex {
	return round(from_world(l, p))
}

corner_offset :: proc "contextless" (l: Layout, corner: int) -> Vec2 {
	angle := 2.0 * math.PI * (l.orientation.start_angle + f64(corner)) / 6.0
	return Vec2{l.size.x * math.cos(angle), l.size.y * math.sin(angle)}
}

// Writes the six corners of `h` in world space, counter-clockwise.
corners :: proc "contextless" (l: Layout, h: Hex, out: ^[6]Vec2) {
	c := to_world(l, h)
	for i in 0 ..< 6 {
		off := corner_offset(l, i)
		out[i] = Vec2{c.x + off.x, c.y + off.y}
	}
}

// Half-extent of a single cell's axis-aligned bounding box.
cell_half_extent :: proc "contextless" (l: Layout) -> Vec2 {
	if l.orientation.start_angle == 0.5 {
		// pointy-top: flat sides left/right, points up/down
		return Vec2{l.size.x * math.SQRT_THREE / 2.0, l.size.y}
	}
	return Vec2{l.size.x, l.size.y * math.SQRT_THREE / 2.0}
}

// Area of one cell, in squared world units. Meaningful for equal-area
// projections, where it is a genuine ground area.
cell_area :: proc "contextless" (l: Layout) -> f64 {
	return 1.5 * math.SQRT_THREE * l.size.x * l.size.y
}

// Centre-to-centre spacing between edge neighbours.
cell_pitch :: proc "contextless" (l: Layout) -> f64 {
	return math.SQRT_THREE * math.sqrt(l.size.x * l.size.y)
}

// ---------------------------------------------------------------------------
// Region queries
// ---------------------------------------------------------------------------

// Inclusive axial bounds. An axial rectangle is a parallelogram in world space,
// so `bounds_covering_rect` over-covers.
Bounds :: struct {
	q0, r0: i32, // inclusive
	q1, r1: i32, // inclusive
}

bounds_is_empty :: proc "contextless" (b: Bounds) -> bool {
	return b.q1 < b.q0 || b.r1 < b.r0
}

bounds_count :: proc "contextless" (b: Bounds) -> int {
	if bounds_is_empty(b) {
		return 0
	}
	return int(b.q1 - b.q0 + 1) * int(b.r1 - b.r0 + 1)
}

bounds_contains :: proc "contextless" (b: Bounds, h: Hex) -> bool {
	return h.q >= b.q0 && h.q <= b.q1 && h.r >= b.r0 && h.r <= b.r1
}

// Axial bounds guaranteed to contain every cell whose centre lies inside the
// world-space rectangle [min, max]. The four rectangle corners bound the axial
// region because the inverse layout transform is affine, and one extra cell of
// margin covers cells straddling the border.
bounds_covering_rect :: proc "contextless" (l: Layout, min, max: Vec2) -> Bounds {
	c0 := from_world(l, Vec2{min.x, min.y})
	c1 := from_world(l, Vec2{max.x, min.y})
	c2 := from_world(l, Vec2{min.x, max.y})
	c3 := from_world(l, Vec2{max.x, max.y})

	qmin := math.min(math.min(c0.q, c1.q), math.min(c2.q, c3.q))
	qmax := math.max(math.max(c0.q, c1.q), math.max(c2.q, c3.q))
	rmin := math.min(math.min(c0.r, c1.r), math.min(c2.r, c3.r))
	rmax := math.max(math.max(c0.r, c1.r), math.max(c2.r, c3.r))

	return Bounds {
		q0 = i32(math.floor(qmin)) - 1,
		r0 = i32(math.floor(rmin)) - 1,
		q1 = i32(math.ceil(qmax)) + 1,
		r1 = i32(math.ceil(rmax)) + 1,
	}
}

// World-space axis-aligned bounding box of every cell in `b`, including the
// cells' own extents. Correct despite the shear because the axial rectangle is
// convex, so its world image is bounded by its four corner cells.
bounds_world_aabb :: proc "contextless" (l: Layout, b: Bounds) -> (min, max: Vec2) {
	p0 := to_world(l, Hex{b.q0, b.r0})
	p1 := to_world(l, Hex{b.q1, b.r0})
	p2 := to_world(l, Hex{b.q0, b.r1})
	p3 := to_world(l, Hex{b.q1, b.r1})

	min = Vec2{math.min(math.min(p0.x, p1.x), math.min(p2.x, p3.x)), math.min(math.min(p0.y, p1.y), math.min(p2.y, p3.y))}
	max = Vec2{math.max(math.max(p0.x, p1.x), math.max(p2.x, p3.x)), math.max(math.max(p0.y, p1.y), math.max(p2.y, p3.y))}

	he := cell_half_extent(l)
	min -= he
	max += he
	return
}

// True if the world point lies within the cell `h`, using the exact
// nearest-centre definition of cell ownership.
contains_point :: proc "contextless" (l: Layout, h: Hex, p: Vec2) -> bool {
	return world_to_hex(l, p) == h
}
