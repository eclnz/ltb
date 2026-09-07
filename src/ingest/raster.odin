/*
Package ingest turns real map data into hex layers.

A reader produces a `Raster` -- a georeferenced grid of numbers with a known CRS
-- and `rasterize` resamples it onto a world's hex grid. Every raster format
stops at `Raster`, so nothing downstream depends on the source format.
*/
package ingest

import "core:math"
import geo "ltb:geo"
import "ltb:layers"

// Affine map from pixel indices to projected coordinates, in the GDAL
// convention: the transform is applied to the pixel's *corner*, so a pixel
// centre is at (col + 0.5, row + 0.5).
Affine :: struct {
	// x = c + a*col + b*row
	// y = f + d*col + e*row
	c, a, b: f64,
	f, d, e: f64,
}

affine_north_up :: proc "contextless" (origin_x, origin_y, pixel_w, pixel_h: f64) -> Affine {
	// pixel_h is normally negative: rows increase southwards.
	return Affine{c = origin_x, a = pixel_w, b = 0, f = origin_y, d = 0, e = pixel_h}
}

affine_apply :: #force_inline proc "contextless" (t: Affine, col, row: f64) -> geo.Point {
	return geo.Point{t.c + t.a * col + t.b * row, t.f + t.d * col + t.e * row}
}

// Inverse transform. `ok` is false for a degenerate (zero-determinant) affine.
affine_invert :: proc "contextless" (t: Affine) -> (inv: Affine, ok: bool) {
	det := t.a * t.e - t.b * t.d
	if abs(det) < 1e-30 {
		return {}, false
	}
	id := 1.0 / det
	ia := t.e * id
	ib := -t.b * id
	idd := -t.d * id
	ie := t.a * id
	return Affine {
			a = ia,
			b = ib,
			c = -(ia * t.c + ib * t.f),
			d = idd,
			e = ie,
			f = -(idd * t.c + ie * t.f),
		},
		true
}

Interleave :: enum u8 {
	BSQ, // band sequential: all of band 0, then all of band 1
	BIP, // band interleaved by pixel: b0 b1 b2, b0 b1 b2, ...
	BIL, // band interleaved by line
}

// A georeferenced grid. `data` holds raw samples in the source's own element
// type; nothing is widened to f64 on load, so a large source costs what it
// costs on disk rather than eight bytes a sample.
Raster :: struct {
	width, height: int,
	bands:         int,
	kind:          layers.Element_Kind,
	interleave:    Interleave,
	data:          []byte,
	transform:     Affine,
	inv_transform: Affine,
	projection:    geo.Projection, // .Geographic means `transform` yields degrees
	has_nodata:    bool,
	nodata:        f64,
	scale:         f64, // decoded = raw * scale + offset
	offset:        f64,
	name:          string,
}

raster_destroy :: proc(r: ^Raster, allocator := context.allocator) {
	delete(r.data, allocator)
	r.data = nil
}

// Finalises a freshly read raster: caches the inverse transform and applies
// defaults. Every reader calls this before returning.
raster_finish :: proc(r: ^Raster) -> bool {
	if r.scale == 0 {
		r.scale = 1
	}
	if r.bands <= 0 {
		r.bands = 1
	}
	inv, ok := affine_invert(r.transform)
	if !ok {
		return false
	}
	r.inv_transform = inv
	return len(r.data) >= r.width * r.height * r.bands * layers.element_size(r.kind)
}

@(private)
sample_offset :: #force_inline proc "contextless" (r: ^Raster, band, col, row: int) -> int {
	esz := layers.element_size(r.kind)
	switch r.interleave {
	case .BSQ:
		return ((band * r.height + row) * r.width + col) * esz
	case .BIP:
		return ((row * r.width + col) * r.bands + band) * esz
	case .BIL:
		return ((row * r.bands + band) * r.width + col) * esz
	}
	return 0
}

// Raw sample at integer pixel coordinates, decoded through scale/offset.
// `ok` is false out of bounds or on the nodata sentinel.
raster_at :: proc "contextless" (r: ^Raster, band, col, row: int) -> (value: f64, ok: bool) {
	if col < 0 || row < 0 || col >= r.width || row >= r.height || band < 0 || band >= r.bands {
		return 0, false
	}
	raw := layers.read_element(r.kind, rawptr(uintptr(raw_data(r.data)) + uintptr(sample_offset(r, band, col, row))))
	if r.has_nodata {
		if r.nodata != r.nodata {
			if raw != raw {
				return 0, false
			}
		} else if raw == r.nodata {
			return 0, false
		}
	}
	if raw != raw {
		return 0, false // an unflagged NaN is still missing data
	}
	return raw * r.scale + r.offset, true
}

// Projected coordinates of a pixel centre, in the raster's own CRS.
raster_pixel_center :: #force_inline proc "contextless" (r: ^Raster, col, row: int) -> geo.Point {
	return affine_apply(r.transform, f64(col) + 0.5, f64(row) + 0.5)
}

raster_pixel_center_ll :: proc "contextless" (r: ^Raster, col, row: int) -> geo.Lat_Lon {
	return geo.inverse(r.projection, raster_pixel_center(r, col, row))
}

// Continuous pixel coordinates of a position given in the raster's CRS.
raster_pixel_of :: #force_inline proc "contextless" (r: ^Raster, p: geo.Point) -> (col, row: f64) {
	q := affine_apply(r.inv_transform, p.x, p.y)
	return q.x, q.y
}

// Nearest-neighbour lookup by geodetic position.
raster_sample_ll :: proc "contextless" (r: ^Raster, band: int, ll: geo.Lat_Lon) -> (value: f64, ok: bool) {
	p := geo.forward(r.projection, ll)
	fc, fr := raster_pixel_of(r, p)
	return raster_at(r, band, int(math.floor(fc)), int(math.floor(fr)))
}

// Bilinear lookup by geodetic position. Falls back to nearest where a
// contributing sample is missing, so edges and nodata holes stay usable.
raster_sample_ll_linear :: proc "contextless" (r: ^Raster, band: int, ll: geo.Lat_Lon) -> (value: f64, ok: bool) {
	p := geo.forward(r.projection, ll)
	fc, fr := raster_pixel_of(r, p)
	// pixel centres sit at integer + 0.5
	x := fc - 0.5
	y := fr - 0.5
	c0 := int(math.floor(x))
	r0 := int(math.floor(y))
	tx := x - f64(c0)
	ty := y - f64(r0)

	sum, wsum := 0.0, 0.0
	for dy in 0 ..< 2 {
		for dx in 0 ..< 2 {
			v, got := raster_at(r, band, c0 + dx, r0 + dy)
			if !got {
				continue
			}
			wx := dx == 0 ? (1.0 - tx) : tx
			wy := dy == 0 ? (1.0 - ty) : ty
			w := wx * wy
			sum += v * w
			wsum += w
		}
	}
	if wsum <= 1e-9 {
		return 0, false
	}
	return sum / wsum, true
}

// Geographic extent of the raster, from its four corners. Correct for any
// north-up or rotated affine.
raster_geo_bounds :: proc "contextless" (r: ^Raster) -> geo.Geo_Bounds {
	corners := [4]geo.Point {
		affine_apply(r.transform, 0, 0),
		affine_apply(r.transform, f64(r.width), 0),
		affine_apply(r.transform, 0, f64(r.height)),
		affine_apply(r.transform, f64(r.width), f64(r.height)),
	}
	b := geo.geo_bounds_empty()
	for c in corners {
		geo.geo_bounds_add(&b, geo.inverse(r.projection, c))
	}
	return b
}

// Approximate ground resolution in metres, measured at the raster's centre.
// Used to decide whether resampling to hexes should scatter or gather.
raster_ground_resolution :: proc (r: ^Raster) -> f64 {
	cc := r.width / 2
	cr := r.height / 2
	a := raster_pixel_center_ll(r, cc, cr)
	b := raster_pixel_center_ll(r, cc + 1, cr)
	c := raster_pixel_center_ll(r, cc, cr + 1)
	dx := geo.haversine_distance(a, b)
	dy := geo.haversine_distance(a, c)
	if dx <= 0 && dy <= 0 {
		return 0
	}
	if dx <= 0 {return dy}
	if dy <= 0 {return dx}
	return math.sqrt(dx * dy)
}
