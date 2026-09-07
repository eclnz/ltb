package tiff

import "core:bytes"
import "core:compress/zlib"

/*
Package tiff is baseline TIFF decoding: directory parsing and the four
compressions that actually appear in published raster data (none, Deflate, LZW,
PackBits).

GeoTIFF adds its georeferencing on top of these structures; that part lives in
ltb:ingest. Keeping them apart means the TIFF side stays testable on ordinary
images -- this package imports nothing but core:bytes and core:compress/zlib,
so its tests build in about a second and touch no projection, no hex grid and
no window.
*/

Type :: enum u16 {
	Byte      = 1,
	Ascii     = 2,
	Short     = 3,
	Long      = 4,
	Rational  = 5,
	SByte     = 6,
	Undefined = 7,
	SShort    = 8,
	SLong     = 9,
	SRational = 10,
	Float     = 11,
	Double    = 12,
}

@(private)
type_size :: proc "contextless" (t: Type) -> int {
	switch t {
	case .Byte, .Ascii, .SByte, .Undefined:
		return 1
	case .Short, .SShort:
		return 2
	case .Long, .SLong, .Float:
		return 4
	case .Rational, .SRational, .Double:
		return 8
	}
	return 0
}

Entry :: struct {
	tag:    u16,
	type:   Type,
	count:  u32,
	offset: u32, // file offset, or the inline value when it fits in four bytes
	inline: bool,
}

Reader :: struct {
	data:    []byte,
	big_end: bool,
	entries: map[u16]Entry,
}

// Standard TIFF tags this reader understands.
TAG_IMAGE_WIDTH :: 256
TAG_IMAGE_LENGTH :: 257
TAG_BITS_PER_SAMPLE :: 258
TAG_COMPRESSION :: 259
TAG_PHOTOMETRIC :: 262
TAG_STRIP_OFFSETS :: 273
TAG_SAMPLES_PER_PIXEL :: 277
TAG_ROWS_PER_STRIP :: 278
TAG_STRIP_BYTE_COUNTS :: 279
TAG_PLANAR_CONFIG :: 284
TAG_PREDICTOR :: 317
TAG_TILE_WIDTH :: 322
TAG_TILE_LENGTH :: 323
TAG_TILE_OFFSETS :: 324
TAG_TILE_BYTE_COUNTS :: 325
TAG_SAMPLE_FORMAT :: 339

COMPRESSION_NONE :: 1
COMPRESSION_LZW :: 5
COMPRESSION_DEFLATE_ADOBE :: 8
COMPRESSION_PACKBITS :: 32773
COMPRESSION_DEFLATE :: 32946

@(private)
rd_u16 :: proc "contextless" (t: ^Reader, off: int) -> u16 {
	if off < 0 || off + 2 > len(t.data) {
		return 0
	}
	b := t.data[off:]
	return t.big_end ? (u16(b[0]) << 8 | u16(b[1])) : (u16(b[1]) << 8 | u16(b[0]))
}

@(private)
rd_u32 :: proc "contextless" (t: ^Reader, off: int) -> u32 {
	if off < 0 || off + 4 > len(t.data) {
		return 0
	}
	b := t.data[off:]
	if t.big_end {
		return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
	}
	return u32(b[3]) << 24 | u32(b[2]) << 16 | u32(b[1]) << 8 | u32(b[0])
}

@(private)
rd_f64 :: proc "contextless" (t: ^Reader, off: int) -> f64 {
	lo := rd_u32(t, t.big_end ? off + 4 : off)
	hi := rd_u32(t, t.big_end ? off : off + 4)
	return transmute(f64)(u64(hi) << 32 | u64(lo))
}

// Opens a TIFF and reads its first image file directory. Subsequent IFDs
// (overviews, masks) are ignored: the engine builds its own pyramid.
open :: proc(data: []byte, allocator := context.allocator) -> (t: Reader, ok: bool) {
	if len(data) < 8 {
		return {}, false
	}
	t.data = data
	switch {
	case data[0] == 'I' && data[1] == 'I':
		t.big_end = false
	case data[0] == 'M' && data[1] == 'M':
		t.big_end = true
	case:
		return {}, false
	}
	if rd_u16(&t, 2) != 42 {
		return {}, false // BigTIFF (43) and anything else is out of scope
	}

	ifd := int(rd_u32(&t, 4))
	n := int(rd_u16(&t, ifd))
	if n <= 0 || ifd + 2 + n * 12 > len(data) {
		return {}, false
	}
	t.entries = make(map[u16]Entry, n * 2, allocator)
	for i in 0 ..< n {
		p := ifd + 2 + i * 12
		e := Entry {
			tag   = rd_u16(&t, p),
			type  = Type(rd_u16(&t, p + 2)),
			count = rd_u32(&t, p + 4),
		}
		size := type_size(e.type) * int(e.count)
		if size <= 4 {
			e.offset = u32(p + 8)
			e.inline = true
		} else {
			e.offset = rd_u32(&t, p + 8)
		}
		t.entries[e.tag] = e
	}
	return t, true
}

close :: proc(t: ^Reader) {
	delete(t.entries)
	t.entries = nil
}

has :: proc(t: ^Reader, tag: u16) -> bool {
	_, ok := t.entries[tag]
	return ok
}

// Reads an integer-valued tag element. Returns 0 for a missing tag, which is
// what the TIFF defaults mostly want anyway.
integer :: proc(t: ^Reader, tag: u16, index := 0, default: u64 = 0) -> u64 {
	e, ok := t.entries[tag]
	if !ok || index >= int(e.count) {
		return default
	}
	base := int(e.offset) + index * type_size(e.type)
	switch e.type {
	case .Byte, .Ascii, .Undefined:
		return base < len(t.data) ? u64(t.data[base]) : default
	case .SByte:
		return base < len(t.data) ? u64(i64(i8(t.data[base]))) : default
	case .Short:
		return u64(rd_u16(t, base))
	case .SShort:
		return u64(i64(i16(rd_u16(t, base))))
	case .Long:
		return u64(rd_u32(t, base))
	case .SLong:
		return u64(i64(i32(rd_u32(t, base))))
	case .Float:
		return u64(transmute(f32)rd_u32(t, base))
	case .Double:
		return u64(rd_f64(t, base))
	case .Rational, .SRational:
		den := rd_u32(t, base + 4)
		return den == 0 ? default : u64(rd_u32(t, base) / den)
	}
	return default
}

// Collects an integer tag into a freshly allocated slice.
integers :: proc(t: ^Reader, tag: u16, allocator := context.allocator) -> []u64 {
	e, ok := t.entries[tag]
	if !ok {
		return nil
	}
	out := make([]u64, int(e.count), allocator)
	for i in 0 ..< int(e.count) {
		out[i] = integer(t, tag, i)
	}
	return out
}

doubles :: proc(t: ^Reader, tag: u16, allocator := context.allocator) -> []f64 {
	e, ok := t.entries[tag]
	if !ok || e.type != .Double {
		return nil
	}
	out := make([]f64, int(e.count), allocator)
	for i in 0 ..< int(e.count) {
		out[i] = rd_f64(t, int(e.offset) + i * 8)
	}
	return out
}

ascii :: proc(t: ^Reader, tag: u16) -> string {
	e, ok := t.entries[tag]
	if !ok || e.type != .Ascii {
		return ""
	}
	start := int(e.offset)
	n := int(e.count)
	if start < 0 || start + n > len(t.data) {
		return ""
	}
	s := string(t.data[start:start + n])
	// TIFF ASCII values are NUL-terminated.
	for i in 0 ..< len(s) {
		if s[i] == 0 {
			return s[:i]
		}
	}
	return s
}

// ---------------------------------------------------------------------------
// Decompression
// ---------------------------------------------------------------------------

decompress_block :: proc(
	compression: u64,
	src: []byte,
	expected: int,
	allocator := context.allocator,
) -> (
	out: []byte,
	ok: bool,
) {
	switch compression {
	case COMPRESSION_NONE:
		out = make([]byte, len(src), allocator)
		copy(out, src)
		return out, true
	case COMPRESSION_DEFLATE, COMPRESSION_DEFLATE_ADOBE:
		buf: bytes.Buffer
		if err := zlib.inflate_from_byte_array(src, &buf, false, expected); err != nil {
			bytes.buffer_destroy(&buf)
			return nil, false
		}
		res := bytes.buffer_to_bytes(&buf)
		out = make([]byte, len(res), allocator)
		copy(out, res)
		bytes.buffer_destroy(&buf)
		return out, true
	case COMPRESSION_PACKBITS:
		return unpack_bits(src, expected, allocator)
	case COMPRESSION_LZW:
		return lzw_decode(src, expected, allocator)
	}
	return nil, false
}

// PackBits: a simple run-length scheme, byte-oriented.
@(private)
unpack_bits :: proc(src: []byte, expected: int, allocator := context.allocator) -> (out: []byte, ok: bool) {
	dst := make([dynamic]byte, 0, max(expected, len(src) * 2), allocator)
	i := 0
	for i < len(src) {
		n := int(i8(src[i]))
		i += 1
		if n >= 0 {
			count := n + 1
			if i + count > len(src) {
				break
			}
			append(&dst, ..src[i:i + count])
			i += count
		} else if n != -128 {
			count := 1 - n
			if i >= len(src) {
				break
			}
			b := src[i]
			i += 1
			for _ in 0 ..< count {
				append(&dst, b)
			}
		}
	}
	return dst[:], len(dst) > 0
}

// TIFF's LZW variant: MSB-first codes, code 256 clears, 257 ends, and the code
// width grows one entry early relative to the GIF flavour.
@(private)
lzw_decode :: proc(src: []byte, expected: int, allocator := context.allocator) -> (out: []byte, ok: bool) {
	CLEAR :: 256
	END :: 257
	FIRST :: 258
	MAX_CODE :: 4096

	Entry :: struct {
		prev:   i32, // -1 for a root code
		length: i32,
		byte:   u8,
	}
	table := make([]Entry, MAX_CODE, context.temp_allocator)
	defer delete(table, context.temp_allocator)

	reset :: proc(table: []Entry) {
		for i in 0 ..< 256 {
			table[i] = Entry{-1, 1, u8(i)}
		}
	}
	reset(table)

	dst := make([dynamic]byte, 0, max(expected, 1024), allocator)
	scratch: [MAX_CODE]u8

	next := i32(FIRST)
	width := u32(9)
	bitpos := 0
	prev := i32(-1)
	total_bits := len(src) * 8

	emit :: proc(table: []Entry, code: i32, scratch: ^[MAX_CODE]u8, dst: ^[dynamic]byte) -> u8 {
		n := 0
		c := code
		for c >= 0 && n < MAX_CODE {
			scratch[n] = table[c].byte
			n += 1
			c = table[c].prev
		}
		for i := n - 1; i >= 0; i -= 1 {
			append(dst, scratch[i])
		}
		return n > 0 ? scratch[n - 1] : 0
	}

	for bitpos + int(width) <= total_bits {
		code := i32(0)
		for _ in 0 ..< width {
			byte_index := bitpos >> 3
			bit := 7 - u32(bitpos & 7)
			code = (code << 1) | i32((src[byte_index] >> bit) & 1)
			bitpos += 1
		}

		switch code {
		case CLEAR:
			reset(table)
			next = FIRST
			width = 9
			prev = -1
			continue
		case END:
			return dst[:], len(dst) > 0
		}

		if prev < 0 {
			if code >= 256 {
				return dst[:], false
			}
			emit(table, code, &scratch, &dst)
			prev = code
		} else {
			first: u8
			if code < next && table[code].length > 0 {
				emit(table, code, &scratch, &dst)
				// The new table entry extends `prev` by the first byte of the
				// string just emitted, so walk `code` back to its root.
				c := code
				for table[c].prev >= 0 {c = table[c].prev}
				first = table[c].byte
			} else {
				// The classic KwKwK case: the code is the one about to be added.
				c := prev
				for table[c].prev >= 0 {c = table[c].prev}
				first = table[c].byte
				emit(table, prev, &scratch, &dst)
				append(&dst, first)
			}
			if next < MAX_CODE {
				root := prev
				table[next] = Entry{root, table[prev].length + 1, first}
				next += 1
			}
			prev = code
		}

		// Early change: widen one code before the table is actually full.
		switch next {
		case 511:
			width = 10
		case 1023:
			width = 11
		case 2047:
			width = 12
		}
	}
	return dst[:], len(dst) > 0
}

// Undoes horizontal differencing (TIFF predictor 2) over one row.
undo_predictor_row :: proc(row: []byte, samples: int, bits: int) {
	if samples <= 0 {
		return
	}
	switch bits {
	case 8:
		for i in samples ..< len(row) {
			row[i] += row[i - samples]
		}
	case 16:
		n := len(row) / 2
		p := (cast([^]u16)raw_data(row))[:n]
		for i in samples ..< n {
			p[i] += p[i - samples]
		}
	case 32:
		n := len(row) / 4
		p := (cast([^]u32)raw_data(row))[:n]
		for i in samples ..< n {
			p[i] += p[i - samples]
		}
	}
}

// Byte-swaps multi-byte samples in place, for a file whose endianness differs
// from the host's.
swap_samples :: proc(buf: []byte, bytes_per_sample: int) {
	switch bytes_per_sample {
	case 2:
		n := len(buf) / 2
		p := (cast([^]u16)raw_data(buf))[:n]
		for i in 0 ..< n {
			p[i] = (p[i] >> 8) | (p[i] << 8)
		}
	case 4:
		n := len(buf) / 4
		p := (cast([^]u32)raw_data(buf))[:n]
		for i in 0 ..< n {
			v := p[i]
			p[i] = (v >> 24) | ((v >> 8) & 0x0000_FF00) | ((v << 8) & 0x00FF_0000) | (v << 24)
		}
	case 8:
		n := len(buf) / 8
		p := (cast([^]u64)raw_data(buf))[:n]
		for i in 0 ..< n {
			v := p[i]
			v = ((v & 0x00FF00FF00FF00FF) << 8) | ((v >> 8) & 0x00FF00FF00FF00FF)
			v = ((v & 0x0000FFFF0000FFFF) << 16) | ((v >> 16) & 0x0000FFFF0000FFFF)
			p[i] = (v << 32) | (v >> 32)
		}
	}
}
