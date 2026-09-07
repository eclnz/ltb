package ecs

import "core:slice"
import "core:testing"

Position :: struct {
	x, y: f64,
}

Velocity :: struct {
	dx, dy: f64,
}

@(test)
test_spawn_gives_distinct_live_handles :: proc(t: ^testing.T) {
	r: Registry
	init(&r)
	defer destroy(&r)

	a := spawn(&r)
	b := spawn(&r)
	testing.expect(t, a != b, "two spawns returned the same handle")
	testing.expect(t, alive(r, a) && alive(r, b))
	testing.expect_value(t, r.alive, 2)
	// Slot zero is reserved so that a zeroed struct field reads as dead.
	testing.expect(t, !alive(r, NIL), "the nil handle must never be alive")
}

@(test)
test_despawn_invalidates_the_handle :: proc(t: ^testing.T) {
	r: Registry
	init(&r)
	defer destroy(&r)

	e := spawn(&r)
	testing.expect(t, despawn(&r, e))
	testing.expect(t, !alive(r, e), "a despawned handle is still alive")
	testing.expect_value(t, r.alive, 0)

	// Despawning twice is a caller bug and is reported, not absorbed.
	testing.expect(t, !despawn(&r, e), "despawning twice reported success")
}

@(test)
test_recycled_slot_does_not_answer_to_the_old_handle :: proc(t: ^testing.T) {
	r: Registry
	init(&r)
	defer destroy(&r)

	old := spawn(&r)
	despawn(&r, old)
	new := spawn(&r)

	// The slot is reused, so without the generation these would be equal and
	// the stale handle would silently address the new entity.
	testing.expect_value(t, new.index, old.index)
	testing.expect(t, new.generation != old.generation, "the generation did not advance")
	testing.expect(t, alive(r, new))
	testing.expect(t, !alive(r, old), "a stale handle addressed the recycled slot")
}

@(test)
test_pool_add_get_remove :: proc(t: ^testing.T) {
	r: Registry
	init(&r)
	defer destroy(&r)
	p: Pool(Position)
	pool_init(&p)
	defer pool_destroy(&p)

	e := spawn(&r)
	testing.expect(t, !pool_has(p, e), "an entity has a component before one was added")
	_, found := pool_get(&p, e)
	testing.expect(t, !found, "getting an absent component reported success")

	testing.expect(t, pool_add(&p, e, Position{1, 2}))
	got := (^Position)(nil)
	got, found = pool_get(&p, e)
	testing.expect(t, found)
	testing.expect_value(t, got^, Position{1, 2})

	// Written through the pointer, so a system can update in place.
	got.x = 9
	got, _ = pool_get(&p, e)
	testing.expect_value(t, got.x, 9.0)

	testing.expect(t, pool_remove(&p, e))
	testing.expect(t, !pool_has(p, e))
	testing.expect_value(t, pool_len(p), 0)
	testing.expect(t, !pool_remove(&p, e), "removing twice reported success")
}

@(test)
test_pool_add_twice_is_refused :: proc(t: ^testing.T) {
	r: Registry
	init(&r)
	defer destroy(&r)
	p: Pool(Position)
	pool_init(&p)
	defer pool_destroy(&p)

	e := spawn(&r)
	testing.expect(t, pool_add(&p, e, Position{1, 1}))
	// Two systems each believing they own the component must not silently
	// overwrite one another.
	testing.expect(t, !pool_add(&p, e, Position{5, 5}), "a second add was accepted")

	v, _ := pool_get(&p, e)
	testing.expect_value(t, v^, Position{1, 1})

	// pool_set is the deliberate overwrite.
	pool_set(&p, e, Position{5, 5})
	v, _ = pool_get(&p, e)
	testing.expect_value(t, v^, Position{5, 5})
}

@(test)
test_removal_keeps_rows_packed :: proc(t: ^testing.T) {
	r: Registry
	init(&r)
	defer destroy(&r)
	p: Pool(Position)
	pool_init(&p)
	defer pool_destroy(&p)

	es: [5]Entity
	for &e, i in es {
		e = spawn(&r)
		pool_add(&p, e, Position{f64(i), 0})
	}
	// Remove from the middle: the last row is swapped in behind it.
	testing.expect(t, pool_remove(&p, es[1]))
	testing.expect_value(t, pool_len(p), 4)

	// Every surviving entity still resolves to its own value, whatever row it
	// was moved to.
	for e, i in es {
		if i == 1 {
			testing.expect(t, !pool_has(p, e))
			continue
		}
		v, found := pool_get(&p, e)
		testing.expect(t, found)
		testing.expect_value(t, v.x, f64(i))
	}
	testing.expect_value(t, len(pool_values(&p)), 4)
}

@(test)
test_stale_handle_does_not_read_a_recycled_entitys_component :: proc(t: ^testing.T) {
	r: Registry
	init(&r)
	defer destroy(&r)
	p: Pool(Position)
	pool_init(&p)
	defer pool_destroy(&p)

	old := spawn(&r)
	pool_add(&p, old, Position{1, 1})
	despawn(&r, old)

	// The row is still there -- the registry cannot tell the pool about the
	// despawn -- but the stale handle must not reach it.
	new := spawn(&r)
	testing.expect_value(t, new.index, old.index)
	testing.expect(t, !pool_has(p, new), "the recycled entity inherited a component")

	dropped := pool_compact(&p, r)
	testing.expect_value(t, dropped, 1)
	testing.expect_value(t, pool_len(p), 0)
}

@(test)
test_compact_drops_only_dead_rows :: proc(t: ^testing.T) {
	r: Registry
	init(&r)
	defer destroy(&r)
	p: Pool(Position)
	pool_init(&p)
	defer pool_destroy(&p)

	live, dead: [dynamic]Entity
	defer delete(live)
	defer delete(dead)
	for i in 0 ..< 10 {
		e := spawn(&r)
		pool_add(&p, e, Position{f64(i), 0})
		if i % 3 == 0 {
			append(&dead, e)
		} else {
			append(&live, e)
		}
	}
	for e in dead {
		despawn(&r, e)
	}

	testing.expect_value(t, pool_compact(&p, r), len(dead))
	testing.expect_value(t, pool_len(p), len(live))
	for e in live {
		testing.expect(t, pool_has(p, e), "compact dropped a live entity")
	}
}

@(test)
test_join_returns_the_intersection :: proc(t: ^testing.T) {
	r: Registry
	init(&r)
	defer destroy(&r)
	pos: Pool(Position)
	vel: Pool(Velocity)
	pool_init(&pos)
	pool_init(&vel)
	defer pool_destroy(&pos)
	defer pool_destroy(&vel)

	both: [dynamic]Entity
	defer delete(both)
	for i in 0 ..< 12 {
		e := spawn(&r)
		pool_add(&pos, e, Position{f64(i), 0})
		// A third of them also move, so the join walks the smaller pool.
		if i % 3 == 0 {
			pool_add(&vel, e, Velocity{1, 0})
			append(&both, e)
		}
	}

	got := pool_join(pos, vel, context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, len(got), len(both))

	// Row order is not stable, so compare as sets.
	slice.sort_by(got, proc(a, b: Entity) -> bool {return a.index < b.index})
	slice.sort_by(both[:], proc(a, b: Entity) -> bool {return a.index < b.index})
	testing.expect(t, slice.equal(got, both[:]), "join did not return the intersection")

	// Both argument orders describe the same set.
	flipped := pool_join(vel, pos, context.temp_allocator)
	testing.expect_value(t, len(flipped), len(both))
}
