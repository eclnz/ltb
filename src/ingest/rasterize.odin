package ingest

import "core:math"
import geo "ltb:geo"
import hex "ltb:hex"
import "ltb:layers"
import "ltb:world"

// How source samples are mapped onto cells.
Resample :: enum u8 {
	// Pick by comparing the source's ground resolution to the cell pitch.
	Auto,
	// Walk the source pixels and combine everything that lands in a cell.
	// Correct when the source is finer than the grid, which is the usual case
	// for a 10-30 m raster on a 100 m-1 km grid.
	Scatter,
	// Walk the cells and read the source at each cell centre. Correct when the
	// source is coarser than the grid, where scattering would leave holes.
	Gather_Nearest,
	Gather_Linear,
}

Options :: struct {
	// Pyramid level to write. Data normally lands at level 0 and the coarser
	// levels are derived from it.
	level:        int,
	// Source band for each component; nil means band i for component i.
	bands:        []int,
	resample:     Resample,
	// Overrides the layer's own aggregate rule for this ingest. `.None` keeps
	// the layer's rule.
	rule:         layers.Aggregate,
	// Applied to source values before they are stored: decoded = v*scale + offset.
	value_scale:  f64,
	value_offset: f64,
	// After scattering, fill cells that no pixel landed in by sampling the
	// source at the cell centre. Costs a second pass; worth it near the edges
	// of a source whose resolution is close to the cell pitch.
	fill_gaps:    bool,
	// Restricts the write to these cells. Defaults to the source's own extent.
	limit:        Maybe(hex.Bounds),
	// Safety valve for a mis-georeferenced source that would otherwise ask for
	// billions of cells. Zero uses `DEFAULT_MAX_CELLS`.
	max_cells:    int,
}

DEFAULT_MAX_CELLS :: 40_000_000

Result :: struct {
	cells_written:  int,
	samples_used:   int,
	samples_missing: int,
	resample_used:  Resample,
	gap_filled:     int,
}

Error :: enum {
	None,
	Unknown_Layer,
	Too_Many_Cells,
	Bad_Raster,
	Component_Mismatch,
}

@(private)
sample_point :: proc "contextless" (r: ^Raster, band: int, ll: geo.Lat_Lon, linear: bool) -> (f64, bool) {
	if linear {
		return raster_sample_ll_linear(r, band, ll)
	}
	return raster_sample_ll(r, band, ll)
}

// Resamples `r` onto `w`'s hex grid and writes it into `layer`.
rasterize :: proc(
	w: ^world.World,
	r: ^Raster,
	layer: layers.Layer_Id,
	opts := Options{},
) -> (
	res: Result,
	err: Error,
) {
	d := layers.desc_of(w.registry, layer)
	if d == nil {
		return {}, .Unknown_Layer
	}
	if r.width <= 0 || r.height <= 0 || len(r.data) == 0 {
		return {}, .Bad_Raster
	}

	o := opts
	if o.value_scale == 0 {
		o.value_scale = 1
	}
	if o.max_cells == 0 {
		o.max_cells = DEFAULT_MAX_CELLS
	}
	rule := o.rule == .None ? d.aggregate : o.rule
	if rule == .None {
		rule = layers.default_aggregate(d.semantic)
	}

	nc := layers.desc_components(d)
	if nc > layers.MAX_ACCUM_COMPONENTS {
		return {}, .Component_Mismatch
	}
	band_of: [layers.MAX_ACCUM_COMPONENTS]int
	for i in 0 ..< nc {
		band_of[i] = i < len(o.bands) ? o.bands[i] : i
		if band_of[i] >= r.bands {
			band_of[i] = r.bands - 1
		}
	}

	bounds := o.limit.? or_else world.bounds_for_geo(w, o.level, raster_geo_bounds(r))
	if hex.bounds_count(bounds) > o.max_cells {
		return {}, .Too_Many_Cells
	}

	mode := o.resample
	if mode == .Auto {
		src_res := raster_ground_resolution(r)
		pitch := world.level_resolution(w, o.level)
		if src_res > 0 && src_res <= pitch {
			mode = .Scatter
		} else {
			mode = d.interp == .Nearest ? .Gather_Nearest : .Gather_Linear
		}
	}
	res.resample_used = mode

	// Skip the geodetic round trip when the two frames are literally the same
	// projection; on a country-sized ingest that is a lot of transcendentals.
	same_frame := r.projection == w.projection

	if mode == .Scatter {
		a: layers.Accumulator
		layers.accum_init(&a, d, rule, context.temp_allocator)
		defer layers.accum_destroy(&a)

		values: [layers.MAX_ACCUM_COMPONENTS]f64
		lay := world.layout(w, o.level)

		for row in 0 ..< r.height {
			for col in 0 ..< r.width {
				any_data := false
				for i in 0 ..< nc {
					v, ok := raster_at(r, band_of[i], col, row)
					values[i] = ok ? v * o.value_scale + o.value_offset : 0
					any_data ||= ok
				}
				if !any_data {
					res.samples_missing += 1
					continue
				}
				p := raster_pixel_center(r, col, row)
				wp := same_frame ? p : geo.forward(w.projection, geo.inverse(r.projection, p))
				h := hex.world_to_hex(lay, wp)
				if !hex.bounds_contains(bounds, h) {
					continue
				}
				layers.accum_add(&a, h, values[:nc])
				res.samples_used += 1
			}
		}
		res.cells_written = layers.accum_flush(&a, w.store, layer, u8(o.level))

		if o.fill_gaps {
			res.gap_filled = fill_gaps_from_raster(w, r, layer, d, bounds, o, band_of[:nc], &a)
			res.cells_written += res.gap_filled
		}
		return res, .None
	}

	// Gather
	linear := mode == .Gather_Linear && d.interp == .Linear
	values: [layers.MAX_ACCUM_COMPONENTS]f64
	for rr in bounds.r0 ..= bounds.r1 {
		for qq in bounds.q0 ..= bounds.q1 {
			h := hex.Hex{qq, rr}
			ll := world.cell_center_ll(w, o.level, h)
			any_data := false
			for i in 0 ..< nc {
				v, ok := sample_point(r, band_of[i], ll, linear)
				values[i] = ok ? v * o.value_scale + o.value_offset : 0
				any_data ||= ok
			}
			if !any_data {
				res.samples_missing += 1
				continue
			}
			if nc == 1 {
				layers.set(w.store, layer, u8(o.level), h, values[0])
			} else {
				layers.set_components(w.store, layer, u8(o.level), h, values[:nc])
			}
			res.cells_written += 1
			res.samples_used += 1
		}
	}
	return res, .None
}

@(private)
fill_gaps_from_raster :: proc(
	w: ^world.World,
	r: ^Raster,
	layer: layers.Layer_Id,
	d: ^layers.Layer_Desc,
	bounds: hex.Bounds,
	o: Options,
	band_of: []int,
	a: ^layers.Accumulator,
) -> (
	filled: int,
) {
	nc := len(band_of)
	values: [layers.MAX_ACCUM_COMPONENTS]f64
	linear := d.interp == .Linear
	for rr in bounds.r0 ..= bounds.r1 {
		for qq in bounds.q0 ..= bounds.q1 {
			h := hex.Hex{qq, rr}
			if layers.accum_has(a, h) {
				continue
			}
			ll := world.cell_center_ll(w, o.level, h)
			any_data := false
			for i in 0 ..< nc {
				v, ok := sample_point(r, band_of[i], ll, linear)
				values[i] = ok ? v * o.value_scale + o.value_offset : 0
				any_data ||= ok
			}
			if !any_data {
				continue
			}
			if nc == 1 {
				layers.set(w.store, layer, u8(o.level), h, values[0])
			} else {
				layers.set_components(w.store, layer, u8(o.level), h, values[:nc])
			}
			filled += 1
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Derived layers
// ---------------------------------------------------------------------------

// Computes slope and aspect from an elevation layer using the six hex
// neighbours: a plane is fitted through the neighbouring cell centres by least
// squares, which on a hex grid is both cheaper and less directionally biased
// than the usual 3x3 square kernel.
derive_slope_aspect :: proc(
	w: ^world.World,
	elevation, slope, aspect: layers.Layer_Id,
	level := 0,
	bounds: Maybe(hex.Bounds) = nil,
) -> (
	cells: int,
) {
	lay := world.layout(w, level)
	region := bounds.? or_else world.extent(w, level)
	center := hex.to_world(lay, hex.Hex{0, 0})

	// Neighbour offsets in world space are the same for every cell, so the
	// normal equations are built once.
	offs: [6][2]f64
	for dir in 0 ..< 6 {
		p := hex.to_world(lay, hex.DIRECTIONS[dir])
		offs[dir] = {p.x - center.x, p.y - center.y}
	}
	sxx, sxy, syy := 0.0, 0.0, 0.0
	for dir in 0 ..< 6 {
		sxx += offs[dir].x * offs[dir].x
		sxy += offs[dir].x * offs[dir].y
		syy += offs[dir].y * offs[dir].y
	}
	det := sxx * syy - sxy * sxy
	if abs(det) < 1e-12 {
		return 0
	}

	for rr in region.r0 ..= region.r1 {
		for qq in region.q0 ..= region.q1 {
			h := hex.Hex{qq, rr}
			z0, ok := layers.get(w.store, elevation, u8(level), h)
			if !ok {
				continue
			}
			sxz, syz := 0.0, 0.0
			n := 0
			for dir in 0 ..< 6 {
				zn, got := layers.get(w.store, elevation, u8(level), hex.neighbor(h, hex.Direction(dir)))
				if !got {
					continue
				}
				dz := zn - z0
				sxz += offs[dir].x * dz
				syz += offs[dir].y * dz
				n += 1
			}
			if n < 3 {
				continue
			}
			// Solve [sxx sxy; sxy syy] [gx gy]^T = [sxz syz]^T
			gx := (syy * sxz - sxy * syz) / det
			gy := (sxx * syz - sxy * sxz) / det

			grade := math.sqrt(gx * gx + gy * gy)
			layers.set(w.store, slope, u8(level), h, math.atan(grade) * 180.0 / math.PI)

			// Aspect is the compass bearing of steepest descent. World +y is
			// north in every projection the engine uses.
			if grade > 1e-9 {
				bearing := math.atan2(-gx, -gy) * 180.0 / math.PI
				if bearing < 0 {
					bearing += 360.0
				}
				layers.set(w.store, aspect, u8(level), h, bearing)
			} else {
				layers.set(w.store, aspect, u8(level), h, 0)
			}
			cells += 1
		}
	}
	return
}

// Standard Lambert hillshade from slope and aspect, cached into a layer so the
// renderer does not recompute it per frame.
derive_hillshade :: proc(
	w: ^world.World,
	slope, aspect, hillshade: layers.Layer_Id,
	level := 0,
	sun_azimuth := 315.0,
	sun_altitude := 45.0,
	bounds: Maybe(hex.Bounds) = nil,
) -> (
	cells: int,
) {
	region := bounds.? or_else world.extent(w, level)
	za := (90.0 - sun_altitude) * math.PI / 180.0
	az := sun_azimuth * math.PI / 180.0
	for rr in region.r0 ..= region.r1 {
		for qq in region.q0 ..= region.q1 {
			h := hex.Hex{qq, rr}
			s, ok := layers.get(w.store, slope, u8(level), h)
			if !ok {
				continue
			}
			a := layers.get_or(w.store, aspect, u8(level), h, 0) * math.PI / 180.0
			sr := s * math.PI / 180.0
			v := math.cos(za) * math.cos(sr) + math.sin(za) * math.sin(sr) * math.cos(az - a)
			layers.set(w.store, hillshade, u8(level), h, clamp(v, 0, 1))
			cells += 1
		}
	}
	return
}
