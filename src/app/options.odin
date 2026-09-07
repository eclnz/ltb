package app

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

/*
Fields a manifest's "region" block can also set.

The command line wins over the manifest, so parsing records which of these were
typed and the region fills in only the rest. Without that, `--lat` would be
silently discarded by any manifest that places itself.
*/
Given_Field :: enum {
	Lat,
	Lon,
	Span,
	Cell_Area,
	Levels,
	Open_Layer,
}

Given :: bit_set[Given_Field]

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
	// Load a whole dataset manifest: several sources, each with its own
	// resampling and attribute mapping.
	manifest:     string,
	// Extra layer declarations to register before anything else.
	layer_file:   string,
	// Render a scripted set of frames to this directory and exit.
	shots_dir:    string,
	// Which scripted set to render: "wide" or "close".
	shots_set:    string,
	// Layer the viewer opens on. Empty falls back to terrain.elevation, then
	// to the first layer that holds anything.
	open_layer:   string,
	// Window size for the interactive mode.
	width, height: int,
	print_layers: bool,
	// Which of the above the command line set explicitly.
	given:        Given,
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

Every cell comes from a file. Give it a dataset with --manifest or --load, or
start the viewer and open one from the File menu.

usage: ltb [options]

  --headless            run without a window: ingest, simulate, report
  --seed N              simulation seed (default 0x5EED1234ABCD0001)
  --cell-area M2        ground area of one level-0 cell in m^2 (default 250000)
  --levels N            number of pyramid levels (default 7)
  --lat D --lon D       centre of the region (default -41.5, 172.8)
  --span KM             half-width of the region in km (default 160)
  --ticks N             simulation ticks to run before drawing (default 0)
  --days-per-tick D     simulated days per tick (default 7)
  --load PATH           ingest a GeoTIFF or .asc file before starting
  --load-layer NAME     layer to ingest into (default terrain.elevation)
  --manifest PATH       load a dataset manifest (rasters and vectors together);
                        its "region" block sets the centre, span, cell size and
                        opening layer unless the flags above are given
  --layers PATH         register extra layer declarations from a JSON file
  --open-layer NAME     layer the viewer opens on
  --shots DIR           render a scripted set of frames to DIR and exit
  --shot-set NAME       which set: wide (default) or close
  --width N --height N  window size
  --list-layers         print the layer catalogue and exit
  --help                this message

controls (interactive):
  drag / arrows         pan            wheel          zoom
  o                     open a dataset (or drop a file on the window)
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

	// A value that will not parse is an error, not a reason to carry on with
	// the default: a typo in --lat would otherwise put the world somewhere
	// else entirely and say nothing about it.
	number :: proc(v: string, name: string) -> (f64, bool) {
		n, parsed := strconv.parse_f64(v)
		if !parsed {
			fmt.eprintfln("%s: %q is not a number", name, v)
		}
		return n, parsed
	}
	integer :: proc(v: string, name: string) -> (int, bool) {
		n, parsed := strconv.parse_int(v)
		if !parsed {
			fmt.eprintfln("%s: %q is not a whole number", name, v)
		}
		return n, parsed
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
			seed, parsed := strconv.parse_u64_maybe_prefixed(v)
			if !parsed {
				fmt.eprintfln("%s: %q is not a number", a, v)
				return o, false
			}
			o.seed = seed
		case "--cell-area":
			v := next_value(args, &i, a) or_return
			o.cell_area = number(v, a) or_return
			o.given += {.Cell_Area}
		case "--levels":
			v := next_value(args, &i, a) or_return
			o.levels = integer(v, a) or_return
			o.given += {.Levels}
		case "--lat":
			v := next_value(args, &i, a) or_return
			o.lat = number(v, a) or_return
			o.given += {.Lat}
		case "--lon":
			v := next_value(args, &i, a) or_return
			o.lon = number(v, a) or_return
			o.given += {.Lon}
		case "--span":
			v := next_value(args, &i, a) or_return
			o.span_km = number(v, a) or_return
			o.given += {.Span}
		case "--ticks":
			v := next_value(args, &i, a) or_return
			o.ticks = integer(v, a) or_return
		case "--days-per-tick":
			v := next_value(args, &i, a) or_return
			o.days_per_tick = number(v, a) or_return
		case "--load":
			o.load_path = next_value(args, &i, a) or_return
		case "--load-layer":
			o.load_layer = next_value(args, &i, a) or_return
		case "--manifest":
			o.manifest = next_value(args, &i, a) or_return
		case "--layers":
			o.layer_file = next_value(args, &i, a) or_return
		case "--open-layer":
			o.open_layer = next_value(args, &i, a) or_return
			o.given += {.Open_Layer}
		case "--shots":
			o.shots_dir = next_value(args, &i, a) or_return
		case "--shot-set":
			o.shots_set = next_value(args, &i, a) or_return
		case "--width":
			v := next_value(args, &i, a) or_return
			o.width = integer(v, a) or_return
		case "--height":
			v := next_value(args, &i, a) or_return
			o.height = integer(v, a) or_return
		case:
			fmt.eprintfln("unknown argument %s", a)
			fmt.println(USAGE)
			return o, false
		}
		i += 1
	}
	if len(o.load_path) > 0 && len(o.load_layer) == 0 {
		o.load_layer = "terrain.elevation"
	}
	// A manifest places its own world, so the command line and the File menu
	// put the same dataset in the same place.
	apply_manifest_region(&o)
	return o, true
}
