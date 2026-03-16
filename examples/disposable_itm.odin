package examples

import mbox "../mbox"
import pool_pkg "../pool"
import list "core:container/intrusive/list"
import "core:strings"
import "core:thread"

@(private)
_Disposable_Master :: struct {
	pool: pool_pkg.Pool(DisposableItm),
	mb:   mbox.Mailbox(DisposableItm),
}

// create_disposable_master is a factory proc that demonstrates Idiom 11: errdefer-dispose.
// [itc: errdefer-dispose]
create_disposable_master :: proc() -> (m: ^_Disposable_Master, ok: bool) {
	raw := new(_Disposable_Master) // [itc: heap-master]
	if raw == nil { return }

	m_opt: Maybe(^_Disposable_Master) = raw
	// named return 'ok' is checked at exit time.
	// if post-init setup fails, dispose cleans up the partially-init master.
	defer if !ok { _disposable_master_dispose(&m_opt) }

	init_ok, _ := pool_pkg.init(&raw.pool, initial_msgs = 4, max_msgs = 0,
		hooks = DISPOSABLE_ITM_HOOKS)
	if !init_ok { return }

	m = raw
	ok = true
	return
}

@(private)
_disposable_master_dispose :: proc(m: ^Maybe(^_Disposable_Master)) { // [itc: dispose-contract]
	mp, ok := m.?
	if !ok || mp == nil { return }

	// Drain mailbox and return to pool or dispose [itc: dispose-optional]
	remaining, _ := mbox.close(&mp.mb)
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		itm := container_of(node, DisposableItm, "node")
		itm_opt: Maybe(^DisposableItm) = itm

		// Respect Idiom 6: check if accepted by pool
		ptr, accepted := pool_pkg.put(&mp.pool, &itm_opt)
		if !accepted && ptr != nil {
			// Foreign or pool closed: manual dispose [itc: foreign-dispose]
			p_opt: Maybe(^DisposableItm) = ptr
			disposable_dispose(&p_opt)
		}
	}

	pool_pkg.destroy(&mp.pool)
	free(mp)
	m^ = nil
}

// disposable_itm_example shows a full lifecycle with internal resources:
//   producer: pool.get → fill name → send
//   consumer: receive → process → pool.put (reset clears name automatically)
//
// Also shows the error path: if send fails, defer dispose handles cleanup.
// [itc: disposable-itm]
disposable_itm_example :: proc() -> bool {
	m, ok := create_disposable_master()
	if !ok {
		return false
	}
	m_opt: Maybe(^_Disposable_Master) = m
	defer _disposable_master_dispose(&m_opt) // [itc: defer-dispose]

	result := false

	// Consumer thread: receives one item, checks the name, puts back to pool.
	t := thread.create_and_start_with_poly_data(m, proc(m: ^_Disposable_Master) { // [itc: thread-container]
		itm, err := mbox.wait_receive(&m.mb)
		if err != .None || itm == nil {
			return
		}

		// Demonstrating Idiom 2: defer-put with Idiom 6: foreign-dispose
		itm_opt: Maybe(^DisposableItm) = itm // [itc: maybe-container]
		defer { // [itc: defer-put]
			ptr, accepted := pool_pkg.put(&m.pool, &itm_opt)
			if !accepted && ptr != nil {
				p_opt: Maybe(^DisposableItm) = ptr
				disposable_dispose(&p_opt) // [itc: foreign-dispose]
			}
		}

		// process: name is set
		_ = itm.name
	})

	// Producer: get from pool, fill resources, send.
	itm, status := pool_pkg.get(&m.pool)
	if status != .Ok {
		thread.join(t)
		thread.destroy(t)
		return false
	}

	itm_opt: Maybe(^DisposableItm) = itm // [itc: maybe-container]
	defer disposable_dispose(&itm_opt) // no-op if send succeeded // [itc: defer-dispose]

	itm_opt.?.name = strings.clone("hello", itm_opt.?.allocator)
	if mbox.send(&m.mb, &itm_opt) {
		result = true
	}
	// if send failed: itm is non-nil, defer dispose handles cleanup

	thread.join(t)
	thread.destroy(t)

	return result
}
