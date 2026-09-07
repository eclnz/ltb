/*
Package geo provides the geodetic layer: reference ellipsoids, map projections
and distance computations.

The simulation works in projected metres, not in degrees. Everything that comes
in from a real-world data source is projected into the world's reference
projection exactly once, at ingest time, so the rest of the engine only ever
deals with a single flat metric coordinate system.
*/
package geo

import "core:math"

// Geodetic position in degrees, with an optional ellipsoidal height in metres.
Lat_Lon :: struct {
	lat, lon: f64,
	height:   f64,
}

lat_lon :: proc "contextless" (lat, lon: f64) -> Lat_Lon {
	return Lat_Lon{lat = lat, lon = lon}
}

// Axis-aligned geographic box. `lon_min` may exceed `lon_max` for boxes that
// cross the antimeridian.
Geo_Bounds :: struct {
	lat_min, lon_min: f64,
	lat_max, lon_max: f64,
}

geo_bounds_center :: proc "contextless" (b: Geo_Bounds) -> Lat_Lon {
	lon_span := b.lon_max - b.lon_min
	if lon_span < 0 {
		lon_span += 360.0
	}
	return lat_lon((b.lat_min + b.lat_max) * 0.5, wrap_longitude(b.lon_min + lon_span * 0.5))
}

geo_bounds_contains :: proc "contextless" (b: Geo_Bounds, p: Lat_Lon) -> bool {
	if p.lat < b.lat_min || p.lat > b.lat_max {
		return false
	}
	if b.lon_min <= b.lon_max {
		return p.lon >= b.lon_min && p.lon <= b.lon_max
	}
	// crosses the antimeridian
	return p.lon >= b.lon_min || p.lon <= b.lon_max
}

// Normalises a longitude into [-180, 180).
wrap_longitude :: proc "contextless" (lon: f64) -> f64 {
	x := math.mod(lon + 180.0, 360.0)
	if x < 0 {
		x += 360.0
	}
	return x - 180.0
}

// ---------------------------------------------------------------------------
// Reference ellipsoids
// ---------------------------------------------------------------------------

// A reference ellipsoid, given by its semi-major axis and flattening. Derived
// quantities are computed on demand so the definitions stay compile-time
// constants.
Ellipsoid :: struct {
	a: f64, // semi-major axis, metres
	f: f64, // flattening
}

WGS84 :: Ellipsoid{a = 6378137.0, f = 1.0 / 298.257223563}
GRS80 :: Ellipsoid{a = 6378137.0, f = 1.0 / 298.257222101}
SPHERE_R6371 :: Ellipsoid{a = 6371008.8, f = 0.0} // authalic-ish mean sphere

// First eccentricity squared.
ecc_sq :: #force_inline proc "contextless" (el: Ellipsoid) -> f64 {
	return el.f * (2.0 - el.f)
}

ecc :: #force_inline proc "contextless" (el: Ellipsoid) -> f64 {
	return math.sqrt(ecc_sq(el))
}

// Semi-minor axis.
semi_minor :: #force_inline proc "contextless" (el: Ellipsoid) -> f64 {
	return el.a * (1.0 - el.f)
}

// Radius of the sphere with the same surface area as the ellipsoid, R_q in
// Snyder's notation. Defined via the authalic area function so the equal-area
// projections and this radius stay consistent by construction.
authalic_radius :: proc "contextless" (el: Ellipsoid) -> f64 {
	return el.a * math.sqrt(authalic_q(el, 1.0) * 0.5)
}

// Snyder's authalic area function q(phi); q(pi/2) scaled by a^2 gives the
// ellipsoid's surface area over 2*pi.
authalic_q :: proc "contextless" (el: Ellipsoid, sin_phi: f64) -> f64 {
	e2 := ecc_sq(el)
	if e2 <= 1e-15 {
		return 2.0 * sin_phi
	}
	e := math.sqrt(e2)
	es := e * sin_phi
	return (1.0 - e2) * (sin_phi / (1.0 - es * es) - (1.0 / (2.0 * e)) * math.ln((1.0 - es) / (1.0 + es)))
}

// Inverse of `authalic_q`: recovers geodetic latitude from the authalic
// latitude beta, using Snyder's series (accurate to well under a micrometre
// for terrestrial eccentricities).
authalic_to_geodetic :: proc "contextless" (el: Ellipsoid, beta: f64) -> f64 {
	e2 := ecc_sq(el)
	if e2 <= 1e-15 {
		return beta
	}
	e4 := e2 * e2
	e6 := e4 * e2
	return(
		beta +
		(e2 / 3.0 + 31.0 * e4 / 180.0 + 517.0 * e6 / 5040.0) * math.sin(2.0 * beta) +
		(23.0 * e4 / 360.0 + 251.0 * e6 / 3780.0) * math.sin(4.0 * beta) +
		(761.0 * e6 / 45360.0) * math.sin(6.0 * beta) \
	)
}

// Snyder's m(phi) = cos(phi) / sqrt(1 - e^2 sin^2 phi), the parallel radius
// scale used by the conic projections.
parallel_m :: proc "contextless" (el: Ellipsoid, phi: f64) -> f64 {
	e2 := ecc_sq(el)
	s := math.sin(phi)
	return math.cos(phi) / math.sqrt(1.0 - e2 * s * s)
}

// Radius of curvature in the prime vertical.
radius_prime_vertical :: proc "contextless" (el: Ellipsoid, phi: f64) -> f64 {
	e2 := ecc_sq(el)
	s := math.sin(phi)
	return el.a / math.sqrt(1.0 - e2 * s * s)
}

// ---------------------------------------------------------------------------
// Distances
// ---------------------------------------------------------------------------

DEG :: math.PI / 180.0
RAD :: 180.0 / math.PI

// Great-circle distance on the mean sphere. Fast, ~0.5% error against the
// ellipsoid; good enough for gameplay ranges, not for survey work.
haversine_distance :: proc "contextless" (a, b: Lat_Lon, radius := 6371008.8) -> f64 {
	p1 := a.lat * DEG
	p2 := b.lat * DEG
	dp := (b.lat - a.lat) * DEG
	dl := (b.lon - a.lon) * DEG
	s1 := math.sin(dp * 0.5)
	s2 := math.sin(dl * 0.5)
	h := s1 * s1 + math.cos(p1) * math.cos(p2) * s2 * s2
	return 2.0 * radius * math.asin(math.sqrt(math.min(1.0, h)))
}

// Vincenty inverse solution: geodesic distance and forward azimuth on the
// ellipsoid. `ok` is false for near-antipodal pairs, where the iteration does
// not converge; fall back to `haversine_distance` there.
geodesic_distance :: proc "contextless" (el: Ellipsoid, p1, p2: Lat_Lon) -> (distance: f64, azimuth: f64, ok: bool) {
	a := el.a
	f := el.f
	b := semi_minor(el)

	L := (p2.lon - p1.lon) * DEG
	U1 := math.atan((1.0 - f) * math.tan(p1.lat * DEG))
	U2 := math.atan((1.0 - f) * math.tan(p2.lat * DEG))
	sin_u1, cos_u1 := math.sin(U1), math.cos(U1)
	sin_u2, cos_u2 := math.sin(U2), math.cos(U2)

	lambda := L
	sin_sigma, cos_sigma, sigma, sin_alpha, cos_sq_alpha, cos_2sigma_m: f64

	for _ in 0 ..< 200 {
		sin_lambda, cos_lambda := math.sin(lambda), math.cos(lambda)
		sin_sigma = math.sqrt(
			(cos_u2 * sin_lambda) * (cos_u2 * sin_lambda) +
			(cos_u1 * sin_u2 - sin_u1 * cos_u2 * cos_lambda) * (cos_u1 * sin_u2 - sin_u1 * cos_u2 * cos_lambda),
		)
		if sin_sigma == 0 {
			return 0, 0, true // coincident points
		}
		cos_sigma = sin_u1 * sin_u2 + cos_u1 * cos_u2 * cos_lambda
		sigma = math.atan2(sin_sigma, cos_sigma)
		sin_alpha = cos_u1 * cos_u2 * sin_lambda / sin_sigma
		cos_sq_alpha = 1.0 - sin_alpha * sin_alpha
		cos_2sigma_m = 0.0
		if cos_sq_alpha != 0 {
			cos_2sigma_m = cos_sigma - 2.0 * sin_u1 * sin_u2 / cos_sq_alpha
		}
		C := f / 16.0 * cos_sq_alpha * (4.0 + f * (4.0 - 3.0 * cos_sq_alpha))
		prev := lambda
		lambda =
			L +
			(1.0 - C) *
				f *
				sin_alpha *
				(sigma +
						C *
							sin_sigma *
							(cos_2sigma_m + C * cos_sigma * (-1.0 + 2.0 * cos_2sigma_m * cos_2sigma_m)))
		if abs(lambda - prev) < 1e-12 {
			u_sq := cos_sq_alpha * (a * a - b * b) / (b * b)
			A := 1.0 + u_sq / 16384.0 * (4096.0 + u_sq * (-768.0 + u_sq * (320.0 - 175.0 * u_sq)))
			B := u_sq / 1024.0 * (256.0 + u_sq * (-128.0 + u_sq * (74.0 - 47.0 * u_sq)))
			d_sigma :=
				B *
				sin_sigma *
				(cos_2sigma_m +
						B /
							4.0 *
							(cos_sigma * (-1.0 + 2.0 * cos_2sigma_m * cos_2sigma_m) -
									B /
										6.0 *
										cos_2sigma_m *
										(-3.0 + 4.0 * sin_sigma * sin_sigma) *
										(-3.0 + 4.0 * cos_2sigma_m * cos_2sigma_m)))
			sin_lambda2, cos_lambda2 := math.sin(lambda), math.cos(lambda)
			az := math.atan2(cos_u2 * sin_lambda2, cos_u1 * sin_u2 - sin_u1 * cos_u2 * cos_lambda2)
			return b * A * (sigma - d_sigma), az * RAD, true
		}
	}
	return 0, 0, false
}
