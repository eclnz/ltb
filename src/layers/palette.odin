package layers

import "core:math"

// Colour ramps used to turn layer values into pixels. Kept in the layer
// descriptor so a newly registered layer is drawable without touching the
// renderer.

RGB :: [3]u8

@(private)
lerp_u8 :: proc "contextless" (a, b: u8, t: f64) -> u8 {
	return u8(clamp(f64(a) + (f64(b) - f64(a)) * t + 0.5, 0, 255))
}

@(private)
mix :: proc "contextless" (a, b: RGB, t: f64) -> RGB {
	return RGB{lerp_u8(a.r, b.r, t), lerp_u8(a.g, b.g, t), lerp_u8(a.b, b.b, t)}
}

// Samples a ramp at t in [0, 1].
palette_sample :: proc "contextless" (p: Palette, t: f64) -> RGB {
	if len(p.stops) == 0 {
		g := u8(clamp(t * 255.0, 0, 255))
		return RGB{g, g, g}
	}
	tt := clamp(t, 0, 1)
	if p.kind == .Cyclic {
		tt = t - math.floor(t)
	}
	if tt <= p.stops[0].t {
		return p.stops[0].color
	}
	last := len(p.stops) - 1
	if tt >= p.stops[last].t {
		return p.stops[last].color
	}
	for i in 0 ..< last {
		a := p.stops[i]
		b := p.stops[i + 1]
		if tt >= a.t && tt <= b.t {
			span := b.t - a.t
			f := span <= 0 ? 0.0 : (tt - a.t) / span
			return mix(a.color, b.color, f)
		}
	}
	return p.stops[last].color
}

// Colour for a decoded value of a layer, honouring its semantic.
//
// Categorical layers look the value up in `categories`; composition layers must
// be coloured with `composition_color` instead, since a single number cannot
// describe a mixture.
value_color :: proc(d: ^Layer_Desc, value: f64) -> RGB {
	switch d.semantic {
	case .Categorical:
		for c in d.categories {
			if f64(c.value) == value {
				return c.color
			}
		}
		return RGB{80, 80, 80}
	case .Boolean:
		return value != 0 ? RGB{240, 240, 240} : RGB{30, 30, 30}
	case .Scalar, .Fraction, .Composition, .Vector, .Density, .Direction:
	// handled below
	}
	span := d.max_value - d.min_value
	t := span <= 0 ? 0.0 : (value - d.min_value) / span
	return palette_sample(d.palette, t)
}

// Colour for a composition cell: the category colours of each component,
// weighted by that component's fraction.
composition_color :: proc(d: ^Layer_Desc, fractions: []f64) -> RGB {
	r, g, b, w := 0.0, 0.0, 0.0, 0.0
	n := min(len(fractions), len(d.categories))
	for i in 0 ..< n {
		f := max(0.0, fractions[i])
		c := d.categories[i].color
		r += f64(c.r) * f
		g += f64(c.g) * f
		b += f64(c.b) * f
		w += f
	}
	if w <= 1e-9 {
		return RGB{60, 60, 60}
	}
	return RGB{u8(clamp(r / w, 0, 255)), u8(clamp(g / w, 0, 255)), u8(clamp(b / w, 0, 255))}
}

// The single most abundant component of a composition cell.
dominant_component :: proc(fractions: []f64) -> (index: int, share: f64) {
	index = -1
	for f, i in fractions {
		if f > share {
			share = f
			index = i
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Standard ramps
// ---------------------------------------------------------------------------

@(rodata)
STOPS_VIRIDIS := [?]Palette_Stop {
	{0.00, {68, 1, 84}},
	{0.25, {59, 82, 139}},
	{0.50, {33, 145, 140}},
	{0.75, {94, 201, 98}},
	{1.00, {253, 231, 37}},
}

@(rodata)
STOPS_TERRAIN := [?]Palette_Stop {
	{0.00, {22, 66, 106}},
	{0.06, {66, 133, 170}},
	{0.12, {182, 199, 148}},
	{0.30, {112, 155, 84}},
	{0.55, {171, 158, 96}},
	{0.75, {135, 112, 88}},
	{0.90, {186, 180, 176}},
	{1.00, {255, 255, 255}},
}

@(rodata)
STOPS_GREENS := [?]Palette_Stop {
	{0.00, {247, 252, 245}},
	{0.35, {161, 217, 155}},
	{0.70, {49, 133, 63}},
	{1.00, {0, 63, 26}},
}

@(rodata)
STOPS_BLUES := [?]Palette_Stop {
	{0.00, {247, 251, 255}},
	{0.40, {158, 202, 225}},
	{0.75, {49, 130, 189}},
	{1.00, {8, 48, 107}},
}

@(rodata)
STOPS_HEAT := [?]Palette_Stop {
	{0.00, {26, 30, 60}},
	{0.35, {150, 60, 90}},
	{0.65, {235, 130, 45}},
	{1.00, {255, 245, 200}},
}

// Blue-white-red, for anomalies and anything with a meaningful zero.
@(rodata)
STOPS_DIVERGING := [?]Palette_Stop {
	{0.00, {33, 102, 172}},
	{0.25, {146, 197, 222}},
	{0.50, {247, 247, 247}},
	{0.75, {244, 165, 130}},
	{1.00, {178, 24, 43}},
}

// Hue wheel for directions; 0 and 1 meet seamlessly.
@(rodata)
STOPS_CYCLIC := [?]Palette_Stop {
	{0.00, {230, 90, 90}},
	{0.25, {200, 200, 80}},
	{0.50, {80, 200, 120}},
	{0.75, {90, 120, 220}},
	{1.00, {230, 90, 90}},
}

@(rodata)
STOPS_MOISTURE := [?]Palette_Stop {
	{0.00, {140, 108, 70}},
	{0.45, {200, 190, 140}},
	{1.00, {40, 110, 160}},
}

// Slices of `@(rodata)` arrays are not compile-time constants, so the named
// ramps are package variables rather than constants.
PALETTE_VIRIDIS := Palette{.Sequential, STOPS_VIRIDIS[:]}
PALETTE_TERRAIN := Palette{.Sequential, STOPS_TERRAIN[:]}
PALETTE_GREENS := Palette{.Sequential, STOPS_GREENS[:]}
PALETTE_BLUES := Palette{.Sequential, STOPS_BLUES[:]}
PALETTE_HEAT := Palette{.Sequential, STOPS_HEAT[:]}
PALETTE_DIVERGING := Palette{.Diverging, STOPS_DIVERGING[:]}
PALETTE_CYCLIC := Palette{.Cyclic, STOPS_CYCLIC[:]}
PALETTE_MOISTURE := Palette{.Sequential, STOPS_MOISTURE[:]}
PALETTE_CATEGORICAL := Palette{.Categorical, nil}
PALETTE_COMPOSITION := Palette{.Composition, nil}
