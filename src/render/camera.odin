/*
Package render draws the world with raylib.

The renderer never walks the whole world. It asks the pyramid which level suits
the current zoom, converts the viewport to axial bounds at that level, and draws
only what is inside them. Zooming out therefore costs no more than zooming in:
the cells get bigger and there are no more of them on screen.
*/
package render

import "core:math"
import geo "ltb:geo"
import hex "ltb:hex"
import "ltb:world"

// A 2D map camera in projected metres.
Camera :: struct {
	// World position at the centre of the viewport, in projected metres.
	center:           geo.Point,
	// Zoom, expressed the way map people expect: ground metres per screen pixel.
	metres_per_pixel: f64,
	// Viewport size in pixels.
	screen:           [2]f64,
	// Clamps, so scroll wheels cannot leave the world behind.
	min_mpp:          f64,
	max_mpp:          f64,
}

camera_init :: proc(c: ^Camera, w: ^world.World, screen_w, screen_h: int) {
	c.screen = {f64(screen_w), f64(screen_h)}
	c.center = geo.forward(w.projection, geo.geo_bounds_center(w.bounds))
	// Start framed on the whole world.
	mn, mx := world.world_extent_metres(w)
	span := math.max(mx.x - mn.x, mx.y - mn.y)
	c.metres_per_pixel = math.max(span / math.max(c.screen.x, c.screen.y), 1.0)
	c.min_mpp = world.level_resolution(w, 0) / 64.0
	c.max_mpp = math.max(c.metres_per_pixel * 4.0, c.min_mpp * 2.0)
}

camera_resize :: proc(c: ^Camera, screen_w, screen_h: int) {
	c.screen = {f64(screen_w), f64(screen_h)}
}

// Projected metres to screen pixels. Screen y grows downwards; world y grows
// north, so the sign flips.
world_to_screen :: #force_inline proc "contextless" (c: ^Camera, p: geo.Point) -> [2]f32 {
	return [2]f32 {
		f32((p.x - c.center.x) / c.metres_per_pixel + c.screen.x * 0.5),
		f32((c.center.y - p.y) / c.metres_per_pixel + c.screen.y * 0.5),
	}
}

screen_to_world :: #force_inline proc "contextless" (c: ^Camera, s: [2]f64) -> geo.Point {
	return geo.Point {
		c.center.x + (s.x - c.screen.x * 0.5) * c.metres_per_pixel,
		c.center.y - (s.y - c.screen.y * 0.5) * c.metres_per_pixel,
	}
}

// Pans by a screen-space delta, which is what a mouse drag produces.
camera_pan_pixels :: proc(c: ^Camera, dx, dy: f64) {
	c.center.x -= dx * c.metres_per_pixel
	c.center.y += dy * c.metres_per_pixel
}

// Zooms by a multiplicative factor, keeping the world point under `anchor`
// (in screen pixels) fixed.
camera_zoom_at :: proc(c: ^Camera, factor: f64, anchor: [2]f64) {
	before := screen_to_world(c, anchor)
	c.metres_per_pixel = clamp(c.metres_per_pixel * factor, c.min_mpp, c.max_mpp)
	after := screen_to_world(c, anchor)
	c.center.x += before.x - after.x
	c.center.y += before.y - after.y
}

// Projected-metre rectangle currently visible.
camera_view_rect :: proc(c: ^Camera) -> (min, max: geo.Point) {
	half_w := c.screen.x * 0.5 * c.metres_per_pixel
	half_h := c.screen.y * 0.5 * c.metres_per_pixel
	return geo.Point{c.center.x - half_w, c.center.y - half_h},
		geo.Point{c.center.x + half_w, c.center.y + half_h}
}

// The pyramid level whose cells are large enough to be worth drawing at this
// zoom, and the axial bounds of the viewport at that level.
camera_visible :: proc(c: ^Camera, w: ^world.World, min_cell_pixels := 7.0) -> (level: int, bounds: hex.Bounds) {
	level = world.level_for_scale(w, c.metres_per_pixel, min_cell_pixels)
	mn, mx := camera_view_rect(c)
	bounds = hex.bounds_covering_rect(world.layout(w, level), mn, mx)
	return
}

// Cell under a screen position, at the level currently being drawn.
camera_pick :: proc(c: ^Camera, w: ^world.World, screen_pos: [2]f64, level: int) -> hex.Hex {
	return hex.world_to_hex(world.layout(w, level), screen_to_world(c, screen_pos))
}
