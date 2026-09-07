package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "ltb:app"
import "ltb:ingest"
import "ltb:layers"
import "ltb:ui"
import rl "vendor:raylib"

/*
The dataset browser.

A modal list of one directory at a time, filtered to the formats the ingest can
read. Opening a manifest rebuilds the world; opening a bare raster or vector
ingests it into the world already up, which needs a target layer, so the
catalogue is offered alongside the file list whenever the selection is not a
manifest.
*/

Browser :: struct {
	open:        bool,
	// Directory being listed, absolute, owned.
	dir:         string,
	names:       [dynamic]string,
	paths:       [dynamic]string,
	is_dir:      [dynamic]bool,
	selected:    int,
	scroll:      int,
	// True when the selection is a manifest, so opening it replaces the world
	// and no target layer is needed.
	sel_manifest: bool,

	// The layer a non-manifest source would be ingested into.
	layer_names: [dynamic]string,
	layer_index: int,
	layer_scroll: int,

	// Laid out each frame, shared by input and drawing.
	panel:       rl.Rectangle,
	list:        rl.Rectangle,
	layer_list:  rl.Rectangle,
	up_btn:      rl.Rectangle,
	open_btn:    rl.Rectangle,
	cancel_btn:  rl.Rectangle,
}

browser_init :: proc(b: ^Browser) {
	b.names = make([dynamic]string, 0, 64)
	b.paths = make([dynamic]string, 0, 64)
	b.is_dir = make([dynamic]bool, 0, 64)
	b.layer_names = make([dynamic]string, 0, 64)
	b.selected = -1
}

browser_destroy :: proc(b: ^Browser) {
	browser_clear(b)
	delete(b.names)
	delete(b.paths)
	delete(b.is_dir)
	browser_clear_layers(b)
	delete(b.layer_names)
	delete(b.dir)
	b^ = {}
}

@(private = "file")
browser_clear :: proc(b: ^Browser) {
	for n in b.names {delete(n)}
	for p in b.paths {delete(p)}
	clear(&b.names)
	clear(&b.paths)
	clear(&b.is_dir)
}

@(private = "file")
browser_clear_layers :: proc(b: ^Browser) {
	for n in b.layer_names {delete(n)}
	clear(&b.layer_names)
}

// Opens on data/ when it is there, since that is where the sample datasets
// live, and on the working directory otherwise.
browser_open :: proc(b: ^Browser, a: ^app.App) {
	start := string(rl.GetWorkingDirectory())
	if rl.DirectoryExists("data") {
		joined, _ := strings.concatenate({start, "/data"}, context.temp_allocator)
		start = joined
	}
	browser_open_at(b, a, start)
}

// Opens listing the directory `path` sits in, with `path` selected. A file
// dropped on the window lands here, so its target layer can still be chosen.
browser_open_at :: proc(b: ^Browser, a: ^app.App, path: string) {
	dir := path
	if !rl.DirectoryExists(strings.clone_to_cstring(path, context.temp_allocator)) {
		dir = string(rl.GetPrevDirectoryPath(strings.clone_to_cstring(path, context.temp_allocator)))
	}
	b.open = true
	browser_load_layers(b, a)
	browser_set_dir(b, a, dir)

	for p, i in b.paths {
		if p == path {
			browser_select(b, a, i)
			break
		}
	}
}

@(private = "file")
browser_load_layers :: proc(b: ^Browser, a: ^app.App) {
	browser_clear_layers(b)
	// Cloned: the registry these names live in is freed when a dataset is
	// opened, and the browser outlives that by a frame.
	for i in 0 ..< layers.layer_count(a.world.registry) {
		d := layers.desc_of(a.world.registry, layers.Layer_Id(i))
		append(&b.layer_names, strings.clone(d.name))
	}
	b.layer_index = 0
	b.layer_scroll = 0
	for n, i in b.layer_names {
		if n == "terrain.elevation" {
			b.layer_index = i
			break
		}
	}
}

@(private = "file")
browser_set_dir :: proc(b: ^Browser, a: ^app.App, dir: string) {
	browser_clear(b)
	delete(b.dir)
	b.dir = strings.clone(dir)
	b.selected = -1
	b.scroll = 0
	b.sel_manifest = false

	files := rl.LoadDirectoryFiles(strings.clone_to_cstring(dir, context.temp_allocator))
	defer rl.UnloadDirectoryFiles(files)

	Row :: struct {
		name, path: string,
		is_dir:     bool,
	}
	rows := make([dynamic]Row, 0, int(files.count), context.temp_allocator)
	for i in 0 ..< int(files.count) {
		path := string(files.paths[i])
		name := string(rl.GetFileName(files.paths[i]))
		if strings.has_prefix(name, ".") {
			continue
		}
		is_dir := !rl.IsPathFile(files.paths[i])
		if !is_dir && !ingest.is_readable(name) {
			continue
		}
		append(&rows, Row{name, path, is_dir})
	}
	// Directories first, then by name, which is the order every file dialog
	// uses and the only one that makes a deep tree navigable.
	slice.sort_by(rows[:], proc(x, y: Row) -> bool {
		if x.is_dir != y.is_dir {
			return x.is_dir
		}
		return x.name < y.name
	})
	for r in rows {
		append(&b.names, strings.clone(r.name))
		append(&b.paths, strings.clone(r.path))
		append(&b.is_dir, r.is_dir)
	}
}

@(private = "file")
browser_select :: proc(b: ^Browser, a: ^app.App, index: int) {
	b.selected = index
	b.sel_manifest = false
	if index < 0 || index >= len(b.paths) || b.is_dir[index] {
		return
	}
	_, is_manifest := app.dataset_options(a.opts, b.paths[index])
	b.sel_manifest = is_manifest
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

browser_input :: proc(m: ^Menu, a: ^app.App) {
	b := &m.browser
	browser_layout(b)
	mp := rl.GetMousePosition()
	clicked := rl.IsMouseButtonPressed(.LEFT)

	if rl.IsKeyPressed(.ESCAPE) {
		browser_close(b)
		return
	}
	if rl.IsKeyPressed(.BACKSPACE) {
		browser_up(b, a)
		return
	}
	if rl.IsKeyPressed(.DOWN) && len(b.paths) > 0 {
		browser_select(b, a, min(b.selected + 1, len(b.paths) - 1))
		browser_reveal(b)
	}
	if rl.IsKeyPressed(.UP) && len(b.paths) > 0 {
		browser_select(b, a, max(b.selected - 1, 0))
		browser_reveal(b)
	}
	if rl.IsKeyPressed(.ENTER) {
		browser_activate(m, a)
		return
	}

	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		if ui.hovered(b.layer_list, mp) && !b.sel_manifest {
			b.layer_scroll = clamp(b.layer_scroll - int(wheel) * 3, 0, max(0, len(b.layer_names) - ui.list_rows(b.layer_list)))
		} else {
			b.scroll = clamp(b.scroll - int(wheel) * 3, 0, max(0, len(b.paths) - ui.list_rows(b.list)))
		}
	}

	if !clicked {
		return
	}
	if ui.hovered(b.up_btn, mp) {
		browser_up(b, a)
		return
	}
	if ui.hovered(b.cancel_btn, mp) {
		browser_close(b)
		return
	}
	if ui.hovered(b.open_btn, mp) {
		browser_activate(m, a)
		return
	}
	if ui.hovered(b.list, mp) {
		row := ui.list_row_at(b.list, mp, b.scroll, len(b.paths))
		if row >= 0 {
			// A second click on the row already selected opens it, which is
			// the double-click every file dialog answers to.
			if row == b.selected {
				browser_activate(m, a)
			} else {
				browser_select(b, a, row)
			}
		}
		return
	}
	if !b.sel_manifest && ui.hovered(b.layer_list, mp) {
		row := ui.list_row_at(b.layer_list, mp, b.layer_scroll, len(b.layer_names))
		if row >= 0 {
			b.layer_index = row
		}
		return
	}
	// Clicking outside the panel dismisses it, like the drop-down menu.
	if !ui.hovered(b.panel, mp) {
		browser_close(b)
	}
}

@(private = "file")
browser_close :: proc(b: ^Browser) {
	b.open = false
	browser_clear(b)
	browser_clear_layers(b)
}

@(private = "file")
browser_up :: proc(b: ^Browser, a: ^app.App) {
	parent := string(rl.GetPrevDirectoryPath(strings.clone_to_cstring(b.dir, context.temp_allocator)))
	if len(parent) > 0 && parent != b.dir {
		browser_set_dir(b, a, parent)
	}
}

// Enters a directory, or asks the loop to open the selected file.
@(private = "file")
browser_activate :: proc(m: ^Menu, a: ^app.App) {
	b := &m.browser
	if b.selected < 0 || b.selected >= len(b.paths) {
		return
	}
	if b.is_dir[b.selected] {
		browser_set_dir(b, a, b.paths[b.selected])
		return
	}
	path := b.paths[b.selected]
	if b.sel_manifest {
		menu_request_open(m, path)
	} else if b.layer_index >= 0 && b.layer_index < len(b.layer_names) {
		menu_request_source(m, path, b.layer_names[b.layer_index])
	}
	browser_close(b)
}

// Keeps the selected row on screen after a keyboard move.
@(private = "file")
browser_reveal :: proc(b: ^Browser) {
	rows := ui.list_rows(b.list)
	if b.selected < b.scroll {
		b.scroll = b.selected
	} else if b.selected >= b.scroll + rows {
		b.scroll = b.selected - rows + 1
	}
	b.scroll = clamp(b.scroll, 0, max(0, len(b.paths) - rows))
}

// ---------------------------------------------------------------------------
// Layout and drawing
// ---------------------------------------------------------------------------

@(private = "file")
browser_layout :: proc(b: ^Browser) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	w := min(f32(820), sw - 60)
	h := min(f32(540), sh - 60)
	x := (sw - w) * 0.5
	y := (sh - h) * 0.5
	b.panel = rl.Rectangle{x, y, w, h}

	b.up_btn = rl.Rectangle{x + w - 68, y + 38, 56, 22}

	list_top := y + 70
	list_bottom := y + h - 48
	// The layer catalogue takes the right third, and only when it is needed.
	list_w := b.sel_manifest ? w - 24 : (w - 32) * 0.62
	b.list = rl.Rectangle{x + 12, list_top, list_w, list_bottom - list_top}
	b.layer_list = rl.Rectangle{x + 20 + list_w, list_top, w - 32 - list_w, list_bottom - list_top}

	b.cancel_btn = rl.Rectangle{x + w - 176, y + h - 36, 78, 26}
	b.open_btn = rl.Rectangle{x + w - 90, y + h - 36, 78, 26}
}

browser_draw :: proc(m: ^Menu, a: ^app.App) {
	b := &m.browser
	browser_layout(b)
	mp := ui.mouse()

	ui.scrim()
	ui.frame(b.panel)

	px := i32(b.panel.x)
	py := i32(b.panel.y)
	bottom := i32(b.panel.y + b.panel.height)
	ui.text("Open data", px + 12, py + 10, ui.HEADING, ui.TEXT)
	ui.text(b.dir, px + 12, py + 42, ui.SMALL, ui.TEXT_MUTED)
	ui.button(b.up_btn, "Up", ui.hovered(b.up_btn, mp), true)

	ui.list(b.list, len(b.names), b.selected, b.scroll, mp, file_label, b)

	if !b.sel_manifest {
		ui.text("ingest into layer", i32(b.layer_list.x), i32(b.layer_list.y) - 16, ui.SMALL, ui.TEXT_MUTED)
		ui.list(b.layer_list, len(b.layer_names), b.layer_index, b.layer_scroll, mp, layer_label, b)
	} else if b.selected >= 0 {
		ui.text("manifest: replaces the world", px + 12, bottom - 62, ui.SMALL, ui.OK)
	}

	can_open := b.selected >= 0 && b.selected < len(b.paths)
	ui.button(b.cancel_btn, "Cancel", ui.hovered(b.cancel_btn, mp), true)
	ui.button(
		b.open_btn,
		can_open && b.is_dir[b.selected] ? "Enter" : "Open",
		ui.hovered(b.open_btn, mp),
		can_open,
	)

	ui.text(
		"double-click or enter opens   backspace goes up   esc cancels",
		px + 12,
		bottom - 30,
		ui.TINY,
		ui.TEXT_FAINT,
	)
}

// A directory reads as somewhere to go rather than something to open, so it is
// marked as such in both its colour and its trailing slash.
@(private = "file")
file_label :: proc(index: int, user: rawptr) -> (text: string, color: ui.Color) {
	b := (^Browser)(user)
	if b.is_dir[index] {
		return fmt.tprintf("%s/", b.names[index]), ui.LINK
	}
	return b.names[index], ui.TEXT
}

@(private = "file")
layer_label :: proc(index: int, user: rawptr) -> (text: string, color: ui.Color) {
	return (^Browser)(user).layer_names[index], ui.TEXT
}
