package ecs

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
	return row != NO_ROW && p.entities[row] == e
}

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

pool_set :: proc(p: ^Pool($T), e: Entity, value: T) {
	if ptr, found := pool_get(p, e); found {
		ptr^ = value
		return
	}
	pool_add(p, e, value)
}

pool_get :: proc(p: ^Pool($T), e: Entity) -> (value: ^T, found: bool) {
	if !pool_has(p^, e) {
		return nil, false
	}
	return &p.values[p.sparse[e.index]], true
}

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

pool_entities :: proc(p: Pool($T)) -> []Entity {
	return p.entities[:]
}

pool_values :: proc(p: ^Pool($T)) -> []T {
	return p.values[:]
}

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
