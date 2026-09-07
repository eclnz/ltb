/*
Package ecs is entity identity and lifetime, and nothing else.

The registry owns ids. Component storage is a `Pool`, and a domain owns its own
pools rather than registering them here -- the same rule `sim` already follows
for system state, and what keeps this package free of every domain's types.
*/
package ecs

Entity :: struct {
	index:      u32,
	generation: u32,
}

// The handle that never refers to anything. Generations start at one, so a
// zeroed Entity is always dead.
NIL :: Entity{0, 0}

Registry :: struct {
	generations: [dynamic]u32,
	free:        [dynamic]u32,
	alive:       int,
}

init :: proc(r: ^Registry, capacity := 256, allocator := context.allocator) {
	r.generations = make([dynamic]u32, 1, capacity, allocator)
	r.free = make([dynamic]u32, 0, capacity, allocator)
	r.alive = 0
}

destroy :: proc(r: ^Registry) {
	delete(r.generations)
	delete(r.free)
	r^ = {}
}

spawn :: proc(r: ^Registry) -> Entity {
	r.alive += 1
	if len(r.free) > 0 {
		index := pop(&r.free)
		return Entity{index, r.generations[index]}
	}
	index := u32(len(r.generations))
	append(&r.generations, u32(1))
	return Entity{index, 1}
}

despawn :: proc(r: ^Registry, e: Entity) -> (ok: bool) {
	if !alive(r^, e) {
		return false
	}
	r.generations[e.index] += 1
	if r.generations[e.index] == 0 {
		r.generations[e.index] = 1
	}
	append(&r.free, e.index)
	r.alive -= 1
	return true
}

alive :: proc(r: Registry, e: Entity) -> bool {
	if e.index == 0 || int(e.index) >= len(r.generations) {
		return false
	}
	return r.generations[e.index] == e.generation
}

slot_count :: proc(r: Registry) -> int {
	return len(r.generations)
}
