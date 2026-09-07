package worldgen

import "core:math"
import "core:slice"
import geo "ltb:geo"
import hex "ltb:hex"
import "ltb:ingest"
import "ltb:layers"
import "ltb:world"

Params :: struct {
	seed:              u64,
	// Level to generate at. Coarser levels are built by the pyramid afterwards.
	level:             int,
	// Horizontal size of the largest terrain features, in metres.
	terrain_scale:     f64,
	sea_level:         f64, // metres
	max_elevation:     f64, // metres
	// Fraction of the map that ends up above sea level, approximately.
	land_fraction:     f64,
	// Bearing the prevailing wind blows towards, in degrees. Sets which side of
	// the ranges gets the rain.
	prevailing_wind:   f64,
	// Multiplies the whole precipitation field.
	wetness:           f64,
	build_pyramid:     bool,
}

default_params :: proc() -> Params {
	return Params {
		seed = 0x5EED_1234_ABCD_0001,
		level = 0,
		terrain_scale = 90_000,
		sea_level = 0,
		max_elevation = 2400,
		land_fraction = 0.62,
		prevailing_wind = 90, // westerlies: wind blows towards the east
		wetness = 1.0,
		build_pyramid = true,
	}
}

// Layer ids the generator writes. Resolved once so the inner loops do not do
// string lookups.
Layer_Ids :: struct {
	elevation, slope, aspect, hillshade, roughness:     layers.Layer_Id,
	water_depth, water_permanent, flow_accum, flow_dir: layers.Layer_Id,
	distance_to_water:                                  layers.Layer_Id,
	temp_mean, temp_min, precip, humidity, gdd:         layers.Layer_Id,
	soil_texture, soil_ph, soil_depth, soil_moisture:   layers.Layer_Id,
	landcover, forest_density, forest_composition:      layers.Layer_Id,
	canopy_height, stand_age, biomass, fuel_moisture:   layers.Layer_Id,
	population, built_up, ownership:                    layers.Layer_Id,
}

resolve_layers :: proc(r: ^layers.Registry) -> (ids: Layer_Ids, ok: bool) {
	get :: proc(r: ^layers.Registry, name: string, ok: ^bool) -> layers.Layer_Id {
		id, found := layers.lookup(r, name)
		if !found {
			ok^ = false
		}
		return id
	}
	ok = true
	ids.elevation = get(r, "terrain.elevation", &ok)
	ids.slope = get(r, "terrain.slope", &ok)
	ids.aspect = get(r, "terrain.aspect", &ok)
	ids.hillshade = get(r, "terrain.hillshade", &ok)
	ids.roughness = get(r, "terrain.roughness", &ok)
	ids.water_depth = get(r, "water.depth", &ok)
	ids.water_permanent = get(r, "water.permanent", &ok)
	ids.flow_accum = get(r, "water.flow_accumulation", &ok)
	ids.flow_dir = get(r, "water.flow_direction", &ok)
	ids.distance_to_water = get(r, "water.distance_to_water", &ok)
	ids.temp_mean = get(r, "climate.temp_mean_annual", &ok)
	ids.temp_min = get(r, "climate.temp_min_coldest_month", &ok)
	ids.precip = get(r, "climate.precip_annual", &ok)
	ids.humidity = get(r, "climate.humidity", &ok)
	ids.gdd = get(r, "climate.growing_degree_days", &ok)
	ids.soil_texture = get(r, "soil.texture", &ok)
	ids.soil_ph = get(r, "soil.ph", &ok)
	ids.soil_depth = get(r, "soil.depth", &ok)
	ids.soil_moisture = get(r, "soil.moisture", &ok)
	ids.landcover = get(r, "land.cover", &ok)
	ids.forest_density = get(r, "forest.density", &ok)
	ids.forest_composition = get(r, "forest.composition", &ok)
	ids.canopy_height = get(r, "forest.canopy_height", &ok)
	ids.stand_age = get(r, "forest.stand_age", &ok)
	ids.biomass = get(r, "forest.biomass_above_ground", &ok)
	ids.fuel_moisture = get(r, "fire.fuel_moisture", &ok)
	ids.population = get(r, "human.population_density", &ok)
	ids.built_up = get(r, "human.built_up", &ok)
	ids.ownership = get(r, "human.ownership", &ok)
	return
}

Stats :: struct {
	cells:      int,
	land_cells: int,
	forested:   int,
}

// Fills a world's layers over `bounds`, or over the world's whole extent.
generate :: proc(w: ^world.World, p: Params, bounds: Maybe(hex.Bounds) = nil) -> (stats: Stats, ok: bool) {
	ids := resolve_layers(w.registry) or_return
	region := bounds.? or_else world.extent(w, p.level)
	lvl := u8(p.level)
	lay := world.layout(w, p.level)

	elev_noise, warp_noise, detail_noise, climate_noise, soil_noise: Noise
	noise_init(&elev_noise, p.seed)
	noise_init(&warp_noise, p.seed ~ 0x9E37_79B9_7F4A_7C15)
	noise_init(&detail_noise, p.seed ~ 0xBF58_476D_1CE4_E5B9)
	noise_init(&climate_noise, p.seed ~ 0x94D0_49BB_1331_11EB)
	noise_init(&soil_noise, p.seed ~ 0x2545_F491_4F6C_DD1D)

	inv_scale := 1.0 / math.max(1.0, p.terrain_scale)

	// ---- terrain -------------------------------------------------------
	// Domain warping first: it turns the noise's obvious grid alignment into
	// something that reads as geology.
	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			wp := hex.to_world(lay, h)
			x := wp.x * inv_scale
			y := wp.y * inv_scale

			wx := x + 0.55 * fbm(&warp_noise, x * 0.7 + 11.3, y * 0.7 - 4.1, 4)
			wy := y + 0.55 * fbm(&warp_noise, x * 0.7 - 7.9, y * 0.7 + 2.7, 4)

			continent := fbm(&elev_noise, wx * 0.35, wy * 0.35, 5)
			mountains := ridged(&elev_noise, wx * 1.15 + 31.0, wy * 1.15 - 17.0, 6)
			detail := fbm(&detail_noise, wx * 4.0, wy * 4.0, 4)

			// Shift the continent field so about `land_fraction` of it is
			// positive, then let the ridged field pile mountains onto land only.
			land := continent + (p.land_fraction - 0.5) * 1.6
			height: f64
			if land <= 0 {
				height = land * 900.0 // shelf and ocean floor
			} else {
				uplift := math.pow(math.min(1.0, land * 1.9), 1.35)
				height = uplift * (0.35 + 0.65 * mountains) * p.max_elevation
				height += detail * 45.0 * uplift
			}
			height += p.sea_level

			layers.set(w.store, ids.elevation, lvl, h, height)
			stats.cells += 1
			if height > p.sea_level {
				stats.land_cells += 1
			}
		}
	}

	ingest.derive_slope_aspect(w, ids.elevation, ids.slope, ids.aspect, p.level, region)
	ingest.derive_hillshade(w, ids.slope, ids.aspect, ids.hillshade, p.level, 315, 45, region)
	derive_roughness(w, ids.elevation, ids.roughness, p.level, region)

	// ---- hydrology -----------------------------------------------------
	route_water(w, ids, p, region, lvl)

	// ---- climate -------------------------------------------------------
	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			elev, has := layers.get(w.store, ids.elevation, lvl, h)
			if !has {
				continue
			}
			ll := world.cell_center_ll(w, p.level, h)
			wp := hex.to_world(lay, h)
			x := wp.x * inv_scale
			y := wp.y * inv_scale

			// Sea-level temperature from latitude, then a lapse rate with
			// height. 6.5 K/km is the standard environmental lapse rate.
			//
			// The latitude term is quadratic, not linear: mean sea-level
			// temperature falls slowly through the tropics and fast towards the
			// poles, giving about 27 C at the equator, 17 C at 40 degrees and
			// -22 C at the pole.
			abs_lat := abs(ll.lat)
			t_sea := 27.0 - 0.006 * abs_lat * abs_lat + 3.0 * fbm(&climate_noise, x * 0.5, y * 0.5, 3)
			land_elev := math.max(0.0, elev - p.sea_level)
			temp := t_sea - 0.0065 * land_elev
			layers.set(w.store, ids.temp_mean, lvl, h, temp)

			// Continentality: the seasonal swing grows inland and with latitude.
			swing := 4.0 + 0.32 * abs_lat
			layers.set(w.store, ids.temp_min, lvl, h, temp - swing)

			// Orographic precipitation: rain falls where the ground climbs into
			// the wind, and the lee side is dry.
			upwind := upwind_gradient(w, ids.elevation, lvl, lay, h, p.prevailing_wind)
			base := 850.0 + 900.0 * fbm(&climate_noise, x * 0.6 + 5.0, y * 0.6 - 3.0, 4)
			orographic := clamp(upwind * 4200.0, -700.0, 2600.0)
			precip := (base + orographic) * p.wetness
			precip *= math.max(0.25, 1.0 - abs_lat / 140.0)
			precip = math.max(60.0, precip)
			if elev <= p.sea_level {
				precip = math.max(precip, 900.0)
			}
			layers.set(w.store, ids.precip, lvl, h, precip)

			humidity := clamp(0.32 + precip / 3600.0 - math.max(0.0, temp - 18.0) * 0.012, 0.05, 1.0)
			layers.set(w.store, ids.humidity, lvl, h, humidity)

			layers.set(w.store, ids.gdd, lvl, h, growing_degree_days(temp, swing, 5.0))
		}
	}

	// ---- soil ----------------------------------------------------------
	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			elev, has := layers.get(w.store, ids.elevation, lvl, h)
			if !has || elev <= p.sea_level {
				continue
			}
			wp := hex.to_world(lay, h)
			x := wp.x * inv_scale
			y := wp.y * inv_scale
			slope := layers.get_or(w.store, ids.slope, lvl, h, 0)
			precip := layers.get_or(w.store, ids.precip, lvl, h, 800)

			// Steep ground keeps little soil; valley bottoms accumulate it.
			depth := clamp(2.6 - slope * 0.055 + fbm(&soil_noise, x * 2.0, y * 2.0, 3) * 0.8, 0.05, 4.0)
			layers.set(w.store, ids.soil_depth, lvl, h, depth)

			// Texture drifts with a slow noise field; steep sites are coarser.
			mix := fbm(&soil_noise, x * 1.3 + 21.0, y * 1.3 - 9.0, 3)
			sand := clamp(0.40 + mix * 0.30 + slope * 0.004, 0.05, 0.85)
			clay := clamp(0.30 - mix * 0.22 + math.max(0.0, precip - 1500.0) * 0.00008, 0.05, 0.70)
			silt := math.max(0.02, 1.0 - sand - clay)
			total := sand + clay + silt
			tex := [3]f64{sand / total, silt / total, clay / total}
			layers.set_components(w.store, ids.soil_texture, lvl, h, tex[:])

			// Heavy rain leaches bases out of the profile, so wet soils are acid.
			ph := clamp(7.4 - precip * 0.0011 + mix * 0.5, 3.6, 8.6)
			layers.set(w.store, ids.soil_ph, lvl, h, ph)

			moisture := clamp(precip / 2400.0 - slope * 0.006 + 0.15, 0.02, 1.0)
			layers.set(w.store, ids.soil_moisture, lvl, h, moisture)
		}
	}

	// ---- vegetation and cover ------------------------------------------
	comp: [8]f64
	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			elev, has := layers.get(w.store, ids.elevation, lvl, h)
			if !has {
				continue
			}
			if elev <= p.sea_level {
				layers.set(w.store, ids.landcover, lvl, h, 0) // water
				continue
			}
			temp := layers.get_or(w.store, ids.temp_mean, lvl, h, 10)
			tmin := layers.get_or(w.store, ids.temp_min, lvl, h, 0)
			precip := layers.get_or(w.store, ids.precip, lvl, h, 800)
			slope := layers.get_or(w.store, ids.slope, lvl, h, 0)
			moisture := layers.get_or(w.store, ids.soil_moisture, lvl, h, 0.4)
			soil_d := layers.get_or(w.store, ids.soil_depth, lvl, h, 1)

			// Tree cover: needs warmth, water and something to root in, and
			// thins out on the steepest, thinnest ground.
			warmth := smoothstep(-4.0, 8.0, temp) * (1.0 - smoothstep(28.0, 34.0, temp))
			water := smoothstep(250.0, 900.0, precip)
			rooting := smoothstep(0.10, 0.90, soil_d)
			steep := 1.0 - smoothstep(34.0, 55.0, slope)
			density := clamp(warmth * water * rooting * steep, 0.0, 1.0)

			// Snow and ice above the permanent snow line.
			if tmin < -22.0 || (temp < -6.0 && precip > 700) {
				layers.set(w.store, ids.landcover, lvl, h, 1)
				layers.set(w.store, ids.forest_density, lvl, h, 0)
				continue
			}

			layers.set(w.store, ids.forest_density, lvl, h, density)

			cover: f64
			switch {
			case density > 0.55:
				cover = temp < 6.0 ? 10.0 : (precip > 1600 ? 9.0 : 11.0)
			case density > 0.25:
				cover = 6.0 // shrubland
			case precip < 220:
				cover = soil_d < 0.4 ? 2.0 : 3.0
			case slope < 8 && moisture > 0.55 && temp > 6:
				cover = 8.0 // cropland on flat, moist, warm ground
			case:
				cover = 5.0 // grassland
			}
			layers.set(w.store, ids.landcover, lvl, h, cover)

			if density > 0.05 {
				stats.forested += 1
				// Species mix follows the climate niches. Everything is scored,
				// then normalised, so the mix shifts gradually across gradients
				// instead of snapping between types.
				comp[0] = niche(temp, -6, 12) * niche(precip, 500, 2600) // evergreen conifer
				comp[1] = niche(temp, -12, 2) * niche(precip, 250, 900) // deciduous conifer
				comp[2] = niche(temp, 12, 27) * niche(precip, 1200, 4000) // evergreen broadleaf
				comp[3] = niche(temp, 5, 18) * niche(precip, 600, 1800) // deciduous broadleaf
				comp[4] = niche(temp, 13, 26) * niche(precip, 200, 750) // sclerophyll
				comp[5] = niche(temp, 12, 22) * niche(precip, 1800, 5000) * 0.6 // tree fern
				comp[6] = elev < 6 ? niche(temp, 20, 30) * 0.8 : 0.0 // mangrove
				comp[7] = (slope < 18 && soil_d > 0.6) ? 0.25 : 0.05 // plantation
				total := 0.0
				for c in comp {total += c}
				if total < 1e-6 {
					comp = {}
					comp[0] = 1
					total = 1
				}
				for i in 0 ..< 8 {comp[i] /= total}
				layers.set_components(w.store, ids.forest_composition, lvl, h, comp[:])

				// Height and age follow productivity, capped by exposure.
				productivity := clamp(density * water * warmth, 0, 1)
				height := 3.0 + productivity * 38.0 * (1.0 - smoothstep(20.0, 45.0, slope) * 0.5)
				layers.set(w.store, ids.canopy_height, lvl, h, height)
				layers.set(w.store, ids.stand_age, lvl, h, 15.0 + productivity * 220.0)
				// A rough allometry: biomass rises faster than height.
				layers.set(w.store, ids.biomass, lvl, h, density * math.pow(height, 1.6) * 1.5)
			}

			// Fine fuels dry out where it is hot and the soil is dry.
			layers.set(
				w.store,
				ids.fuel_moisture,
				lvl,
				h,
				clamp(0.06 + moisture * 0.55 + math.max(0.0, 18.0 - temp) * 0.01, 0.02, 0.9),
			)
		}
	}

	// ---- people --------------------------------------------------------
	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			elev, has := layers.get(w.store, ids.elevation, lvl, h)
			if !has || elev <= p.sea_level {
				continue
			}
			slope := layers.get_or(w.store, ids.slope, lvl, h, 0)
			temp := layers.get_or(w.store, ids.temp_mean, lvl, h, 10)
			dist_water := layers.get_or(w.store, ids.distance_to_water, lvl, h, 50_000)
			wp := hex.to_world(lay, h)
			x := wp.x * inv_scale
			y := wp.y * inv_scale

			// Settlement likes flat, temperate ground near water, and clusters:
			// the noise term is squared so a few places get most of the people.
			site := (1.0 - smoothstep(3.0, 20.0, slope)) *
				smoothstep(-4.0, 10.0, temp) *
				(1.0 - smoothstep(0.0, 30_000.0, dist_water)) *
				(1.0 - smoothstep(900.0, 2200.0, elev))
			cluster := math.max(0.0, fbm(&climate_noise, x * 3.1 - 40.0, y * 3.1 + 12.0, 4))
			pop := site * cluster * cluster * 5200.0
			if pop > 0.5 {
				layers.set(w.store, ids.population, lvl, h, pop)
				layers.set(w.store, ids.built_up, lvl, h, clamp(pop / 6000.0, 0, 0.95))
			}
			layers.set(w.store, ids.ownership, lvl, h, pop > 200 ? 4.0 : (slope > 28 ? 2.0 : 3.0))
		}
	}

	if p.build_pyramid {
		world.build_all(w, p.level)
	}
	return stats, true
}

// ---------------------------------------------------------------------------

@(private)
smoothstep :: proc "contextless" (edge0, edge1, x: f64) -> f64 {
	if edge1 == edge0 {
		return x < edge0 ? 0 : 1
	}
	t := clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3.0 - 2.0 * t)
}

// Annual growing degree days above `base`, for a site whose daily temperature
// follows a sinusoid of mean `mean` and amplitude `amplitude`.
//
// Integrating max(0, T(t) - base) over the year has a closed form, which is
// both exact for the assumed cycle and far cheaper than stepping 365 days:
//
//     c  = (mean - base) / amplitude
//     t0 = acos(-c)
//     GDD = (365 * amplitude / pi) * (c * t0 + sin t0)
growing_degree_days :: proc "contextless" (mean, amplitude, base: f64) -> f64 {
	DAYS :: 365.2425
	if amplitude <= 1e-6 {
		return math.max(0.0, mean - base) * DAYS
	}
	c := (mean - base) / amplitude
	if c >= 1.0 {
		return (mean - base) * DAYS
	}
	if c <= -1.0 {
		return 0
	}
	t0 := math.acos(-c)
	return (DAYS * amplitude / math.PI) * (c * t0 + math.sin(t0))
}

// A tolerance curve: 1 in the middle of [lo, hi], falling to 0 at the edges.
@(private)
niche :: proc "contextless" (x, lo, hi: f64) -> f64 {
	if hi <= lo {
		return 0
	}
	t := (x - lo) / (hi - lo)
	if t <= 0 || t >= 1 {
		return 0
	}
	s := math.sin(t * math.PI)
	return s * s
}

// Local relief: the elevation range across a cell's neighbourhood.
@(private)
derive_roughness :: proc(
	w: ^world.World,
	elevation, roughness: layers.Layer_Id,
	level: int,
	region: hex.Bounds,
) {
	lvl := u8(level)
	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			z, ok := layers.get(w.store, elevation, lvl, h)
			if !ok {
				continue
			}
			lo, hi := z, z
			for d in 0 ..< 6 {
				if zn, got := layers.get(w.store, elevation, lvl, hex.neighbor(h, hex.Direction(d))); got {
					lo = math.min(lo, zn)
					hi = math.max(hi, zn)
				}
			}
			layers.set(w.store, roughness, lvl, h, hi - lo)
		}
	}
}

// Rise of the terrain into the wind, normalised by the cell pitch. Positive on
// windward slopes, negative in the lee.
@(private)
upwind_gradient :: proc(
	w: ^world.World,
	elevation: layers.Layer_Id,
	level: u8,
	lay: hex.Layout,
	h: hex.Hex,
	wind_bearing: f64,
) -> f64 {
	z, ok := layers.get(w.store, elevation, level, h)
	if !ok {
		return 0
	}
	// The wind blows towards `wind_bearing`, so upwind is the opposite way.
	rad := (wind_bearing + 180.0) * math.PI / 180.0
	dir := [2]f64{math.sin(rad), math.cos(rad)}
	pitch := hex.cell_pitch(lay)

	// Pick the neighbour closest to upwind.
	center := hex.to_world(lay, h)
	best := -2.0
	best_dir := 0
	for d in 0 ..< 6 {
		p := hex.to_world(lay, hex.neighbor(h, hex.Direction(d)))
		v := [2]f64{p.x - center.x, p.y - center.y}
		l := math.sqrt(v.x * v.x + v.y * v.y)
		if l < 1e-9 {
			continue
		}
		dot := (v.x * dir.x + v.y * dir.y) / l
		if dot > best {
			best = dot
			best_dir = d
		}
	}
	zu, got := layers.get(w.store, elevation, level, hex.neighbor(h, hex.Direction(best_dir)))
	if !got {
		return 0
	}
	return (z - zu) / pitch
}

// Routes every cell's water downhill and accumulates the upstream count, then
// derives permanent water, channel depth and distance to water from it.
//
// Sorting the cells by descending elevation and pushing each one's accumulated
// flow into its lowest neighbour visits every cell exactly once and needs no
// iteration to converge, because water only ever moves downhill.
@(private)
route_water :: proc(w: ^world.World, ids: Layer_Ids, p: Params, region: hex.Bounds, lvl: u8) {
	Cell :: struct {
		h: hex.Hex,
		z: f64,
	}
	n := hex.bounds_count(region)
	if n <= 0 {
		return
	}
	cells := make([dynamic]Cell, 0, n, context.temp_allocator)
	defer delete(cells)
	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			if z, ok := layers.get(w.store, ids.elevation, lvl, h); ok {
				append(&cells, Cell{h, z})
			}
		}
	}
	slice.sort_by(cells[:], proc(a, b: Cell) -> bool {
		return a.z > b.z
	})

	accum := make(map[hex.Hex]f64, len(cells) * 2, context.temp_allocator)
	defer delete(accum)
	for c in cells {
		accum[c.h] = 1.0
	}

	for c in cells {
		if c.z <= p.sea_level {
			continue
		}
		lowest := c.h
		lowest_z := c.z
		lowest_dir := -1
		for d in 0 ..< 6 {
			nh := hex.neighbor(c.h, hex.Direction(d))
			nz, ok := layers.get(w.store, ids.elevation, lvl, nh)
			if !ok {
				continue
			}
			if nz < lowest_z {
				lowest_z = nz
				lowest = nh
				lowest_dir = d
			}
		}
		if lowest_dir < 0 {
			continue // a pit: water stops here
		}
		// Bearing of the chosen neighbour, for the flow direction layer.
		lay := world.layout(w, int(lvl))
		cp := hex.to_world(lay, c.h)
		np := hex.to_world(lay, lowest)
		bearing := math.atan2(np.x - cp.x, np.y - cp.y) * 180.0 / math.PI
		if bearing < 0 {bearing += 360.0}
		layers.set(w.store, ids.flow_dir, lvl, c.h, bearing)

		if v, ok := accum[c.h]; ok {
			accum[lowest] = accum[lowest] + v
		}
	}

	for c in cells {
		a := accum[c.h]
		layers.set(w.store, ids.flow_accum, lvl, c.h, a)
		if c.z <= p.sea_level {
			layers.set(w.store, ids.water_permanent, lvl, c.h, 1)
			layers.set(w.store, ids.water_depth, lvl, c.h, p.sea_level - c.z)
			continue
		}
		// A channel forms once enough ground drains through the cell. The
		// exponent keeps big rivers from being absurdly deep.
		if a > 120 {
			layers.set(w.store, ids.water_permanent, lvl, c.h, 1)
			layers.set(w.store, ids.water_depth, lvl, c.h, math.min(14.0, 0.35 * math.pow(a / 120.0, 0.4)))
		}
	}

	derive_distance_to_water(w, ids, region, lvl)
}

// Multi-source breadth-first expansion over the hex graph, which gives an exact
// hop distance and, multiplied by the cell pitch, a good approximation of the
// straight-line distance to the nearest water.
@(private)
derive_distance_to_water :: proc(w: ^world.World, ids: Layer_Ids, region: hex.Bounds, lvl: u8) {
	pitch := hex.cell_pitch(world.layout(w, int(lvl)))
	dist := make(map[hex.Hex]i32, hex.bounds_count(region) * 2, context.temp_allocator)
	defer delete(dist)
	frontier := make([dynamic]hex.Hex, 0, 4096, context.temp_allocator)
	next := make([dynamic]hex.Hex, 0, 4096, context.temp_allocator)
	defer delete(frontier)
	defer delete(next)

	for r in region.r0 ..= region.r1 {
		for q in region.q0 ..= region.q1 {
			h := hex.Hex{q, r}
			if v, ok := layers.get(w.store, ids.water_permanent, lvl, h); ok && v != 0 {
				dist[h] = 0
				append(&frontier, h)
			}
		}
	}

	step := i32(0)
	for len(frontier) > 0 {
		step += 1
		clear(&next)
		for h in frontier {
			for d in 0 ..< 6 {
				nh := hex.neighbor(h, hex.Direction(d))
				if !hex.bounds_contains(region, nh) {
					continue
				}
				if _, seen := dist[nh]; seen {
					continue
				}
				if _, has := layers.get(w.store, ids.elevation, lvl, nh); !has {
					continue
				}
				dist[nh] = step
				append(&next, nh)
			}
		}
		frontier, next = next, frontier
	}

	for h, d in dist {
		layers.set(w.store, ids.distance_to_water, lvl, h, f64(d) * pitch)
	}
}
