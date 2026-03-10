package examples

import mbox ".."
import list "core:container/intrusive/list"
import "core:sync"
import "core:thread"

// Dice is the object passed between players.
// It is never replaced or reminted during the game.
Dice :: struct {
	node: list.Node,
	rolls: int,
}

// Player represents a thread at the table.
Player :: struct {
	id:      int,
	in_mb:   ^mbox.Mailbox(Dice),
	next_mb: ^mbox.Mailbox(Dice),
	total:   int, // how many rolls to complete
	done:    ^sync.Sema,
}

// endless_game_example shows 4 threads passing a single message in a circle.
//
// Player 1 → Player 2 → Player 3 → Player 4 → Player 1
//
// After 10,000 rolls, the game is won.
// This proves we can play millions of turns with zero overhead.
endless_game_example :: proc() -> bool {
	ROLLS :: 10_000
	PLAYERS :: 4

	// Each player has their own mailbox.
	mboxes: [PLAYERS]mbox.Mailbox(Dice)
	players: [PLAYERS]Player
	threads: [PLAYERS]^thread.Thread
	done: sync.Sema

	// 1. Setup the table.
	for i in 0 ..< PLAYERS {
		players[i] = {
			id      = i + 1,
			in_mb   = &mboxes[i],
			next_mb = &mboxes[(i + 1) % PLAYERS],
			total   = ROLLS,
			done    = &done,
		}
	}

	// 2. Start all players.
	for i in 0 ..< PLAYERS {
		threads[i] = thread.create_and_start_with_poly_data(&players[i], proc(p: ^Player) {
			for {
				// Wait for the turn.
				dice, err := mbox.wait_receive(p.in_mb)
				if err != .None {
					break // table closed, exit
				}

				// If the dice return to Player 1, one full round is complete.
				if p.id == 1 {
					dice.rolls += 1
				}

				// Check if the game is won.
				if dice.rolls >= p.total {
					sync.sema_post(p.done) // signal the dealer
					// pass it one last time so others can exit or close
					mbox.send(p.next_mb, dice)
					return
				}

				// Pass the turn to the next player.
				mbox.send(p.next_mb, dice)
			}
		})
	}

	// 3. Start the game! Player 1 takes the first turn.
	the_dice := Dice{rolls = 0}
	mbox.send(&mboxes[0], &the_dice)

	// 4. Wait for the final win signal.
	sync.sema_wait(&done)

	// 5. Cleanup: close all mailboxes to stop the threads.
	for i in 0 ..< PLAYERS {
		mbox.close(&mboxes[i])
	}

	for i in 0 ..< PLAYERS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	return the_dice.rolls >= ROLLS
}
