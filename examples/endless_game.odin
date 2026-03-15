package examples

import mbox "../mbox"
import list "core:container/intrusive/list"
import "core:sync"
import "core:thread"

// Dice is the object passed between players.
// One allocation. Never replaced during the game.
Dice :: struct {
	node:  list.Node,
	rolls: int,
}

// Player represents a thread at the table.
Player :: struct {
	id:      int,
	in_mb:   ^mbox.Mailbox(Dice),
	next_mb: ^mbox.Mailbox(Dice),
	total:   int,
	done:    ^sync.Sema,
}

@(private)
_Endless_Game_Master :: struct {
	mboxes: [4]mbox.Mailbox(Dice),
	players: [4]Player,
	threads: [4]^thread.Thread,
	done: sync.Sema,
}

// create_endless_game_master is a factory proc that demonstrates Idiom 11: errdefer-dispose.
// [itc: errdefer-dispose]
create_endless_game_master :: proc() -> (m: ^_Endless_Game_Master, ok: bool) {
	raw := new(_Endless_Game_Master) // [itc: heap-master]
	if raw == nil { return }

	m_opt: Maybe(^_Endless_Game_Master) = raw
	defer if !ok { _endless_game_dispose(&m_opt) }

	// ... potential further setup ...

	m = raw
	ok = true
	return
}

@(private)
_endless_game_dispose :: proc(m: ^Maybe(^_Endless_Game_Master)) { // [itc: dispose-contract]
	mp, ok := m.?
	if !ok || mp == nil {return}
	
	for i in 0 ..< 4 {
		remaining, _ := mbox.close(&mp.mboxes[i])
		for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
			dice := (^Dice)(node)
			free(dice)
		}
	}
	free(mp)
	m^ = nil
}

// endless_game_example shows 4 threads passing a single heap-allocated message in a circle.
endless_game_example :: proc() -> bool {
	ROLLS :: 10_000
	PLAYERS :: 4

	m, ok := create_endless_game_master()
	if !ok {
		return false
	}
	m_opt: Maybe(^_Endless_Game_Master) = m
	defer _endless_game_dispose(&m_opt) // [itc: defer-dispose]

	for i in 0 ..< PLAYERS {
		m.players[i] = {
			id      = i + 1,
			in_mb   = &m.mboxes[i],
			next_mb = &m.mboxes[(i + 1) % PLAYERS],
			total   = ROLLS,
			done    = &m.done,
		}
	}

	for i in 0 ..< PLAYERS {
		m.threads[i] = thread.create_and_start_with_poly_data(&m.players[i], proc(p: ^Player) { // [itc: thread-container]
			for {
				dice, err := mbox.wait_receive(p.in_mb)
				if err != .None {
					break
				}

				// Player 1 counts each full round.
				if p.id == 1 {
					dice.rolls += 1
				}

				game_done := dice.rolls >= p.total
				dice_opt: Maybe(^Dice) = dice // [itc: maybe-container]
				ok := mbox.send(p.next_mb, &dice_opt)
				if game_done {
					sync.sema_post(p.done)
					return
				}
				if !ok {
					return
				}
			}
		})
	}

	// Allocate the dice on the heap. One object, lives until free() in dispose.
	the_dice_ptr := new(Dice)
	the_dice: Maybe(^Dice) = the_dice_ptr // [itc: maybe-container]
	if !mbox.send(&m.mboxes[0], &the_dice) {
		free(the_dice_ptr)
		return false
	}

	sync.sema_wait(&m.done)

	for i in 0 ..< PLAYERS {
		thread.join(m.threads[i])
		thread.destroy(m.threads[i])
	}

	return the_dice_ptr.rolls >= ROLLS
}
