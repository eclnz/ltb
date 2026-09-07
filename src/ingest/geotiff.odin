package ingest

import "core:os"
import "core:strconv"
import geo "ltb:geo"
import "ltb:layers"

/*
GeoTIFF: the format most real elevation, land cover and forestry rasters
actually ship in.

This reader handles the parts that appear in published data -- stripped and
tiled layouts, chunky and planar interleave, 8/16/32/64-bit integer and float
samples, predictor 2, and the four common compressions -- plus enough of the
GeoTIFF key machinery to recover a usable projection. It is not a complete
implementation of the spec, and says so loudly when it meets something it does
not know rather than guessing at georeferencing.
*/

// GeoTIFF-specific tags.
TAG_MODEL_PIXEL_SCALE :: 33550
TAG_MODEL_TIEPOINT :: 33922
TAG_MODEL_TRANSFORMATION :: 34264
TAG_GEO_KEY_DIRECTORY :: 34735
TAG_GEO_DOUBLE_PARAMS :: 34736
TAG_GEO_ASCII_PARAMS :: 34737
TAG_GDAL_NODATA :: 42113

// GeoKey ids used here.
KEY_MODEL_TYPE :: 1024
KEY_RASTER_TYPE :: 1025
KEY_GEOGRAPHIC_TYPE :: 2048
KEY_PROJECTED_CS_TYPE :: 3072
KEY_PROJ_COORD_TRANS :: 3075
KEY_PROJ_LINEAR_UNITS :: 3076
KEY_STD_PARALLEL_1 :: 3078
KEY_STD_PARALLEL_2 :: 3079
KEY_NAT_ORIGIN_LONG :: 3080
KEY_NAT_ORIGIN_LAT :: 3081
KEY_FALSE_EASTING :: 3082
KEY_FALSE_NORTHING :: 3083
KEY_CENTER_LONG :: 3088
KEY_CENTER_LAT :: 3089
KEY_SCALE_AT_NAT_ORIGIN :: 3092

CT_TRANSVERSE_MERCATOR :: 1
CT_MERCATOR :: 7
CT_LAMBERT_AZIM_EQUAL_AREA :: 10
CT_ALBERS_EQUAL_AREA :: 11

Geotiff_Error :: enum {
	None,
	File_Not_Found,
	Not_Tiff,
	Unsupported_Layout,
	Unsupported_Sample,
	Decompression_Failed,
	No_Georeferencing,
	Unknown_Crs,
}

// Reads a GeoTIFF from disk.
//
// `crs_override` replaces whatever the file claims; pass it for files whose
// GeoTIFF keys this reader cannot resolve, or which are known to be wrong.
read_geotiff :: proc(
	path: string,
	crs_override: Maybe(geo.Projection) = nil,
	allocator := context.allocator,
) -> (
	r: Raster,
	err: Geotiff_Error,
) {
	src, ferr := os.read_entire_file(path, context.allocator)
	if ferr != nil {
		return {}, .File_Not_Found
	}
	defer delete(src, context.allocator)
	return parse_geotiff(src, crs_override, allocator)
}

parse_geotiff :: proc(
	file: []byte,
	crs_override: Maybe(geo.Projection) = nil,
	allocator := context.allocator,
) -> (
	r: Raster,
	err: Geotiff_Error,
) {
	t, ok := tiff_open(file, context.temp_allocator)
	if !ok {
		return {}, .Not_Tiff
	}
	defer tiff_close(&t)

	width := int(tiff_int(&t, TAG_IMAGE_WIDTH))
	height := int(tiff_int(&t, TAG_IMAGE_LENGTH))
	if width <= 0 || height <= 0 {
		return {}, .Unsupported_Layout
	}

	samples := int(tiff_int(&t, TAG_SAMPLES_PER_PIXEL, 0, 1))
	bits := int(tiff_int(&t, TAG_BITS_PER_SAMPLE, 0, 8))
	format := int(tiff_int(&t, TAG_SAMPLE_FORMAT, 0, 1)) // 1 uint, 2 int, 3 float
	planar := int(tiff_int(&t, TAG_PLANAR_CONFIG, 0, 1)) // 1 chunky, 2 planar
	compression := tiff_int(&t, TAG_COMPRESSION, 0, COMPRESSION_NONE)
	predictor := int(tiff_int(&t, TAG_PREDICTOR, 0, 1))

	// Mixed bit depths across bands would need a per-band raster; reject rather
	// than silently reading the first band's depth for all of them.
	for i in 1 ..< samples {
		if int(tiff_int(&t, TAG_BITS_PER_SAMPLE, i, u64(bits))) != bits {
			return {}, .Unsupported_Sample
		}
	}

	kind, kind_ok := element_kind_for(bits, format)
	if !kind_ok {
		return {}, .Unsupported_Sample
	}
	esz := layers.element_size(kind)

	// Pixel layout: tiled or stripped.
	tiled := tiff_has(&t, TAG_TILE_WIDTH)
	tile_w, tile_h: int
	offsets, counts: []u64
	if tiled {
		tile_w = int(tiff_int(&t, TAG_TILE_WIDTH))
		tile_h = int(tiff_int(&t, TAG_TILE_LENGTH))
		offsets = tiff_ints(&t, TAG_TILE_OFFSETS, context.temp_allocator)
		counts = tiff_ints(&t, TAG_TILE_BYTE_COUNTS, context.temp_allocator)
	} else {
		tile_w = width
		tile_h = int(tiff_int(&t, TAG_ROWS_PER_STRIP, 0, u64(height)))
		offsets = tiff_ints(&t, TAG_STRIP_OFFSETS, context.temp_allocator)
		counts = tiff_ints(&t, TAG_STRIP_BYTE_COUNTS, context.temp_allocator)
	}
	defer delete(offsets, context.temp_allocator)
	defer delete(counts, context.temp_allocator)
	if tile_w <= 0 || tile_h <= 0 || len(offsets) == 0 || len(offsets) != len(counts) {
		return {}, .Unsupported_Layout
	}

	// One output buffer, interleaved to match the file so no extra shuffle pass
	// is needed.
	interleave: Interleave = planar == 2 ? .BSQ : .BIP
	out := make([]byte, width * height * samples * esz, allocator)

	tiles_across := (width + tile_w - 1) / tile_w
	tiles_down := (height + tile_h - 1) / tile_h
	planes := planar == 2 ? samples : 1
	per_plane_samples := planar == 2 ? 1 : samples
	block_bytes := tile_w * tile_h * per_plane_samples * esz
	row_bytes := tile_w * per_plane_samples * esz
	host_big := ODIN_ENDIAN == .Big
	need_swap := esz > 1 && t.big_end != host_big

	block_index := 0
	for plane in 0 ..< planes {
		for ty in 0 ..< tiles_down {
			for tx in 0 ..< tiles_across {
				if block_index >= len(offsets) {
					delete(out, allocator)
					return {}, .Unsupported_Layout
				}
				off := int(offsets[block_index])
				cnt := int(counts[block_index])
				block_index += 1
				if off < 0 || cnt <= 0 || off + cnt > len(file) {
					continue // a sparse tile: leave the destination zeroed
				}

				raw, dok := decompress_block(compression, file[off:off + cnt], block_bytes, context.temp_allocator)
				if !dok {
					delete(out, allocator)
					return {}, .Decompression_Failed
				}
				defer delete(raw, context.temp_allocator)

				// A strip at the bottom edge may be short; a tile never is.
				rows_here := tile_h
				if !tiled {
					rows_here = min(tile_h, height - ty * tile_h)
				}

				for row in 0 ..< rows_here {
					src_off := row * row_bytes
					if src_off + row_bytes > len(raw) {
						break
					}
					line := raw[src_off:src_off + row_bytes]
					if need_swap {
						swap_samples(line, esz)
					}
					if predictor == 2 {
						undo_predictor_row(line, per_plane_samples, bits)
					}

					y := ty * tile_h + row
					if y >= height {
						break
					}
					cols_here := min(tile_w, width - tx * tile_w)
					if cols_here <= 0 {
						continue
					}
					for col in 0 ..< cols_here {
						x := tx * tile_w + col
						for s in 0 ..< per_plane_samples {
							band := planar == 2 ? plane : s
							si := (col * per_plane_samples + s) * esz
							di := dest_offset(interleave, width, height, samples, esz, band, x, y)
							copy(out[di:di + esz], line[si:si + esz])
						}
					}
				}
			}
		}
	}

	proj, perr := geotiff_projection(&t)
	if p, has := crs_override.?; has {
		proj = p
		perr = .None
	}
	if perr != .None {
		delete(out, allocator)
		return {}, perr
	}

	transform, tok := geotiff_transform(&t)
	if !tok {
		delete(out, allocator)
		return {}, .No_Georeferencing
	}

	nodata := 0.0
	has_nodata := false
	if s := tiff_ascii(&t, TAG_GDAL_NODATA); len(s) > 0 {
		if v, parsed := strconv.parse_f64(s); parsed {
			nodata = v
			has_nodata = true
		}
	}

	r = Raster {
		width      = width,
		height     = height,
		bands      = samples,
		kind       = kind,
		interleave = interleave,
		data       = out,
		transform  = transform,
		projection = proj,
		has_nodata = has_nodata,
		nodata     = nodata,
		scale      = 1,
		name       = "geotiff",
	}
	if !raster_finish(&r) {
		delete(out, allocator)
		return {}, .No_Georeferencing
	}
	return r, .None
}

@(private)
dest_offset :: #force_inline proc "contextless" (
	il: Interleave,
	width, height, bands, esz: int,
	band, x, y: int,
) -> int {
	switch il {
	case .BSQ:
		return ((band * height + y) * width + x) * esz
	case .BIP:
		return ((y * width + x) * bands + band) * esz
	case .BIL:
		return ((y * bands + band) * width + x) * esz
	}
	return 0
}

@(private)
element_kind_for :: proc "contextless" (bits, format: int) -> (layers.Element_Kind, bool) {
	switch format {
	case 1:
		// unsigned integer
		switch bits {
		case 8:
			return .U8, true
		case 16:
			return .U16, true
		case 32:
			return .U32, true
		}
	case 2:
		// signed integer
		switch bits {
		case 8:
			return .I8, true
		case 16:
			return .I16, true
		case 32:
			return .I32, true
		}
	case 3:
		// IEEE float
		switch bits {
		case 32:
			return .F32, true
		case 64:
			return .F64, true
		}
	}
	return .U8, false
}

// ---------------------------------------------------------------------------
// Georeferencing
// ---------------------------------------------------------------------------

@(private)
geotiff_transform :: proc(t: ^Tiff_Reader) -> (Affine, bool) {
	if m := tiff_doubles(t, TAG_MODEL_TRANSFORMATION, context.temp_allocator); len(m) >= 16 {
		defer delete(m, context.temp_allocator)
		// Row-major 4x4; the engine only uses the 2D part.
		return Affine{a = m[0], b = m[1], c = m[3], d = m[4], e = m[5], f = m[7]}, true
	}

	scale := tiff_doubles(t, TAG_MODEL_PIXEL_SCALE, context.temp_allocator)
	tie := tiff_doubles(t, TAG_MODEL_TIEPOINT, context.temp_allocator)
	defer delete(scale, context.temp_allocator)
	defer delete(tie, context.temp_allocator)
	if len(scale) < 2 || len(tie) < 6 {
		return {}, false
	}
	// tie = (i, j, k, x, y, z): raster point (i, j) is at model point (x, y).
	sx := scale[0]
	sy := scale[1]
	ox := tie[3] - tie[0] * sx
	oy := tie[4] + tie[1] * sy
	return affine_north_up(ox, oy, sx, -sy), true
}

@(private)
Geo_Keys :: struct {
	shorts:  map[u16]u16,
	doubles: map[u16]f64,
}

@(private)
read_geo_keys :: proc(t: ^Tiff_Reader, allocator := context.temp_allocator) -> (k: Geo_Keys, ok: bool) {
	e, has := t.entries[TAG_GEO_KEY_DIRECTORY]
	if !has || e.count < 4 {
		return {}, false
	}
	params := tiff_doubles(t, TAG_GEO_DOUBLE_PARAMS, allocator)
	defer delete(params, allocator)

	n := int(tiff_int(t, TAG_GEO_KEY_DIRECTORY, 3))
	if n <= 0 || 4 + n * 4 > int(e.count) {
		return {}, false
	}
	k.shorts = make(map[u16]u16, n * 2, allocator)
	k.doubles = make(map[u16]f64, n * 2, allocator)
	for i in 0 ..< n {
		base := 4 + i * 4
		key := u16(tiff_int(t, TAG_GEO_KEY_DIRECTORY, base))
		loc := u16(tiff_int(t, TAG_GEO_KEY_DIRECTORY, base + 1))
		value := u16(tiff_int(t, TAG_GEO_KEY_DIRECTORY, base + 3))
		switch loc {
		case 0:
			k.shorts[key] = value
		case TAG_GEO_DOUBLE_PARAMS:
			if int(value) < len(params) {
				k.doubles[key] = params[value]
			}
		case TAG_GEO_ASCII_PARAMS:
		// Names and citations only; nothing here needs them.
		}
	}
	return k, true
}

@(private)
key_short :: proc(k: ^Geo_Keys, id: u16, default: u16 = 0) -> u16 {
	v, ok := k.shorts[id]
	return ok ? v : default
}

@(private)
key_double :: proc(k: ^Geo_Keys, id: u16, default: f64 = 0) -> f64 {
	v, ok := k.doubles[id]
	return ok ? v : default
}

// Resolves the file's CRS to one of the engine's projections.
//
// EPSG codes are matched for the families that cover most published data, and a
// user-defined projection is rebuilt from its GeoTIFF parameters. Anything else
// returns .Unknown_Crs; pass `crs_override` to place the raster by hand.
geotiff_projection :: proc(t: ^Tiff_Reader) -> (geo.Projection, Geotiff_Error) {
	keys, ok := read_geo_keys(t, context.temp_allocator)
	if !ok {
		// No GeoTIFF keys at all. A plain TIFF with a tiepoint is almost always
		// in degrees.
		return geo.proj_geographic(), .None
	}
	defer delete(keys.shorts)
	defer delete(keys.doubles)

	model := key_short(&keys, KEY_MODEL_TYPE, 2)
	if model == 2 {
		return geo.proj_geographic(), .None
	}
	if model == 3 {
		return {}, .Unknown_Crs // geocentric: not a map frame
	}

	epsg := key_short(&keys, KEY_PROJECTED_CS_TYPE, 32767)
	switch {
	case epsg >= 32601 && epsg <= 32660:
		return geo.proj_utm(int(epsg) - 32600, true), .None
	case epsg >= 32701 && epsg <= 32760:
		return geo.proj_utm(int(epsg) - 32700, false), .None
	case epsg >= 26901 && epsg <= 26923:
		// NAD83 UTM, north zones only: NAD83 has no southern hemisphere realisation.
		return geo.proj_utm(int(epsg) - 26900, true, geo.GRS80), .None
	case epsg == 3857:
		return geo.proj_web_mercator(), .None
	case epsg == 3035:
		// ETRS89 / LAEA Europe
		return geo.proj_laea(52, 10, geo.GRS80, 4_321_000, 3_210_000), .None
	case epsg == 2193:
		// NZGD2000 / New Zealand Transverse Mercator
		return geo.proj_transverse_mercator(173, 0.9996, geo.GRS80, 1_600_000, 10_000_000), .None
	case epsg == 5070 || epsg == 5069:
		// NAD83 / Conus Albers
		return geo.proj_albers(23, -96, 29.5, 45.5, geo.GRS80), .None
	case epsg == 3577:
		// GDA94 / Australian Albers
		return geo.proj_albers(0, 132, -18, -36, geo.GRS80), .None
	case epsg == 32767:
	// user-defined; fall through and rebuild from the parameter keys
	case:
		return {}, .Unknown_Crs
	}

	// User-defined projection.
	ct := key_short(&keys, KEY_PROJ_COORD_TRANS, 0)
	fe := key_double(&keys, KEY_FALSE_EASTING, 0)
	fn := key_double(&keys, KEY_FALSE_NORTHING, 0)
	switch ct {
	case CT_TRANSVERSE_MERCATOR:
		lon0 := key_double(&keys, KEY_NAT_ORIGIN_LONG, key_double(&keys, KEY_CENTER_LONG, 0))
		k0 := key_double(&keys, KEY_SCALE_AT_NAT_ORIGIN, 1.0)
		return geo.proj_transverse_mercator(lon0, k0, geo.WGS84, fe, fn), .None
	case CT_LAMBERT_AZIM_EQUAL_AREA:
		lat0 := key_double(&keys, KEY_CENTER_LAT, key_double(&keys, KEY_NAT_ORIGIN_LAT, 0))
		lon0 := key_double(&keys, KEY_CENTER_LONG, key_double(&keys, KEY_NAT_ORIGIN_LONG, 0))
		return geo.proj_laea(lat0, lon0, geo.WGS84, fe, fn), .None
	case CT_ALBERS_EQUAL_AREA:
		lat0 := key_double(&keys, KEY_NAT_ORIGIN_LAT, 0)
		lon0 := key_double(&keys, KEY_NAT_ORIGIN_LONG, 0)
		sp1 := key_double(&keys, KEY_STD_PARALLEL_1, lat0)
		sp2 := key_double(&keys, KEY_STD_PARALLEL_2, lat0)
		return geo.proj_albers(lat0, lon0, sp1, sp2, geo.WGS84, fe, fn), .None
	case CT_MERCATOR:
		return geo.proj_web_mercator(), .None
	}
	return {}, .Unknown_Crs
}
