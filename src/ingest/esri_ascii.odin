package ingest

import "core:os"
import "core:strconv"
import "core:strings"
import geo "ltb:geo"
import "ltb:layers"

/*
ESRI ASCII grid (.asc / .grd).

Plain text, one header block then rows of numbers north to south. Slow and
enormous, but it is what a great deal of public elevation, climate and forestry
data is still published as, and it needs no dependencies to read.
*/

/*
Reads an ESRI ASCII grid.

The format carries no CRS at all, so `crs` is required rather than optional: a
grid published in a national projection read as degrees lands a continent away,
and there is nothing in the file to notice it by. `.Crs_Required` says so
instead of assuming lat/lon.
*/
read_esri_ascii :: proc(
	path: string,
	crs: Maybe(geo.Projection) = nil,
	allocator := context.allocator,
) -> (
	r: Raster,
	err: Ingest_Error,
) {
	projection, has_crs := crs.?
	if !has_crs {
		return {}, .Crs_Required
	}
	src, ferr := os.read_entire_file(path, context.temp_allocator)
	if ferr != nil {
		return {}, .File_Not_Found
	}
	defer delete(src, context.temp_allocator)
	return parse_esri_ascii(string(src), projection, allocator)
}

// Parses an ESRI ASCII grid already in memory.
parse_esri_ascii :: proc(
	text: string,
	projection: geo.Projection,
	allocator := context.allocator,
) -> (
	r: Raster,
	err: Ingest_Error,
) {
	ncols, nrows := -1, -1
	xll, yll := 0.0, 0.0
	xll_is_center, yll_is_center := false, false
	cell_x, cell_y := 0.0, 0.0
	nodata := -9999.0
	has_nodata := false

	rest := text
	// The header is a run of "keyword value" lines; the first line that does
	// not start with a keyword begins the data.
	header_loop: for {
		line_end := strings.index_byte(rest, '\n')
		line := line_end < 0 ? rest : rest[:line_end]
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 {
			if line_end < 0 {break}
			rest = rest[line_end + 1:]
			continue
		}
		sp := strings.index_any(trimmed, " \t")
		if sp <= 0 {
			break header_loop
		}
		key := strings.to_lower(trimmed[:sp], context.temp_allocator)
		val := strings.trim_space(trimmed[sp:])
		num, num_ok := strconv.parse_f64(val)

		switch key {
		case "ncols":
			if !num_ok {return {}, .Bad_Header}
			ncols = int(num)
		case "nrows":
			if !num_ok {return {}, .Bad_Header}
			nrows = int(num)
		case "xllcorner":
			xll = num
		case "yllcorner":
			yll = num
		case "xllcenter":
			xll = num
			xll_is_center = true
		case "yllcenter":
			yll = num
			yll_is_center = true
		case "cellsize":
			cell_x = num
			cell_y = num
		case "dx":
			cell_x = num
		case "dy":
			cell_y = num
		case "nodata_value":
			nodata = num
			has_nodata = true
		case:
			break header_loop
		}
		if line_end < 0 {
			rest = ""
			break
		}
		rest = rest[line_end + 1:]
	}

	if ncols <= 0 || nrows <= 0 || cell_x <= 0 || cell_y <= 0 {
		return {}, .Bad_Header
	}

	data := make([]byte, ncols * nrows * 4, allocator)
	vals := (cast([^]f32)raw_data(data))[:ncols * nrows]

	n := 0
	i := 0
	for n < ncols * nrows {
		// skip separators
		for i < len(rest) && (rest[i] == ' ' || rest[i] == '\t' || rest[i] == '\r' || rest[i] == '\n') {
			i += 1
		}
		if i >= len(rest) {
			break
		}
		start := i
		for i < len(rest) && rest[i] != ' ' && rest[i] != '\t' && rest[i] != '\r' && rest[i] != '\n' {
			i += 1
		}
		v, parsed := strconv.parse_f64(rest[start:i])
		if !parsed {
			delete(data, allocator)
			return {}, .Truncated
		}
		vals[n] = f32(v)
		n += 1
	}
	if n != ncols * nrows {
		delete(data, allocator)
		return {}, .Truncated
	}

	// The header gives the lower-left corner; TIFF-style affines start at the
	// upper-left, and rows run north to south.
	ox := xll_is_center ? xll - cell_x * 0.5 : xll
	oy_bottom := yll_is_center ? yll - cell_y * 0.5 : yll
	oy := oy_bottom + cell_y * f64(nrows)

	r = Raster {
		width      = ncols,
		height     = nrows,
		bands      = 1,
		kind       = .F32,
		interleave = .BSQ,
		data       = data,
		transform  = affine_north_up(ox, oy, cell_x, -cell_y),
		projection = projection,
		has_nodata = has_nodata,
		nodata     = nodata,
		scale      = 1,
		name       = "esri_ascii",
	}
	if !raster_finish(&r) {
		delete(data, allocator)
		return {}, .Bad_Header
	}
	return r, .None
}
