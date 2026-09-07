package app

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Options :: struct {
	headless:     bool,
	seed:         u64,
	// Ground area of a level-0 cell, in square metres. 1e6 is a cell about a
	// kilometre across.
	cell_area:    f64,
	levels:       int,
	// Centre and half-span of the region to simulate.
	lat, lon:     f64,
	span_km:      f64,
	ticks:        int,
	days_per_tick: f64,
	// Ingest a GeoTIFF or ESRI ASCII grid into a named layer before starting.
	load_path:    string,
	load_layer:   string,
	// Window size for the interactive mode.
	width, height: int,
	print_layers: bool,
}

default_options :: proc() -> Options {
	return Options {
		headless = false,
		seed = 0x5EED_1234_ABCD_0001,
		cell_area = 250_000, // ~500 m across
		levels = 7,
		lat = -41.5,
		lon = 172.8,
		span_km = 160,
		ticks = 0,
		days_per_tick = 7,
		width = 1440,
		height = 900,
	}
}

USAGE :: `ltb -- hex-grid landscape simulation

usage: ltb [options]

  --headless            run without a window: generate, simulate, report
  --seed N              world seed (default 0x5EED1234ABCD0001)
  --cell-area M2        ground area of one level-0 cell in m^2 (default 250000)
  --levels N            number of pyramid levels (default 7)
  --lat D --lon D       centre of the region (default -41.5, 172.8)
  --span KM             half-width of the region in km (default 160)
  --ticks N             simulation ticks to run before drawing (default 0)
  --days-per-tick D     simulated days per tick (default 7)
  --load PATH           ingest a GeoTIFF or .asc file before starting
  --load-layer NAME     layer to ingest into (default terrain.elevation)
  --width N --height N  window size
  --list-layers         print the layer catalogue and exit
  --help                this message

controls (interactive):
  drag / arrows         pan            wheel          zoom
  [ ]                   previous / next layer with data
  g                     cell outlines  h              hillshade blend
  , .                   force a coarser / finer pyramid level, backtick to release
  space                 pause or resume the simulation
  n                     step one tick while paused
  f                     fill gaps from coarser levels
`

parse_options :: proc() -> (o: Options, ok: bool) {
	o = default_options()
	args := os.args[1:]
	i := 0

	next_value :: proc(args: []string, i: ^int, name: string) -> (string, bool) {
		if i^ + 1 >= len(args) {
			fmt.eprintfln("%s needs a value", name)
			return "", false
		}
		i^ += 1
		return args[i^], true
	}

	for i < len(args) {
		a := args[i]
		switch a {
		case "--help", "-h":
			fmt.println(USAGE)
			return o, false
		case "--headless":
			o.headless = true
		case "--list-layers":
			o.print_layers = true
		case "--seed":
			v := next_value(args, &i, a) or_return
			o.seed = strconv.parse_u64_maybe_prefixed(v) or_else o.seed
		case "--cell-area":
			v := next_value(args, &i, a) or_return
			o.cell_area = strconv.parse_f64(v) or_else o.cell_area
		case "--levels":
			v := next_value(args, &i, a) or_return
			o.levels = strconv.parse_int(v) or_else o.levels
		case "--lat":
			v := next_value(args, &i, a) or_return
			o.lat = strconv.parse_f64(v) or_else o.lat
		case "--lon":
			v := next_value(args, &i, a) or_return
			o.lon = strconv.parse_f64(v) or_else o.lon
		case "--span":
			v := next_value(args, &i, a) or_return
			o.span_km = strconv.parse_f64(v) or_else o.span_km
		case "--ticks":
			v := next_value(args, &i, a) or_return
			o.ticks = strconv.parse_int(v) or_else o.ticks
		case "--days-per-tick":
			v := next_value(args, &i, a) or_return
			o.days_per_tick = strconv.parse_f64(v) or_else o.days_per_tick
		case "--load":
			o.load_path = next_value(args, &i, a) or_return
		case "--load-layer":
			o.load_layer = next_value(args, &i, a) or_return
		case "--width":
			v := next_value(args, &i, a) or_return
			o.width = strconv.parse_int(v) or_else o.width
		case "--height":
			v := next_value(args, &i, a) or_return
			o.height = strconv.parse_int(v) or_else o.height
		case:
			if strings.has_prefix(a, "-") {
				fmt.eprintfln("unknown option %s", a)
				fmt.println(USAGE)
				return o, false
			}
		}
		i += 1
	}
	if len(o.load_path) > 0 && len(o.load_layer) == 0 {
		o.load_layer = "terrain.elevation"
	}
	return o, true
}
