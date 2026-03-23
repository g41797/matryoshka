//+test
package hooks_tests

import "core:testing"
import item "../../item"
import ex   "../../examples/hooks"

@(test)
test_factory_event :: proc(t: ^testing.T) {
	fp := ex.make_ctor_dtor()
	m := fp.ctor(int(ex.ItemId.Event))
	testing.expect(t, m != nil, "ctor(Event) must return non-nil")
	ptr, ok := m.?
	testing.expect(t, ok, "Maybe must unwrap")
	testing.expect(t, ptr.id == int(ex.ItemId.Event), "ctor must set id == Event")
	// Clean up.
	fp.dtor(&m)
}

@(test)
test_factory_sensor :: proc(t: ^testing.T) {
	fp := ex.make_ctor_dtor()
	m := fp.ctor(int(ex.ItemId.Sensor))
	testing.expect(t, m != nil, "ctor(Sensor) must return non-nil")
	ptr, ok := m.?
	testing.expect(t, ok, "Maybe must unwrap")
	testing.expect(t, ptr.id == int(ex.ItemId.Sensor), "ctor must set id == Sensor")
	fp.dtor(&m)
}

@(test)
test_factory_unknown :: proc(t: ^testing.T) {
	fp := ex.make_ctor_dtor()
	m := fp.ctor(99)
	testing.expect(t, m == nil, "ctor(unknown id) must return nil")
}

@(test)
test_dispose :: proc(t: ^testing.T) {
	fp := ex.make_ctor_dtor()
	m := fp.ctor(int(ex.ItemId.Event))
	testing.expect(t, m != nil, "ctor must succeed before dtor test")
	fp.dtor(&m)
	testing.expect(t, m == nil, "dtor must set handle to nil")
}

@(test)
test_roundtrip :: proc(t: ^testing.T) {
	fp := ex.make_ctor_dtor()

	// Event roundtrip
	m_ev := fp.ctor(int(ex.ItemId.Event))
	testing.expect(t, m_ev != nil, "Event ctor must succeed")
	fp.dtor(&m_ev)
	testing.expect(t, m_ev == nil, "Event dtor must nil the handle")

	// Sensor roundtrip
	m_s := fp.ctor(int(ex.ItemId.Sensor))
	testing.expect(t, m_s != nil, "Sensor ctor must succeed")
	fp.dtor(&m_s)
	testing.expect(t, m_s == nil, "Sensor dtor must nil the handle")
}

@(test)
test_dispose_nil_handle :: proc(t: ^testing.T) {
	// dtor must be safe when called with a nil Maybe value (m^ == nil).
	fp := ex.make_ctor_dtor()
	m: Maybe(^item.PolyNode) = nil
	fp.dtor(&m) // must not crash
	testing.expect(t, m == nil, "dtor on nil handle must leave it nil")
}
