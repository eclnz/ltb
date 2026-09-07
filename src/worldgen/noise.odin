/*
Package worldgen fills a world with a plausible landscape when there is no real
data to hand.

Terrain drives climate, terrain and climate drive soil and vegetation, and the
hydrology comes from routing water downhill across the hex graph. Ingesting real
rasters replaces the inputs to that chain, not its structure.
*/
package worldgen

import "core:math"

// Classic Perlin gradient noise on a square lattice, seeded deterministically
// so a world regenerates identically from its seed.
Noise :: struct {
	perm: [512]u8,
}

noise_init :: proc(n: ^Noise, seed: u64) {
	for i in 0 ..< 256 {
		n.perm[i] = u8(i)
	}
	// xorshift64*, so the shuffle depends on the whole seed rather than its
	// low bits.
	state := seed | 1
	next :: proc(s: ^u64) -> u64 {
		x := s^
		x ~= x >> 12
		x ~= x << 25
		x ~= x >> 27
		s^ = x
		return x * 0x2545F4914F6CDD1D
	}
	for i := 255; i > 0; i -= 1 {
		j := int(next(&state) % u64(i + 1))
		n.perm[i], n.perm[j] = n.perm[j], n.perm[i]
	}
	for i in 0 ..< 256 {
		n.perm[256 + i] = n.perm[i]
	}
}

@(private)
fade :: #force_inline proc "contextless" (t: f64) -> f64 {
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

@(private)
grad2 :: #force_inline proc "contextless" (h: u8, x, y: f64) -> f64 {
	switch h & 7 {
	case 0:
		return x + y
	case 1:
		return -x + y
	case 2:
		return x - y
	case 3:
		return -x - y
	case 4:
		return x
	case 5:
		return -x
	case 6:
		return y
	}
	return -y
}

// Value in roughly [-1, 1].
noise2 :: proc "contextless" (n: ^Noise, x, y: f64) -> f64 {
	xi := int(math.floor(x))
	yi := int(math.floor(y))
	xf := x - f64(xi)
	yf := y - f64(yi)
	u := fade(xf)
	v := fade(yf)

	X := u8(xi & 255)
	Y := u8(yi & 255)
	aa := n.perm[int(n.perm[int(X)]) + int(Y)]
	ab := n.perm[int(n.perm[int(X)]) + int(Y) + 1]
	ba := n.perm[int(n.perm[int(X) + 1]) + int(Y)]
	bb := n.perm[int(n.perm[int(X) + 1]) + int(Y) + 1]

	lerp :: #force_inline proc "contextless" (a, b, t: f64) -> f64 {
		return a + (b - a) * t
	}
	x1 := lerp(grad2(aa, xf, yf), grad2(ba, xf - 1, yf), u)
	x2 := lerp(grad2(ab, xf, yf - 1), grad2(bb, xf - 1, yf - 1), u)
	return lerp(x1, x2, v) * 1.4
}

// Fractal Brownian motion: octaves of `noise2` at doubling frequency and
// halving amplitude.
fbm :: proc "contextless" (n: ^Noise, x, y: f64, octaves: int, lacunarity := 2.0, gain := 0.5) -> f64 {
	sum, amp, freq, norm := 0.0, 1.0, 1.0, 0.0
	for _ in 0 ..< octaves {
		sum += noise2(n, x * freq, y * freq) * amp
		norm += amp
		amp *= gain
		freq *= lacunarity
	}
	return norm > 0 ? sum / norm : 0
}

// Ridged multifractal, which produces mountain ranges rather than rolling
// hills. Values are in [0, 1].
ridged :: proc "contextless" (n: ^Noise, x, y: f64, octaves: int, lacunarity := 2.0, gain := 0.5) -> f64 {
	sum, amp, freq, norm := 0.0, 1.0, 1.0, 0.0
	for _ in 0 ..< octaves {
		v := 1.0 - abs(noise2(n, x * freq, y * freq))
		sum += v * v * amp
		norm += amp
		amp *= gain
		freq *= lacunarity
	}
	return norm > 0 ? sum / norm : 0
}
