package layers

import hex "ltb:hex"

/*
Chunk addressing: which chunk a cell lives in, and where inside it.

This is arithmetic on coordinates and nothing else. It does not know that a
store exists, which is what makes it testable on its own and safe to call from
a tight loop.
*/

// Cells per chunk edge, in axial index space. A chunk is a parallelogram in
// world space, which is fine: chunks exist for storage and culling, not for
// geometry.
CHUNK_SIZE :: 64
CHUNK_AREA :: CHUNK_SIZE * CHUNK_SIZE

// Identifies one chunk of one layer at one pyramid level.
Chunk_Key :: struct {
	layer:  Layer_Id,
	level:  u8,
	cx, cy: i32,
}

Chunk :: struct {
	key:    Chunk_Key,
	data:   []byte,
	stride: int, // bytes per cell
}

// Axial coordinates go negative west and north of the origin, so chunk indices
// have to round towards minus infinity rather than towards zero -- otherwise
// the chunks either side of an axis both claim index 0 and overwrite each
// other's cells.
@(private)
floor_div :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) {
		q -= 1
	}
	return q
}

@(private)
floor_mod :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	m := a % b
	if m != 0 && ((m < 0) != (b < 0)) {
		m += b
	}
	return m
}

// The chunk containing `h`, and the cell's index within that chunk.
chunk_of :: #force_inline proc "contextless" (h: hex.Hex) -> (cx, cy: i32, index: int) {
	cx = floor_div(h.q, CHUNK_SIZE)
	cy = floor_div(h.r, CHUNK_SIZE)
	lq := floor_mod(h.q, CHUNK_SIZE)
	lr := floor_mod(h.r, CHUNK_SIZE)
	index = int(lr) * CHUNK_SIZE + int(lq)
	return
}

// Inverse of `chunk_of`.
hex_of_index :: #force_inline proc "contextless" (cx, cy: i32, index: int) -> hex.Hex {
	lq := i32(index % CHUNK_SIZE)
	lr := i32(index / CHUNK_SIZE)
	return hex.Hex{cx * CHUNK_SIZE + lq, cy * CHUNK_SIZE + lr}
}
