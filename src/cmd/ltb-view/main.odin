/*
ltb-view: windowed front end.

The same world as the headless command, drawn and inspectable. Everything that
touches raylib lives in this command, in ltb:render and in ltb:ui, so the engine
itself stays free of a graphics dependency.
*/
package main

import "core:os"
import "ltb:app"

main :: proc() {
	opts, ok := app.parse_options()
	if !ok {
		os.exit(0)
	}
	if opts.print_layers {
		app.print_catalogue_only()
		return
	}

	a: app.App
	if !app.startup(&a, opts) {
		os.exit(1)
	}
	defer app.shutdown(&a)

	if opts.headless {
		app.report_layers(&a.world)
		return
	}
	run_interactive(&a)
}
