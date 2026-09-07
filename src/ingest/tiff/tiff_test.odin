package tiff

import "core:slice"
import "core:testing"

/*
These tests build TIFFs a byte at a time rather than reading fixtures off disk.

The decoder's job is to survive whatever a file claims about itself, and the
interesting cases -- a truncated directory, a tag pointing past the end, a
BigTIFF header, mixed endianness -- are all easier to write than to find in
published data.
*/

// ---------------------------------------------------------------------------
// A minimal TIFF builder
// ---------------------------------------------------------------------------

Tag :: struct {
	tag:    u16,
	type:   Type,
	count:  u32,
	// Values small enough to sit in the entry's four value bytes; anything
	// longer is appended after the directory and referenced by offset.
	values: []u64,
	// Raw payload for Ascii and Double tags, appended verbatim.
	blob:   []byte,
}

@(private = "file")
put_u16 :: proc(b: ^[dynamic]byte, v: u16, big: bool) {
	if big {
		append(b, u8(v >> 8), u8(v))
	} else {
		append(b, u8(v), u8(v >> 8))
	}
}

@(private = "file")
put_u32 :: proc(b: ^[dynamic]byte, v: u32, big: bool) {
	if big {
		append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
	} else {
		append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
}

// Assembles a one-IFD TIFF. The directory sits at offset 8 and any out-of-line
// payload follows it.
@(private = "file")
build :: proc(tags: []Tag, big: bool, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, 0, 512, allocator)

	append(&out, big ? u8('M') : u8('I'), big ? u8('M') : u8('I'))
	put_u16(&out, 42, big)
	put_u32(&out, 8, big)

	// Payload lands after the directory and its four trailing next-IFD bytes.
	heap_at := 8 + 2 + len(tags) * 12 + 4
	heap := make([dynamic]byte, 0, 256, context.temp_allocator)

	put_u16(&out, u16(len(tags)), big)
	for t in tags {
		put_u16(&out, t.tag, big)
		put_u16(&out, u16(t.type), big)
		put_u32(&out, t.count, big)

		size := type_size(t.type) * int(t.count)
		field := make([dynamic]byte, 0, 8, context.temp_allocator)
		if len(t.blob) > 0 {
			append(&field, ..t.blob)
		} else {
			for v in t.values {
				switch t.type {
				case .Byte, .Ascii, .SByte, .Undefined:
					append(&field, u8(v))
				case .Short, .SShort:
					put_u16(&field, u16(v), big)
				case .Long, .SLong, .Float:
					put_u32(&field, u32(v), big)
				case .Rational, .SRational, .Double:
					put_u32(&field, u32(v), big)
					put_u32(&field, 1, big)
				}
			}
		}

		if size <= 4 {
			// Inline, left-aligned in the four value bytes.
			for len(field) < 4 {
				append(&field, 0)
			}
			append(&out, ..field[:4])
		} else {
			put_u32(&out, u32(heap_at + len(heap)), big)
			append(&heap, ..field[:])
		}
	}
	put_u32(&out, 0, big) // no next IFD
	append(&out, ..heap[:])
	return out[:]
}

// ---------------------------------------------------------------------------
// Header handling
// ---------------------------------------------------------------------------

@(test)
test_open_rejects_what_is_not_a_tiff :: proc(t: ^testing.T) {
	_, ok := open({})
	testing.expect(t, !ok, "an empty buffer opened as a TIFF")

	_, ok = open({'I', 'I', 42, 0})
	testing.expect(t, !ok, "a four-byte buffer opened as a TIFF")

	// Right length, wrong byte-order mark.
	bad := []byte{'X', 'Y', 42, 0, 8, 0, 0, 0, 0, 0}
	_, ok = open(bad)
	testing.expect(t, !ok, "an unknown byte-order mark was accepted")
}

@(test)
test_open_rejects_bigtiff :: proc(t: ^testing.T) {
	// Version 43 is BigTIFF, which uses 8-byte offsets throughout. Reading it
	// as classic TIFF would produce plausible nonsense, so it is refused.
	buf := []byte{'I', 'I', 43, 0, 8, 0, 0, 0, 1, 0}
	_, ok := open(buf)
	testing.expect(t, !ok, "BigTIFF was accepted as classic TIFF")
}

@(test)
test_open_rejects_a_directory_running_past_the_end :: proc(t: ^testing.T) {
	// Claims 500 entries in a ten-byte file.
	buf := []byte{'I', 'I', 42, 0, 8, 0, 0, 0, 0xF4, 0x01}
	_, ok := open(buf)
	testing.expect(t, !ok, "a directory larger than the file was accepted")
}

@(test)
test_both_byte_orders_read_the_same_values :: proc(t: ^testing.T) {
	tags := []Tag {
		{tag = TAG_IMAGE_WIDTH, type = .Short, count = 1, values = {640}},
		{tag = TAG_IMAGE_LENGTH, type = .Long, count = 1, values = {480}},
	}
	for big in ([]bool{false, true}) {
		buf := build(tags, big, context.temp_allocator)
		r, ok := open(buf, context.temp_allocator)
		testing.expectf(t, ok, "big_end=%v did not open", big)
		defer close(&r)

		testing.expect_value(t, r.big_end, big)
		testing.expect_value(t, integer(&r, TAG_IMAGE_WIDTH), u64(640))
		testing.expect_value(t, integer(&r, TAG_IMAGE_LENGTH), u64(480))
	}
	free_all(context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Tag reads
// ---------------------------------------------------------------------------

@(test)
test_missing_tag_returns_the_spec_default :: proc(t: ^testing.T) {
	buf := build({{tag = TAG_IMAGE_WIDTH, type = .Short, count = 1, values = {8}}}, false, context.temp_allocator)
	r, ok := open(buf, context.temp_allocator)
	testing.expect(t, ok)
	defer close(&r)
	defer free_all(context.temp_allocator)

	testing.expect(t, has(&r, TAG_IMAGE_WIDTH))
	testing.expect(t, !has(&r, TAG_COMPRESSION), "a tag that was never written is present")

	// The default here is the TIFF specification's own -- an absent
	// Compression tag means uncompressed, an absent SamplesPerPixel means one.
	// It is the format's rule, not error recovery.
	testing.expect_value(t, integer(&r, TAG_COMPRESSION, 0, COMPRESSION_NONE), u64(COMPRESSION_NONE))
	testing.expect_value(t, integer(&r, TAG_SAMPLES_PER_PIXEL, 0, 1), u64(1))
}

@(test)
test_index_past_the_count_returns_the_default :: proc(t: ^testing.T) {
	buf := build({{tag = TAG_BITS_PER_SAMPLE, type = .Short, count = 2, values = {16, 16}}}, false, context.temp_allocator)
	r, ok := open(buf, context.temp_allocator)
	testing.expect(t, ok)
	defer close(&r)
	defer free_all(context.temp_allocator)

	testing.expect_value(t, integer(&r, TAG_BITS_PER_SAMPLE, 0), u64(16))
	testing.expect_value(t, integer(&r, TAG_BITS_PER_SAMPLE, 1), u64(16))
	// A third band on a two-band tag: the caller's default, not a read past
	// the end of the entry.
	testing.expect_value(t, integer(&r, TAG_BITS_PER_SAMPLE, 2, 99), u64(99))
}

@(test)
test_out_of_line_values_are_followed :: proc(t: ^testing.T) {
	// Four LONGs are sixteen bytes, so the entry holds an offset rather than
	// the values themselves -- the path that a corrupt offset would break.
	buf := build(
		{{tag = TAG_STRIP_OFFSETS, type = .Long, count = 4, values = {100, 200, 300, 400}}},
		false,
		context.temp_allocator,
	)
	r, ok := open(buf, context.temp_allocator)
	testing.expect(t, ok)
	defer close(&r)
	defer free_all(context.temp_allocator)

	got := integers(&r, TAG_STRIP_OFFSETS, context.temp_allocator)
	testing.expect(t, slice.equal(got, []u64{100, 200, 300, 400}), "out-of-line LONGs were not read back")

	// A tag that is not there yields nothing to iterate, not a zero-filled
	// slice that would look like four strips at offset zero.
	testing.expect_value(t, len(integers(&r, TAG_TILE_OFFSETS, context.temp_allocator)), 0)
}

@(test)
test_ascii_stops_at_the_terminator :: proc(t: ^testing.T) {
	// TIFF ASCII is NUL-terminated and the count includes the NUL.
	blob := []byte{'-', '9', '9', '9', '9', 0}
	buf := build(
		{{tag = TAG_GDAL_NODATA_FOR_TEST, type = .Ascii, count = u32(len(blob)), blob = blob}},
		false,
		context.temp_allocator,
	)
	r, ok := open(buf, context.temp_allocator)
	testing.expect(t, ok)
	defer close(&r)
	defer free_all(context.temp_allocator)

	testing.expect_value(t, ascii(&r, TAG_GDAL_NODATA_FOR_TEST), "-9999")
	// A non-Ascii tag read as text is empty rather than reinterpreted bytes.
	testing.expect_value(t, ascii(&r, TAG_IMAGE_WIDTH), "")
}

// GDAL's nodata tag, declared here because it belongs to the GeoTIFF layer
// rather than to baseline TIFF.
@(private = "file")
TAG_GDAL_NODATA_FOR_TEST :: 42113

// ---------------------------------------------------------------------------
// Decompression
// ---------------------------------------------------------------------------

@(test)
test_uncompressed_block_round_trips :: proc(t: ^testing.T) {
	src := []byte{1, 2, 3, 4, 5}
	out, ok := decompress_block(COMPRESSION_NONE, src, len(src), context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(out, src), "an uncompressed block came back changed")
}

@(test)
test_packbits_decodes_the_reference_stream :: proc(t: ^testing.T) {
	// The worked example from the TIFF 6.0 specification, which exercises both
	// run and literal opcodes and the negative-length encoding.
	src := []byte{0xFE, 0xAA, 0x02, 0x80, 0x00, 0x2A, 0xFD, 0xAA, 0x03, 0x80, 0x00, 0x2A, 0x22, 0xF7, 0xAA}
	want := []byte {
		0xAA, 0xAA, 0xAA,
		0x80, 0x00, 0x2A,
		0xAA, 0xAA, 0xAA, 0xAA,
		0x80, 0x00, 0x2A, 0x22,
		0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA,
	}
	out, ok := decompress_block(COMPRESSION_PACKBITS, src, len(want), context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(out), len(want))
	testing.expect(t, slice.equal(out, want), "PackBits did not match the reference stream")
}

@(test)
test_unknown_compression_fails_rather_than_returning_the_bytes :: proc(t: ^testing.T) {
	// JPEG-in-TIFF (7) is not implemented. Handing back the raw bytes would
	// render as noise that looks like data.
	out, ok := decompress_block(7, {1, 2, 3, 4}, 4, context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect(t, !ok, "an unsupported compression reported success")
	testing.expect_value(t, len(out), 0)
}

// ---------------------------------------------------------------------------
// Sample fixups
// ---------------------------------------------------------------------------

@(test)
test_predictor_undoes_horizontal_differencing :: proc(t: ^testing.T) {
	// One band, 8-bit: each byte is a delta from the one before it.
	row := []byte{10, 5, 250, 1}
	undo_predictor_row(row, 1, 8)
	// 10, 15, then 15+250 wraps to 9, then 9+1.
	testing.expect(t, slice.equal(row, []byte{10, 15, 9, 10}), "8-bit predictor 2 did not accumulate")

	// Three interleaved bands: each accumulates against the same band three
	// bytes back, never against its neighbour.
	rgb := []byte{100, 50, 25, 1, 2, 3}
	undo_predictor_row(rgb, 3, 8)
	testing.expect(t, slice.equal(rgb, []byte{100, 50, 25, 101, 52, 28}), "banded predictor crossed bands")
}

@(test)
test_predictor_leaves_the_row_alone_for_unsupported_depths :: proc(t: ^testing.T) {
	// A zero sample count would index backwards from the start of the row.
	row := []byte{1, 2, 3}
	undo_predictor_row(row, 0, 8)
	testing.expect(t, slice.equal(row, []byte{1, 2, 3}), "a zero sample count modified the row")
}

@(test)
test_swap_samples_reverses_byte_order :: proc(t: ^testing.T) {
	two := []byte{0x12, 0x34, 0xAB, 0xCD}
	swap_samples(two, 2)
	testing.expect(t, slice.equal(two, []byte{0x34, 0x12, 0xCD, 0xAB}), "16-bit swap")

	four := []byte{0x01, 0x02, 0x03, 0x04}
	swap_samples(four, 4)
	testing.expect(t, slice.equal(four, []byte{0x04, 0x03, 0x02, 0x01}), "32-bit swap")

	eight := []byte{1, 2, 3, 4, 5, 6, 7, 8}
	swap_samples(eight, 8)
	testing.expect(t, slice.equal(eight, []byte{8, 7, 6, 5, 4, 3, 2, 1}), "64-bit swap")

	// Swapping twice is the identity, which is the property that matters when
	// a file's endianness matches the host's after all.
	again := []byte{0x12, 0x34, 0xAB, 0xCD}
	swap_samples(again, 2)
	swap_samples(again, 2)
	testing.expect(t, slice.equal(again, []byte{0x12, 0x34, 0xAB, 0xCD}), "swap is not an involution")
}
