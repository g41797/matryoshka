package examples

import "core:fmt"
import list "core:container/intrusive/list"
import item "../../item"

// example_produce_consume allocates a mix of Event and Sensor items,
// pushes them onto an intrusive list, then pops and dispatches on id.
// Returns true if every item was processed and freed with no leaks.
example_produce_consume :: proc() -> bool {
	l: list.List

	// --- Produce: N pairs of (Event, Sensor) ---
	N :: 3
	for i in 0 ..< N {
		ev := new(Event)
		ev.poly.id = int(ItemId.Event)
		ev.code = i
		ev.message = "event"
		list.push_back(&l, &ev.poly.node)

		s := new(Sensor)
		s.poly.id = int(ItemId.Sensor)
		s.name = "sensor"
		s.value = f64(i) * 1.5
		list.push_back(&l, &s.poly.node)
	}

	// --- Consume: pop front, dispatch on id, free ---
	processed := 0
	for {
		raw := list.pop_front(&l)
		if raw == nil {
			break
		}
		// Safe: list.Node is at offset 0 of PolyNode (via `using node`).
		poly := (^item.PolyNode)(raw)

		switch ItemId(poly.id) {
		case .Event:
			ev := (^Event)(poly)
			fmt.printfln("Event:  code=%d  message=%s", ev.code, ev.message)
			free(ev)
		case .Sensor:
			s := (^Sensor)(poly)
			fmt.printfln("Sensor: name=%s  value=%f", s.name, s.value)
			free(s)
		case:
			fmt.printfln("unknown id: %d", poly.id)
			return false
		}
		processed += 1
	}

	return processed == N * 2
}
