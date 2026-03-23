/*
Package examples_hooks — Ctor_Dtor examples for Event + Sensor

Provides a concrete Ctor_Dtor for two item types:

  - Event:  carries a numeric code and a human-readable message.
  - Sensor: carries a name and a floating-point measurement.

make_ctor_dtor() returns a ready-to-use Ctor_Dtor with ctor and
dtor set; on_get and on_put are nil when not needed.

No pool — just Ctor_Dtor in action.
*/
package examples_hooks
