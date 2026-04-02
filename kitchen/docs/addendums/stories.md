# Stories

## The site name problem

The site is named "Matryoshka — Layered Inter-Thread Communication."  
The name advertises a mechanism.  
The content teaches an insight.

A reader coming from the name expects a messaging library.  
A reader of the docs discovers an ownership model.

The name undersells the real value.

---

## What the files actually say

Both README and `problem2solve.md` center on one question:

> You called the function. Did your pointer go through — or is it still yours?

The real rules, from the README:

- ownership is visible
- data moves
- nothing is shared

Inter-thread messaging (Mailbox) is Doll 2 of 4.  
It is not the primary concept.  
`^MayItem` — visible ownership at every call site — is.

---

## The Odin community

Odin's dominant audience is game developers.  
Their threading model is simple: main thread, worker pool, known data types.  
They roll their own job queue in 50 lines.  
They do not feel the pain matryoshka solves.

The Odin forum thread "What's holding Odin back?" is evidence.  
Developers list missing language features and syntax debates.  
Nobody mentions: lack of server-side project culture, tests, CI/CD patterns, libraries for long-running services.

That is not a cult.  
That is a blind spot.  
The community does not know what it does not have.  
Nobody has built it in the open yet.

---

## The story behind the project

Some years ago, after a microservices failure, a realization:

Most of a programming career was spent building modular monoliths.  
Not by design.  
By accumulation.

The conclusion:

- You do not need super-duper infrastructure.
- You need simple, understandable kits.
- Simple and understandable does not mean for everyone.
- It requires knowledge and discipline.

---

## The pattern: checking the niche

The same exploration was done with Zig.  
The project was tofu: [Tofu — Asynchronous Messaging for Boring Systems](https://ziggit.dev/t/tofu-asynchronous-messaging-for-boring-systems/14517).  
The question was: can Zig be used for boring server-side systems?  
The answer: checked. Maybe yes. Maybe no. The niche was mapped.

Matryoshka is the same expedition, in Odin.  
It is building blocks for otofu — an Odin port of tofu.  
The question: can Odin be used for boring systems at all?

Not: will everyone use it.  
Not: will the game dev community adopt it.  
Just: is it possible? Is the niche real?

---

## What "boring systems" means

"Boring" is a precision term, not self-deprecation.

- Correctness matters more than cleverness.
- The system runs for years, not frames.
- Ownership of data is serious.
- A race condition is a production incident.

That is exactly what `^MayItem` addresses.  
Ownership visible at every call site.  
Because in boring systems, "I forgot to check" costs real money.

---

## The positioning fix

The Zig post title was direct: "Asynchronous Messaging for Boring Systems."  
It said who the project is for.  
It said what it solves.  
It did not oversell.

The current site name "Layered Inter-Thread Communication" sounds like an ingredient.  
It does not say who needs it or why.

A more honest name: "Matryoshka — Building Blocks for Boring Systems in Odin."  
Narrow. Honest. Findable by exactly the person who needs it.

---

## What this project is not

- Not trying to replace the Odin standard library.
- Not trying to win the game dev community.
- Not a port of a Go framework.

## What this project is

- A proof: Odin is a general-purpose language, not just a game language.
- A foundation: building blocks for server-side, event-driven, long-running Odin systems.
- Evidence: left for the next person who asks "can Odin do this?"
