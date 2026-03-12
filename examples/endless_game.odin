package examples

import mbox ".."
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

// endless_game_example shows 4 threads passing a single heap-allocated message in a circle.
//
// Player 1 → Player 2 → Player 3 → Player 4 → Player 1
//
// After 10,000 rolls the game is won.
// The dice is allocated once and freed after all threads exit.
endless_game_example :: proc() -> bool {
	ROLLS :: 10_000
	PLAYERS :: 4

	mboxes: [PLAYERS]mbox.Mailbox(Dice)
	players: [PLAYERS]Player
	threads: [PLAYERS]^thread.Thread
	done: sync.Sema

	for i in 0 ..< PLAYERS {
		players[i] = {
			id      = i + 1,
			in_mb   = &mboxes[i],
			next_mb = &mboxes[(i + 1) % PLAYERS],
			total   = ROLLS,
			done    = &done,
		}
	}

	for i in 0 ..< PLAYERS {
		threads[i] = thread.create_and_start_with_poly_data(&players[i], proc(p: ^Player) {
			for {
				dice, err := mbox.wait_receive(p.in_mb)
				if err != .None {
					break
				}

				// Player 1 counts each full round.
				if p.id == 1 {
					dice.rolls += 1
				}

				if dice.rolls >= p.total {
					sync.sema_post(p.done)
					mbox.send(p.next_mb, dice)
					return
				}

				mbox.send(p.next_mb, dice)
			}
		})
	}

	// Allocate the dice on the heap. One object, lives until free() below.
	the_dice := new(Dice)
	mbox.send(&mboxes[0], the_dice)

	sync.sema_wait(&done)

	// Close all mailboxes — threads will exit on next wait_receive.
	for i in 0 ..< PLAYERS {
		_, _ = mbox.close(&mboxes[i])
	}

	for i in 0 ..< PLAYERS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	// All threads are done. Read result and free.
	result := the_dice.rolls >= ROLLS
	free(the_dice)
	return result
}
