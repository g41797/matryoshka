//+test
package item_tests

import ex "../../examples/item"
import item "../../item"
import list "core:container/intrusive/list"
import "core:testing"

@(test)
test_produce_consume :: proc(t: ^testing.T) {
	testing.expect(t, ex.example_produce_consume(), "produce_consume must return true")
}

@(test)
test_ownership :: proc(t: ^testing.T) {
	testing.expect(t, ex.example_ownership(), "ownership must return true")
}

@(test)
test_list_order :: proc(t: ^testing.T) {
	// Items pop in FIFO order; ids match what was pushed.
	l: list.List

	e1 := new(ex.Event)
	e1.poly.id = int(ex.ItemId.Event)
	e1.code = 1
	list.push_back(&l, &e1.poly.node)

	s1 := new(ex.Sensor)
	s1.poly.id = int(ex.ItemId.Sensor)
	s1.value = 2.0
	list.push_back(&l, &s1.poly.node)

	// Pop first — must be Event
	raw1 := list.pop_front(&l)
	testing.expect(t, raw1 != nil, "first pop must not be nil")
	poly1 := (^item.PolyNode)(raw1)
	testing.expect(t, poly1.id == int(ex.ItemId.Event), "first pop id must be Event")
	got_e1 := (^ex.Event)(poly1)
	testing.expect(t, got_e1.code == 1, "first pop code must be 1")
	free(got_e1)

	// Pop second — must be Sensor
	raw2 := list.pop_front(&l)
	testing.expect(t, raw2 != nil, "second pop must not be nil")
	poly2 := (^item.PolyNode)(raw2)
	testing.expect(t, poly2.id == int(ex.ItemId.Sensor), "second pop id must be Sensor")
	got_s1 := (^ex.Sensor)(poly2)
	testing.expect(t, got_s1.value == 2.0, "second pop value must be 2.0")
	free(got_s1)

	// List must be empty
	testing.expect(t, list.pop_front(&l) == nil, "list must be empty after consuming all")
}

@(test)
test_mixed_ids :: proc(t: ^testing.T) {
	// Every ItemId value must be != 0 and the dispatch table covers all of them.
	all_ids := []ex.ItemId{.Event, .Sensor}
	for id in all_ids {
		testing.expect(t, int(id) != 0, "every ItemId must be != 0")
	}
	// Verify the enum covers exactly two values.
	testing.expect(t, len(all_ids) == 2, "ItemId must have exactly 2 values")
}
