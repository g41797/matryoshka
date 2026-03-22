/*
Package hooks_tests — integration tests for hooks examples.

Calls make_ctor_dtor() and invokes ctor and dtor directly,
without a pool.  Verifies that:

  - ctor allocates the correct type for known ids.
  - ctor returns nil for unknown ids.
  - dtor frees the allocation and sets the handle to nil.
  - roundtrip (ctor → dtor) leaves no handle.
*/
package hooks_tests
