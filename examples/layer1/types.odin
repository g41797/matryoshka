package examples_layer1

import matryoshka "../.."

// Alias for matryoshka.PolyNode — shortens usage across this package.
PolyNode :: matryoshka.PolyNode

// Alias for matryoshka.MayItem — ownership handle.
MayItem :: matryoshka.MayItem

// ItemId identifies the concrete type stored behind a PolyNode.
// Values must be != 0; 0 is always invalid (zero value of int).
ItemId :: enum int {
	Event  = 1,
	Sensor = 2,
}

// Event carries a numeric code and a human-readable message.
Event :: struct {
	using poly: PolyNode, // offset 0 — required for safe cast
	code:       int,
	message:    string,
}

// Sensor carries a name and a floating-point measurement.
Sensor :: struct {
	using poly: PolyNode, // offset 0 — required for safe cast
	name:       string,
	value:      f64,
}
