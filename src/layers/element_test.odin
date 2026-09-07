package layers

import "core:testing"

/*
The element table's internal agreement.

`encode_storable` narrows an integer layer's storable range by one, on the
assumption that the nodata code sits at one end of the raw range. These tests
are what makes that assumption an invariant rather than a coincidence: adding an
element type whose sentinel sits in the middle of its range fails here rather
than silently eating real values.
*/

@(test)
integer_sentinels_sit_at_a_range_end :: proc(t: ^testing.T) {
	for kind in Element_Kind {
		traits := ELEMENT_TRAITS[kind]
		if traits.nodata != traits.nodata {
			continue // float types use NaN, which costs no range
		}
		testing.expectf(
			t,
			traits.nodata == traits.lo || traits.nodata == traits.hi,
			"%v: nodata %v is neither end of [%v, %v], so encode_storable cannot exclude it",
			kind,
			traits.nodata,
			traits.lo,
			traits.hi,
		)
	}
}

@(test)
sizes_hold_their_range :: proc(t: ^testing.T) {
	for kind in Element_Kind {
		traits := ELEMENT_TRAITS[kind]
		testing.expectf(t, traits.size > 0, "%v has no size", kind)
		testing.expectf(t, traits.lo <= traits.hi, "%v has an inverted range", kind)

		#partial switch kind {
		case .F32, .F64:
			continue
		}
		// An integer type's span must fit the bytes claimed for it.
		span := traits.hi - traits.lo + 1
		testing.expectf(
			t,
			span == pow2(traits.size * 8),
			"%v claims %d bytes but spans %v values",
			kind,
			traits.size,
			span,
		)
	}
}

// A value that is storable stays storable, and one that is not is reported
// rather than wrapping.
@(test)
encode_storable_excludes_the_sentinel :: proc(t: ^testing.T) {
	d := Layer_Desc {
		kind       = .U8,
		scale      = 1,
		has_nodata = true,
		nodata_raw = 255,
	}
	raw, saturated := encode_storable(&d, 254)
	testing.expect_value(t, raw, 254.0)
	testing.expect(t, !saturated, "254 fits a u8 layer whose sentinel is 255")

	// 255 is the sentinel, so the largest storable value is one below it.
	raw, saturated = encode_storable(&d, 255)
	testing.expect_value(t, raw, 254.0)
	testing.expect(t, saturated, "255 collides with the sentinel and must report")

	raw, saturated = encode_storable(&d, 900)
	testing.expect_value(t, raw, 254.0)
	testing.expect(t, saturated, "900 does not fit a u8 and must report")
}

// A round trip through the store's raw element codecs must not change a value
// the type can hold.
@(test)
element_round_trip :: proc(t: ^testing.T) {
	buf: [8]byte
	for kind in Element_Kind {
		traits := ELEMENT_TRAITS[kind]
		for value in ([]f64{0, 1, 7}) {
			if value < traits.lo || value > traits.hi {
				continue
			}
			write_element(kind, raw_data(buf[:]), value)
			got := read_element(kind, raw_data(buf[:]))
			testing.expectf(t, got == value, "%v: wrote %v, read %v", kind, value, got)
		}
	}
}

@(private = "file")
pow2 :: proc(bits: int) -> f64 {
	out := 1.0
	for _ in 0 ..< bits {
		out *= 2
	}
	return out
}
