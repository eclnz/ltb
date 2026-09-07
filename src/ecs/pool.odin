package ecs

/*
A component pool: a sparse set of `T`, one row per entity that has one.

Values live in a dense array with no holes, so a system that reads every value
walks contiguous memory, which is the only reason to write an ECS rather than a
map. `sparse` maps an entity's slot to its row; `entities` maps a row back, so
a removal can move the last row into the hole and fix its back-reference in
constant time.

Rows are unordered, and a removal reorders them. Anything that needs a stable
order must sort what it collects rather than relying on insertion order.
*/
Pool :: struct($T: typeid) {
	// Entity slot -> row, or NO_ROW.
	sparse:   [dynamic]u32,
	// Row -> entity. Parallel to `values`.
	entities: [dynamic]Entity,
	values:   [dynamic]T,
}

NO_ROW :: max(u32)

pool_init :: proc(p: ^Pool($T), capacity := 64, allocator := context.allocator) {
	p.sparse = make([dynamic]u32, 0, capacity, allocator)
	p.entities = make([dynamic]Entity, 0, capacity, allocator)
	p.values = make([dynamic]T, 0, capacity, allocator)
}

pool_destroy :: proc(p: ^Pool($T)) {
	delete(p.sparse)
	delete(p.entities)
	delete(p.values)
	p^ = {}
}

pool_len :: proc(p: Pool($T)) -> int {
	return len(p.values)
}

pool_has :: proc(p: Pool($T), e: Entity) -> bool {
	if int(e.index) >= len(p.sparse) {
		return false
	}
	row := p.sparse[e.index]
	// The row must also agree about which entity it holds: a slot recycled
	// after a despawn keeps its old sparse entry until something overwrites it.
	return row != NO_ROW && p.entities[row] == e
}

/*
Attaches a value to an entity.

`ok` is false when the entity already has one. Adding twice is a caller bug --
two systems each believing they own the component -- and overwriting would hide
it behind whichever ran last. Use `pool_set` to deliberately replace.
*/
pool_add :: proc(p: ^Pool($T), e: Entity, value: T) -> (ok: bool) {
	if pool_has(p^, e) {
		return false
	}
	for int(e.index) >= len(p.sparse) {
		append(&p.sparse, NO_ROW)
	}
	p.sparse[e.index] = u32(len(p.values))
	append(&p.entities, e)
	append(&p.values, value)
	return true
}

// Attaches or replaces, for a caller that means to overwrite.
pool_set :: proc(p: ^Pool($T), e: Entity, value: T) {
	if ptr, found := pool_get(p, e); found {
		ptr^ = value
		return
	}
	pool_add(p, e, value)
}

/*
The entity's value, by pointer so a system can write it in place.

`found` is false when the entity has no such component. There is no zero value
returned to carry on with: a system reading a component that is not there is
asking about something it has no business assuming.
*/
pool_get :: proc(p: ^Pool($T), e: Entity) -> (value: ^T, found: bool) {
	if !pool_has(p^, e) {
		return nil, false
	}
	return &p.values[p.sparse[e.index]], true
}

/*
Detaches the entity's value.

The last row is moved into the hole so the dense arrays stay packed, which is
why row order is not stable across removals.
*/
pool_remove :: proc(p: ^Pool($T), e: Entity) -> (ok: bool) {
	if !pool_has(p^, e) {
		return false
	}
	row := p.sparse[e.index]
	last := u32(len(p.values) - 1)
	if row != last {
		moved := p.entities[last]
		p.entities[row] = moved
		p.values[row] = p.values[last]
		p.sparse[moved.index] = row
	}
	pop(&p.entities)
	pop(&p.values)
	p.sparse[e.index] = NO_ROW
	return true
}

// The entities holding a component, and their values, in matching row order.
// Both are the pool's own storage: they are invalidated by any add or remove.
pool_entities :: proc(p: Pool($T)) -> []Entity {
	return p.entities[:]
}

pool_values :: proc(p: ^Pool($T)) -> []T {
	return p.values[:]
}

/*
Drops every row whose entity has been despawned.

A pool cannot notice a despawn on its own -- the registry does not know the
pool exists -- so a domain that despawns entities calls this to reclaim their
rows. Until it does, `pool_has` still answers false for them, so nothing reads
a dead entity's value; the rows just take up space.
*/
pool_compact :: proc(p: ^Pool($T), r: Registry) -> (dropped: int) {
	row := 0
	for row < len(p.entities) {
		if alive(r, p.entities[row]) {
			row += 1
			continue
		}
		// pool_remove swaps the last row in, so this row must be re-examined
		// rather than stepped over.
		pool_remove(p, p.entities[row])
		dropped += 1
	}
	return
}

/*
The entities in `p` that also have a component in `q`.

Iteration walks the smaller pool and tests membership in the larger, so a query
costs the size of the rarest component rather than the commonest. The result is
allocated in `allocator`, which for a per-tick query should be
`context.temp_allocator`.
*/
pool_join :: proc(
	p: Pool($T),
	q: Pool($U),
	allocator := context.allocator,
) -> []Entity {
	out := make([dynamic]Entity, 0, min(pool_len(p), pool_len(q)), allocator)
	if pool_len(p) <= pool_len(q) {
		for e in p.entities {
			if pool_has(q, e) {
				append(&out, e)
			}
		}
	} else {
		for e in q.entities {
			if pool_has(p, e) {
				append(&out, e)
			}
		}
	}
	return out[:]
}
