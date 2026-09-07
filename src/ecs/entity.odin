/*
Package ecs is entity identity and lifetime, and nothing else.

The cell grid is not in here. A hex cell already has an identity -- its axial
coordinate -- and its data already lives in a chunked array indexed by that
coordinate, which is what makes ten million cells and a twelve-level pyramid
affordable. Turning cells into entities would replace an array index with a
sparse-set lookup and throw away the aggregation the pyramid is built on.

What the grid cannot express is a thing with identity that is not one per cell:
a crew that moves between cells, a truck partway along a route, a fire front, a
stand carrying an age. Those are entities, there are thousands of them rather
than millions, and they are what this package is for.

The registry owns ids. Component storage is a `Pool`, and a domain owns its own
pools rather than registering them here -- the same rule `sim` already follows
for system state, and what keeps this package free of every domain's types.
*/
package ecs

/*
A handle to an entity.

The generation makes a stale handle detectable: despawning bumps the slot's
generation, so a handle held across a despawn no longer matches and `alive`
says so. Without it, a recycled index would silently address whatever entity
took the slot over.
*/
Entity :: struct {
	index:      u32,
	generation: u32,
}

// The handle that never refers to anything. Generations start at one, so a
// zeroed Entity is always dead.
NIL :: Entity{0, 0}

Registry :: struct {
	// Current generation per slot. Index 0 is never handed out, so that a
	// zeroed struct field reads as NIL rather than as entity zero.
	generations: [dynamic]u32,
	// Slots whose entity was despawned, ready to be handed out again.
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

/*
Retires an entity, invalidating every handle to it.

`ok` is false when the handle was already dead. Despawning twice is a bug in
the caller, and saying so is the whole reason the generation is carried: the
alternative is to bump a live entity's generation and quietly destroy a
different object than the one that was asked for.

Component pools are not touched. The domain that owns a pool removes its own
rows, because this package does not know they exist.
*/
despawn :: proc(r: ^Registry, e: Entity) -> (ok: bool) {
	if !alive(r^, e) {
		return false
	}
	// Wrapping is deliberate: a slot reused four billion times would otherwise
	// stall on a saturated generation and stop detecting stale handles at all.
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

// How many slots have ever been handed out, which is the length a pool's
// sparse array needs to address every live entity.
slot_count :: proc(r: Registry) -> int {
	return len(r.generations)
}
