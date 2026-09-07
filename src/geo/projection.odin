package geo

import "core:math"

// The projections the engine can read data in, and can use as a world
// reference frame.
//
// An equal-area projection keeps every hex covering the same amount of real
// ground, so per-cell densities are comparable across the map. Lambert Azimuthal
// Equal Area is the default world frame.
Projection_Kind :: enum u8 {
	Geographic,          // pass-through degrees; x = lon, y = lat
	Equirectangular,     // plate carree with a true-scale parallel
	Web_Mercator,        // EPSG:3857, spherical; conformal, badly non-equal-area
	Lambert_Azimuthal,   // LAEA, equal-area, best for a single region
	Albers,              // equal-area conic, best for wide east-west regions
	Transverse_Mercator, // UTM and national grids; conformal
}

// A configured projection. Construct with the `proj_*` helpers, which
// precompute the derived constants held in the tail of the struct.
Projection :: struct {
	kind:            Projection_Kind,
	ellipsoid:       Ellipsoid,
	lat0, lon0:      f64, // origin / central meridian, radians
	lat1, lat2:      f64, // standard parallels, radians
	k0:              f64, // scale factor on the central meridian
	false_easting:   f64,
	false_northing:  f64,

	// derived
	_qp:             f64, // authalic q at the pole
	_rq:             f64, // authalic radius
	_beta0:          f64, // authalic latitude of the origin
	_d:              f64, // LAEA oblique-aspect axis ratio
	_n, _c, _rho0:   f64, // Albers cone constants
}

proj_geographic :: proc "contextless" () -> Projection {
	return Projection{kind = .Geographic, ellipsoid = WGS84, k0 = 1}
}

proj_equirectangular :: proc "contextless" (lat_ts: f64, lon0: f64 = 0, el := WGS84) -> Projection {
	return Projection {
		kind = .Equirectangular,
		ellipsoid = el,
		lat0 = lat_ts * DEG,
		lon0 = lon0 * DEG,
		k0 = 1,
	}
}

proj_web_mercator :: proc "contextless" () -> Projection {
	// EPSG:3857 is defined on a sphere of the WGS84 semi-major axis.
	return Projection{kind = .Web_Mercator, ellipsoid = WGS84, k0 = 1}
}

// Lambert Azimuthal Equal Area centred on (lat0, lon0). This is the recommended
// world frame: exact equal area, and distortion stays small out to a few
// hundred kilometres from the centre.
proj_laea :: proc "contextless" (lat0, lon0: f64, el := WGS84, false_easting: f64 = 0, false_northing: f64 = 0) -> Projection {
	p := Projection {
		kind           = .Lambert_Azimuthal,
		ellipsoid      = el,
		lat0           = lat0 * DEG,
		lon0           = lon0 * DEG,
		k0             = 1,
		false_easting  = false_easting,
		false_northing = false_northing,
	}
	p._qp = authalic_q(el, 1.0)
	p._rq = el.a * math.sqrt(p._qp * 0.5)
	q0 := authalic_q(el, math.sin(p.lat0))
	p._beta0 = math.asin(clamp(q0 / p._qp, -1, 1))
	e2 := ecc_sq(el)
	s0 := math.sin(p.lat0)
	m0 := math.cos(p.lat0) / math.sqrt(1.0 - e2 * s0 * s0)
	cb0 := math.cos(p._beta0)
	if cb0 < 1e-12 {
		p._d = 1.0 // polar aspect; D is unused there
	} else {
		p._d = el.a * m0 / (p._rq * cb0)
	}
	return p
}

// Albers Equal Area Conic with two standard parallels.
proj_albers :: proc "contextless" (lat0, lon0, lat1, lat2: f64, el := WGS84, false_easting: f64 = 0, false_northing: f64 = 0) -> Projection {
	p := Projection {
		kind           = .Albers,
		ellipsoid      = el,
		lat0           = lat0 * DEG,
		lon0           = lon0 * DEG,
		lat1           = lat1 * DEG,
		lat2           = lat2 * DEG,
		k0             = 1,
		false_easting  = false_easting,
		false_northing = false_northing,
	}
	m1 := parallel_m(el, p.lat1)
	m2 := parallel_m(el, p.lat2)
	q1 := authalic_q(el, math.sin(p.lat1))
	q2 := authalic_q(el, math.sin(p.lat2))
	q0 := authalic_q(el, math.sin(p.lat0))
	p._qp = authalic_q(el, 1.0)

	if abs(p.lat1 - p.lat2) < 1e-12 {
		p._n = math.sin(p.lat1)
	} else {
		p._n = (m1 * m1 - m2 * m2) / (q2 - q1)
	}
	p._c = m1 * m1 + p._n * q1
	p._rho0 = el.a * math.sqrt(math.max(0, p._c - p._n * q0)) / p._n
	return p
}

// Transverse Mercator. `proj_utm` derives the standard UTM parameters for a
// zone; use `proj_utm_for` to pick the zone from a longitude.
proj_transverse_mercator :: proc "contextless" (lon0: f64, k0: f64 = 0.9996, el := WGS84, false_easting: f64 = 500_000, false_northing: f64 = 0) -> Projection {
	return Projection {
		kind = .Transverse_Mercator,
		ellipsoid = el,
		lon0 = lon0 * DEG,
		k0 = k0,
		false_easting = false_easting,
		false_northing = false_northing,
	}
}

proj_utm :: proc "contextless" (zone: int, northern: bool, el := WGS84) -> Projection {
	lon0 := f64(zone) * 6.0 - 183.0
	return proj_transverse_mercator(lon0, 0.9996, el, 500_000, northern ? 0 : 10_000_000)
}

utm_zone_for :: proc "contextless" (lon: f64) -> int {
	l := wrap_longitude(lon)
	z := int(math.floor((l + 180.0) / 6.0)) + 1
	return clamp(z, 1, 60)
}

proj_utm_for :: proc "contextless" (p: Lat_Lon, el := WGS84) -> Projection {
	return proj_utm(utm_zone_for(p.lon), p.lat >= 0, el)
}

// ---------------------------------------------------------------------------
// Forward / inverse
// ---------------------------------------------------------------------------

Point :: [2]f64 // projected coordinates, metres (degrees for .Geographic)

// Projects a geodetic position to the projection's plane.
forward :: proc "contextless" (p: Projection, ll: Lat_Lon) -> Point {
	switch p.kind {
	case .Geographic:
		return Point{ll.lon, ll.lat}
	case .Equirectangular:
		return _equirect_fwd(p, ll)
	case .Web_Mercator:
		return _webmerc_fwd(p, ll)
	case .Lambert_Azimuthal:
		return _laea_fwd(p, ll)
	case .Albers:
		return _albers_fwd(p, ll)
	case .Transverse_Mercator:
		return _tm_fwd(p, ll)
	}
	return Point{0, 0}
}

// Recovers a geodetic position from projected coordinates.
inverse :: proc "contextless" (p: Projection, pt: Point) -> Lat_Lon {
	switch p.kind {
	case .Geographic:
		return lat_lon(pt.y, pt.x)
	case .Equirectangular:
		return _equirect_inv(p, pt)
	case .Web_Mercator:
		return _webmerc_inv(p, pt)
	case .Lambert_Azimuthal:
		return _laea_inv(p, pt)
	case .Albers:
		return _albers_inv(p, pt)
	case .Transverse_Mercator:
		return _tm_inv(p, pt)
	}
	return Lat_Lon{}
}

// Re-expresses a point from one projection in another, via geodetic coordinates.
reproject :: proc "contextless" (from, to: Projection, pt: Point) -> Point {
	return forward(to, inverse(from, pt))
}

// True where one projected square metre is one square metre of ground
// everywhere on the map.
is_equal_area :: proc "contextless" (p: Projection) -> bool {
	return p.kind == .Lambert_Azimuthal || p.kind == .Albers
}

// ---------------------------------------------------------------------------

@(private)
_equirect_fwd :: proc "contextless" (p: Projection, ll: Lat_Lon) -> Point {
	r := p.ellipsoid.a
	dlon := wrap_longitude(ll.lon) * DEG - p.lon0
	if dlon > math.PI {dlon -= 2 * math.PI}
	if dlon < -math.PI {dlon += 2 * math.PI}
	return Point{r * dlon * math.cos(p.lat0) + p.false_easting, r * ll.lat * DEG + p.false_northing}
}

@(private)
_equirect_inv :: proc "contextless" (p: Projection, pt: Point) -> Lat_Lon {
	r := p.ellipsoid.a
	lon := ((pt.x - p.false_easting) / (r * math.cos(p.lat0)) + p.lon0) * RAD
	lat := (pt.y - p.false_northing) / r * RAD
	return lat_lon(lat, wrap_longitude(lon))
}

@(private)
_webmerc_fwd :: proc "contextless" (p: Projection, ll: Lat_Lon) -> Point {
	r := p.ellipsoid.a
	lat := clamp(ll.lat, -85.051129, 85.051129) * DEG
	return Point{r * wrap_longitude(ll.lon) * DEG, r * math.ln(math.tan(math.PI / 4.0 + lat / 2.0))}
}

@(private)
_webmerc_inv :: proc "contextless" (p: Projection, pt: Point) -> Lat_Lon {
	r := p.ellipsoid.a
	lon := pt.x / r * RAD
	lat := (2.0 * math.atan(math.exp(pt.y / r)) - math.PI / 2.0) * RAD
	return lat_lon(lat, wrap_longitude(lon))
}

// Snyder, Map Projections -- A Working Manual, eqs. 24-13..24-20 (oblique
// ellipsoidal Lambert Azimuthal Equal Area).
@(private)
_laea_fwd :: proc "contextless" (p: Projection, ll: Lat_Lon) -> Point {
	phi := clamp(ll.lat, -90, 90) * DEG
	dlon := wrap_longitude(ll.lon) * DEG - p.lon0
	if dlon > math.PI {dlon -= 2 * math.PI}
	if dlon < -math.PI {dlon += 2 * math.PI}

	q := authalic_q(p.ellipsoid, math.sin(phi))
	beta := math.asin(clamp(q / p._qp, -1, 1))
	cb, sb := math.cos(beta), math.sin(beta)
	cb0, sb0 := math.cos(p._beta0), math.sin(p._beta0)
	cl := math.cos(dlon)

	denom := 1.0 + sb0 * sb + cb0 * cb * cl
	if denom < 1e-14 {
		// exact antipode of the projection centre: undefined, clamp to the rim
		denom = 1e-14
	}
	B := p._rq * math.sqrt(2.0 / denom)

	x := B * p._d * cb * math.sin(dlon)
	y := (B / p._d) * (cb0 * sb - sb0 * cb * cl)
	return Point{x + p.false_easting, y + p.false_northing}
}

@(private)
_laea_inv :: proc "contextless" (p: Projection, pt: Point) -> Lat_Lon {
	x := (pt.x - p.false_easting) / p._d
	y := (pt.y - p.false_northing) * p._d
	rho := math.sqrt(x * x + y * y)
	if rho < 1e-12 {
		return lat_lon(p.lat0 * RAD, wrap_longitude(p.lon0 * RAD))
	}
	ce := 2.0 * math.asin(clamp(rho / (2.0 * p._rq), -1, 1))
	sc, cc := math.sin(ce), math.cos(ce)
	cb0, sb0 := math.cos(p._beta0), math.sin(p._beta0)

	beta := math.asin(clamp(cc * sb0 + (y * sc * cb0 / rho), -1, 1))
	lon := p.lon0 + math.atan2(x * sc, rho * cb0 * cc - y * sb0 * sc)
	phi := authalic_to_geodetic(p.ellipsoid, beta)
	return lat_lon(phi * RAD, wrap_longitude(lon * RAD))
}

// Snyder eqs. 14-1..14-4 (ellipsoidal Albers Equal Area Conic).
@(private)
_albers_fwd :: proc "contextless" (p: Projection, ll: Lat_Lon) -> Point {
	phi := clamp(ll.lat, -90, 90) * DEG
	dlon := wrap_longitude(ll.lon) * DEG - p.lon0
	if dlon > math.PI {dlon -= 2 * math.PI}
	if dlon < -math.PI {dlon += 2 * math.PI}

	q := authalic_q(p.ellipsoid, math.sin(phi))
	rho := p.ellipsoid.a * math.sqrt(math.max(0, p._c - p._n * q)) / p._n
	theta := p._n * dlon
	return Point {
		rho * math.sin(theta) + p.false_easting,
		p._rho0 - rho * math.cos(theta) + p.false_northing,
	}
}

@(private)
_albers_inv :: proc "contextless" (p: Projection, pt: Point) -> Lat_Lon {
	x := pt.x - p.false_easting
	y := p._rho0 - (pt.y - p.false_northing)
	sign := p._n < 0 ? -1.0 : 1.0
	rho := math.sqrt(x * x + y * y) * sign
	theta := math.atan2(x * sign, y * sign)

	a := p.ellipsoid.a
	q := (p._c - (rho * rho * p._n * p._n) / (a * a)) / p._n
	beta := math.asin(clamp(q / p._qp, -1, 1))
	phi := authalic_to_geodetic(p.ellipsoid, beta)
	lon := p.lon0 + theta / p._n
	return lat_lon(phi * RAD, wrap_longitude(lon * RAD))
}

// Snyder eqs. 8-9..8-12 / 8-17..8-25 (ellipsoidal Transverse Mercator). Accurate
// to a few millimetres within about 4 degrees of the central meridian, which
// covers a UTM zone with margin.
@(private)
_tm_fwd :: proc "contextless" (p: Projection, ll: Lat_Lon) -> Point {
	el := p.ellipsoid
	e2 := ecc_sq(el)
	ep2 := e2 / (1.0 - e2)

	phi := clamp(ll.lat, -90, 90) * DEG
	dlon := wrap_longitude(ll.lon) * DEG - p.lon0
	if dlon > math.PI {dlon -= 2 * math.PI}
	if dlon < -math.PI {dlon += 2 * math.PI}

	sp, cp := math.sin(phi), math.cos(phi)
	tp := sp / cp
	N := el.a / math.sqrt(1.0 - e2 * sp * sp)
	T := tp * tp
	C := ep2 * cp * cp
	A := dlon * cp
	M := _meridian_arc(el, phi)

	a2 := A * A
	x :=
		p.k0 *
		N *
		(A +
				(1.0 - T + C) * a2 * A / 6.0 +
				(5.0 - 18.0 * T + T * T + 72.0 * C - 58.0 * ep2) * a2 * a2 * A / 120.0)
	y :=
		p.k0 *
		(M +
				N *
					tp *
					(a2 / 2.0 +
							(5.0 - T + 9.0 * C + 4.0 * C * C) * a2 * a2 / 24.0 +
							(61.0 - 58.0 * T + T * T + 600.0 * C - 330.0 * ep2) * a2 * a2 * a2 / 720.0))
	return Point{x + p.false_easting, y + p.false_northing}
}

@(private)
_tm_inv :: proc "contextless" (p: Projection, pt: Point) -> Lat_Lon {
	el := p.ellipsoid
	e2 := ecc_sq(el)
	ep2 := e2 / (1.0 - e2)
	e1 := (1.0 - math.sqrt(1.0 - e2)) / (1.0 + math.sqrt(1.0 - e2))

	x := pt.x - p.false_easting
	y := pt.y - p.false_northing

	M := y / p.k0
	mu := M / (el.a * (1.0 - e2 / 4.0 - 3.0 * e2 * e2 / 64.0 - 5.0 * e2 * e2 * e2 / 256.0))

	e1_2 := e1 * e1
	e1_3 := e1_2 * e1
	e1_4 := e1_3 * e1
	phi1 :=
		mu +
		(3.0 * e1 / 2.0 - 27.0 * e1_3 / 32.0) * math.sin(2.0 * mu) +
		(21.0 * e1_2 / 16.0 - 55.0 * e1_4 / 32.0) * math.sin(4.0 * mu) +
		(151.0 * e1_3 / 96.0) * math.sin(6.0 * mu) +
		(1097.0 * e1_4 / 512.0) * math.sin(8.0 * mu)

	s1, c1 := math.sin(phi1), math.cos(phi1)
	if abs(c1) < 1e-15 {
		return lat_lon(phi1 * RAD, wrap_longitude(p.lon0 * RAD))
	}
	t1 := s1 / c1
	C1 := ep2 * c1 * c1
	T1 := t1 * t1
	N1 := el.a / math.sqrt(1.0 - e2 * s1 * s1)
	R1 := el.a * (1.0 - e2) / math.pow(1.0 - e2 * s1 * s1, 1.5)
	D := x / (N1 * p.k0)

	d2 := D * D
	phi :=
		phi1 -
		(N1 * t1 / R1) *
			(d2 / 2.0 -
					(5.0 + 3.0 * T1 + 10.0 * C1 - 4.0 * C1 * C1 - 9.0 * ep2) * d2 * d2 / 24.0 +
					(61.0 + 90.0 * T1 + 298.0 * C1 + 45.0 * T1 * T1 - 252.0 * ep2 - 3.0 * C1 * C1) *
						d2 *
						d2 *
						d2 /
						720.0)
	lon :=
		p.lon0 +
		(D -
					(1.0 + 2.0 * T1 + C1) * d2 * D / 6.0 +
					(5.0 - 2.0 * C1 + 28.0 * T1 - 3.0 * C1 * C1 + 8.0 * ep2 + 24.0 * T1 * T1) * d2 * d2 * D / 120.0) /
			c1
	return lat_lon(phi * RAD, wrap_longitude(lon * RAD))
}

// Meridional arc length from the equator to `phi`.
@(private)
_meridian_arc :: proc "contextless" (el: Ellipsoid, phi: f64) -> f64 {
	e2 := ecc_sq(el)
	e4 := e2 * e2
	e6 := e4 * e2
	return(
		el.a *
		((1.0 - e2 / 4.0 - 3.0 * e4 / 64.0 - 5.0 * e6 / 256.0) * phi -
				(3.0 * e2 / 8.0 + 3.0 * e4 / 32.0 + 45.0 * e6 / 1024.0) * math.sin(2.0 * phi) +
				(15.0 * e4 / 256.0 + 45.0 * e6 / 1024.0) * math.sin(4.0 * phi) -
				(35.0 * e6 / 3072.0) * math.sin(6.0 * phi)) \
	)
}
