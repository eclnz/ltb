/*
ltb: headless front end.

Builds a world, ingests any data it was given, runs the simulation and reports
what happened. It links no graphics libraries, so it runs on a build machine, in
CI, or over ssh.
*/
package main

import "core:os"
import "ltb:app"

main :: proc() {
	opts, ok := app.parse_options()
	if !ok {
		os.exit(0)
	}

	a: app.App
	if opts.print_layers {
		app.print_catalogue_only()
		return
	}
	if !app.startup(&a, opts) {
		os.exit(1)
	}
	defer app.shutdown(&a)

	app.report_layers(&a.world)
}
