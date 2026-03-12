package pool

import list "core:container/intrusive/list"
import "core:testing"

// Test_Msg is the message type used in all pool tests.
Test_Msg :: struct {
	node: list.Node,
	data: int,
}

@(test)
test_pool_get_always :: proc(t: ^testing.T) {
	p: Pool(Test_Msg)
	init(&p)
	defer destroy(&p)

	// Empty pool, .Always strategy — must allocate a new message.
	msg := get(&p)
	testing.expect(t, msg != nil, "get(.Always) on empty pool should return non-nil")
	if msg != nil {
		free(msg)
	}
}

@(test)
test_pool_get_pool_only :: proc(t: ^testing.T) {
	p: Pool(Test_Msg)
	init(&p)
	defer destroy(&p)

	// Empty pool, .Pool_Only — must return nil.
	msg := get(&p, .Pool_Only)
	testing.expect(t, msg == nil, "get(.Pool_Only) on empty pool should return nil")
}

@(test)
test_pool_put_and_get :: proc(t: ^testing.T) {
	p: Pool(Test_Msg)
	init(&p)
	defer destroy(&p)

	// Put a message, then get it back.
	orig := new(Test_Msg)
	orig.data = 42
	put(&p, orig)

	got := get(&p)
	testing.expect(t, got != nil, "get after put should return non-nil")
	testing.expect(t, got == orig, "get should return the same pointer that was put")
	testing.expect(t, got.data == 42, "data should be preserved after put/get round-trip")
	if got != nil {
		free(got)
	}
}

@(test)
test_pool_respects_max :: proc(t: ^testing.T) {
	p: Pool(Test_Msg)
	init(&p, max_msgs = 2)
	defer destroy(&p)

	msg1 := new(Test_Msg)
	msg2 := new(Test_Msg)
	msg3 := new(Test_Msg)

	put(&p, msg1) // curr_msgs = 1
	put(&p, msg2) // curr_msgs = 2
	put(&p, msg3) // exceeds max — pool frees msg3

	testing.expect(t, p.curr_msgs == 2, "curr_msgs should stay at max after excess put")
}

@(test)
test_pool_preinit :: proc(t: ^testing.T) {
	p: Pool(Test_Msg)
	init(&p, initial_msgs = 4)
	defer destroy(&p)

	testing.expect(t, p.curr_msgs == 4, "curr_msgs should be 4 after init with initial_msgs=4")

	// All 4 gets should return pre-allocated messages.
	for _ in 0 ..< 4 {
		msg := get(&p, .Pool_Only)
		testing.expect(t, msg != nil, "pre-allocated get should return non-nil")
		if msg != nil {
			free(msg)
		}
	}

	// Pool is now empty.
	fifth := get(&p, .Pool_Only)
	testing.expect(t, fifth == nil, "pool should be empty after 4 gets")
}

@(test)
test_pool_closed_get :: proc(t: ^testing.T) {
	p: Pool(Test_Msg)
	init(&p)

	msg := new(Test_Msg)
	put(&p, msg) // one message in pool

	destroy(&p) // marks closed, frees pool messages

	got := get(&p)
	testing.expect(t, got == nil, "get on closed pool should return nil")
}

@(test)
test_pool_closed_put :: proc(t: ^testing.T) {
	p: Pool(Test_Msg)
	init(&p)
	destroy(&p) // closed

	msg := new(Test_Msg)
	put(&p, msg) // should free msg, not crash

	testing.expect(t, p.curr_msgs == 0, "curr_msgs should stay 0 after put on closed pool")
}

@(test)
test_pool_nil_put :: proc(t: ^testing.T) {
	p: Pool(Test_Msg)
	init(&p)
	defer destroy(&p)

	put(&p, nil) // no-op
	testing.expect(t, p.curr_msgs == 0, "curr_msgs should stay 0 after put(nil)")
}

@(test)
test_pool_destroy :: proc(t: ^testing.T) {
	p: Pool(Test_Msg)
	init(&p, initial_msgs = 2)

	destroy(&p)

	got := get(&p)
	testing.expect(t, got == nil, "get after destroy should return nil")
	testing.expect(t, p.closed, "pool should be marked closed after destroy")
}
