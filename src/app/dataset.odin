package app

import "core:strings"
import "ltb:ingest"

/*
Opening a dataset after startup.

The command line builds one world and keeps it. A front end with a File menu
needs to swap the world out while the window stays up, which means rebuilding
the registry, the store, the pyramid and the simulation together: a manifest
brings its own layer declarations, and its region block moves the world to
different ground at a different cell size.
*/

/*
Whether a path names a dataset manifest, and the options for opening it.

A manifest replaces the world outright, so the result starts from the defaults
rather than from `base`: carrying the previous dataset's latitude and cell size
into the next one is how a half-metre aerial photograph ends up rendered over
a region six hundred kilometres wide. Only the settings that belong to the
session rather than to the data -- the window, the clock, the seed -- come from
`base`.

Any other file is a single source to ingest into the world already up, and is
left to `load_source`.
*/
dataset_options :: proc(base: Options, path: string) -> (o: Options, is_manifest: bool) {
	region, ok := ingest.read_region(path, context.temp_allocator)
	if !ok {
		return base, false
	}
	defer ingest.region_destroy(&region, context.temp_allocator)

	o = default_options()
	o.width, o.height = base.width, base.height
	o.seed = base.seed
	o.days_per_tick = base.days_per_tick
	o.layer_file = base.layer_file
	o.manifest = path
	apply_region(&o, region)
	return o, true
}

// Overlays a region block, leaving alone anything the command line set.
@(private)
apply_region :: proc(o: ^Options, region: ingest.Region) {
	if v, has := region.lat.?; has && .Lat not_in o.given {o.lat = v}
	if v, has := region.lon.?; has && .Lon not_in o.given {o.lon = v}
	if v, has := region.span_km.?; has && .Span not_in o.given {o.span_km = v}
	if v, has := region.cell_area.?; has && .Cell_Area not_in o.given {o.cell_area = v}
	if v, has := region.levels.?; has && .Levels not_in o.given {o.levels = v}
	if len(region.layer) > 0 && .Open_Layer not_in o.given {
		// Cloned into the static allocator: the options outlive the parse, and
		// this string is read for as long as the world it describes is up.
		o.open_layer = strings.clone(region.layer)
	}
}

// Places a world from the manifest named on the command line, so that
// `--manifest x` and File > Open of the same x agree.
apply_manifest_region :: proc(o: ^Options) {
	if len(o.manifest) == 0 {
		return
	}
	region, ok := ingest.read_region(o.manifest, context.temp_allocator)
	if !ok {
		return
	}
	defer ingest.region_destroy(&region, context.temp_allocator)
	apply_region(o, region)
}

// The name to show for a dataset: its manifest title, or the file name.
dataset_title :: proc(path: string, allocator := context.allocator) -> string {
	region, ok := ingest.read_region(path, context.temp_allocator)
	if ok {
		defer ingest.region_destroy(&region, context.temp_allocator)
		if len(region.title) > 0 {
			return strings.clone(region.title, allocator)
		}
	}
	return strings.clone(path, allocator)
}

/*
Tears the current world down and builds a new one in place.

The App owns its registry and store, and the world holds pointers into them, so
this cannot be done by building a second App and swapping: the world would keep
pointing at the wrong one. It is a shutdown followed by a startup, and on
failure the App is left shut down. A caller that gets `false` must stop using
the App rather than carry on drawing a half-built world.
*/
reload :: proc(app: ^App, opts: Options) -> (ok: bool) {
	shutdown(app)
	app^ = {}
	return startup(app, opts)
}
