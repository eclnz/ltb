package main

import "core:slice"
import "core:strings"
import "ltb:app"
import "ltb:ui"
import rl "vendor:raylib"

/*
The menu bar and the dataset browser.

raylib draws no widgets and macOS's native file dialog would pull in platform
code the rest of the viewer does without, so both are drawn here in the same
immediate-mode style as the HUD. Input is handled at the top of the frame, one
step ahead of the camera, so that a click on the bar does not also drag the map.

The bar owns every string it hands back, and keeps them alive until the next
request replaces them.
*/

MENU_BAR_H :: 26
ITEM_H :: 22
SEPARATOR_H :: 7

// What the interactive loop should do once the frame's input is handled.
Menu_Request :: enum {
	None,
	// Rebuild the world from `path`, a manifest.
	Open_Dataset,
	// Ingest `path` into `layer` of the world that is already up.
	Load_Source,
	// Rebuild the world from the options it already has.
	Reload,
	Quit,
}

Dataset :: struct {
	path:  string,
	title: string,
}

Item_Kind :: enum {
	Open,
	Reload,
	Dataset,
	Separator,
	Quit,
}

Item :: struct {
	kind:  Item_Kind,
	label: string,
	// Index into `Menu.datasets`, for `.Dataset` items.
	index: int,
	rect:  rl.Rectangle,
}

Menu :: struct {
	// -1 when no menu is dropped down. 0 is File, the only one so far.
	open_menu: int,
	file_rect: rl.Rectangle,
	items:     [dynamic]Item,
	datasets:  [dynamic]Dataset,
	browser:   Browser,
	// Set for one frame when something is chosen. The caller clears it.
	request:   Menu_Request,
	path:      string,
	layer:     string,
	// Path the world was built from. Owned here, because App.opts.manifest
	// points at it for as long as that world lives, and the request path it
	// was cloned from is freed by the next request.
	dataset:   string,
	// What the bar shows for that dataset.
	current:   string,
	// One line of feedback, shown under the bar until the next request.
	status:    string,
}

menu_init :: proc(m: ^Menu, current_path: string) {
	m.open_menu = -1
	m.items = make([dynamic]Item, 0, 16)
	m.datasets = make([dynamic]Dataset, 0, 8)
	browser_init(&m.browser)
	discover_datasets(m)
	menu_set_current(m, current_path)
}

menu_destroy :: proc(m: ^Menu) {
	for d in m.datasets {
		delete(d.path)
		delete(d.title)
	}
	delete(m.datasets)
	delete(m.items)
	browser_destroy(&m.browser)
	delete(m.path)
	delete(m.layer)
	delete(m.dataset)
	delete(m.current)
	delete(m.status)
	m^ = {}
}

// Records which dataset the world was built from, and what to call it.
menu_set_current :: proc(m: ^Menu, path: string) {
	delete(m.dataset)
	delete(m.current)
	m.dataset = strings.clone(path)
	if len(path) == 0 {
		m.current = strings.clone("no dataset -- File > Open")
		return
	}
	m.current = app.dataset_title(path)
}

menu_set_status :: proc(m: ^Menu, text: string) {
	delete(m.status)
	m.status = strings.clone(text)
}

menu_request :: proc(m: ^Menu, req: Menu_Request, path: string, layer: string = "") {
	delete(m.path)
	delete(m.layer)
	m.path = strings.clone(path)
	m.layer = strings.clone(layer)
	m.request = req
	m.open_menu = -1
}

// Rebuild the world from this manifest.
menu_request_open :: proc(m: ^Menu, path: string) {
	menu_request(m, .Open_Dataset, path)
}

// Ingest this file into `layer` of the world already up.
menu_request_source :: proc(m: ^Menu, path, layer: string) {
	menu_request(m, .Load_Source, path, layer)
}

// Every manifest under data/, for the File menu's shortcut list. A .json that
// is not a manifest -- a layer catalogue, a stray GeoJSON -- is skipped.
@(private = "file")
discover_datasets :: proc(m: ^Menu) {
	if !rl.DirectoryExists("data") {
		return
	}
	files := rl.LoadDirectoryFilesEx("data", ".json", true)
	defer rl.UnloadDirectoryFiles(files)

	for i in 0 ..< int(files.count) {
		path := string(files.paths[i])
		if _, ok := app.dataset_options(app.default_options(), path); !ok {
			continue
		}
		append(&m.datasets, Dataset{strings.clone(path), app.dataset_title(path)})
	}
	slice.sort_by(m.datasets[:], proc(a, b: Dataset) -> bool {
		return a.path < b.path
	})
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

// Handles a frame's input for the bar and the browser. Returns true when the
// menu took the mouse or the keyboard, in which case the map must ignore both.
menu_input :: proc(m: ^Menu, a: ^app.App) -> (consumed: bool) {
	mp := rl.GetMousePosition()
	clicked := rl.IsMouseButtonPressed(.LEFT)

	if m.browser.open {
		browser_input(m, a)
		return true
	}

	menu_layout(m)
	over_bar := mp.y < MENU_BAR_H

	if rl.IsKeyPressed(.ESCAPE) && m.open_menu >= 0 {
		m.open_menu = -1
		return true
	}

	if clicked && ui.hovered(m.file_rect, mp) {
		m.open_menu = m.open_menu == 0 ? -1 : 0
		return true
	}

	if m.open_menu >= 0 {
		for item in m.items {
			if item.kind == .Separator {
				continue
			}
			if !ui.hovered(item.rect, mp) {
				continue
			}
			if !clicked {
				break
			}
			switch item.kind {
			case .Open:
				browser_open(&m.browser, a)
				m.open_menu = -1
			case .Reload:
				menu_request(m, .Reload, m.dataset)
			case .Dataset:
				menu_request(m, .Open_Dataset, m.datasets[item.index].path)
			case .Quit:
				menu_request(m, .Quit, "")
			case .Separator:
			}
			return true
		}
		// A click anywhere else dismisses the menu without reaching the map.
		if clicked {
			m.open_menu = -1
			return true
		}
		return true
	}

	// A file dragged onto the window is the same gesture as opening one. A
	// manifest carries its own target layers and can go straight in; anything
	// else needs one chosen, so it lands in the browser preselected.
	if rl.IsFileDropped() {
		dropped := rl.LoadDroppedFiles()
		defer rl.UnloadDroppedFiles(dropped)
		if dropped.count > 0 {
			path := string(dropped.paths[0])
			if _, is_manifest := app.dataset_options(a.opts, path); is_manifest {
				menu_request_open(m, path)
			} else {
				browser_open_at(&m.browser, a, path)
			}
			return true
		}
	}

	return over_bar
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

// Positions the bar and, when it is down, the File menu's items. Layout runs
// during input as well as drawing, so hit tests and pixels never disagree.
@(private = "file")
menu_layout :: proc(m: ^Menu) {
	clear(&m.items)
	label_w := f32(ui.text_width("File", ui.BODY))
	m.file_rect = rl.Rectangle{6, 0, label_w + 20, MENU_BAR_H}
	if m.open_menu != 0 {
		return
	}

	add :: proc(m: ^Menu, kind: Item_Kind, label: string, index: int = 0) {
		append(&m.items, Item{kind = kind, label = label, index = index})
	}
	add(m, .Open, "Open dataset...")
	add(m, .Reload, "Reload")
	add(m, .Separator, "")
	for d, i in m.datasets {
		add(m, .Dataset, d.title, i)
	}
	if len(m.datasets) > 0 {
		add(m, .Separator, "")
	}
	add(m, .Quit, "Quit")

	width := f32(200)
	for item in m.items {
		if item.kind == .Separator {
			continue
		}
		width = max(width, f32(ui.text_width(item.label, ui.BODY) + 34))
	}

	y := f32(MENU_BAR_H)
	for &item in m.items {
		h := item.kind == .Separator ? f32(SEPARATOR_H) : f32(ITEM_H)
		item.rect = rl.Rectangle{m.file_rect.x, y, width, h}
		y += h
	}
}

menu_draw :: proc(m: ^Menu, a: ^app.App) {
	if m.browser.open {
		browser_draw(m, a)
		return
	}
	menu_layout(m)
	screen_w := ui.screen_width()
	mp := ui.mouse()

	ui.fill(ui.rect(0, 0, screen_w, MENU_BAR_H), ui.BAR)
	ui.fill(ui.rect(0, MENU_BAR_H, screen_w, 1), ui.BORDER)

	if m.open_menu == 0 || ui.hovered(m.file_rect, mp) {
		ui.fill(m.file_rect, ui.HIGHLIGHT)
	}
	ui.text("File", i32(m.file_rect.x) + 10, 6, ui.BODY, ui.TEXT)

	// The dataset in view, right-aligned, so the window always says what it is
	// showing without opening anything.
	ui.text_right(m.current, screen_w - 10, 7, ui.LABEL, ui.TEXT_MUTED)

	if len(m.status) > 0 {
		ui.text_centered(m.status, screen_w / 2, 7, ui.LABEL, ui.WARN)
	}

	if m.open_menu != 0 || len(m.items) == 0 {
		return
	}
	last := m.items[len(m.items) - 1].rect
	ui.frame(ui.Rectangle{m.file_rect.x, MENU_BAR_H, last.width, last.y + last.height - MENU_BAR_H})

	for item in m.items {
		if item.kind == .Separator {
			y := i32(item.rect.y + item.rect.height * 0.5)
			ui.fill(ui.rect(i32(item.rect.x) + 6, y, i32(item.rect.width) - 12, 1), ui.BORDER)
			continue
		}
		if ui.hovered(item.rect, mp) {
			ui.fill(item.rect, ui.HIGHLIGHT)
		}
		ui.text(
			item.label,
			i32(item.rect.x) + 12,
			i32(item.rect.y) + 5,
			ui.BODY,
			item.kind == .Quit ? ui.ALERT : ui.TEXT,
		)
	}
}
