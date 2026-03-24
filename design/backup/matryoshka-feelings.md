# Matryoshka — how it feels to use

You start simple.

You need threads to talk.
You just want to send something and receive it.

You write a struct.
You add `PolyNode`.
You set `id`.

It works.

---

You send a message.

You forget who owns it.

You touch it after send.

It breaks.

Not always.
Sometimes under load.
Sometimes later.

You look at it.

You see:
- you lost ownership
- nothing stopped you

You fix it.

You remember.

---

You receive a message.

You forget to return it.

It works.
Until memory grows.

You add cleanup.

You forget one path.

It leaks again.

You fix it again.

You start to see:
- every path must end
- every item must go somewhere

---

You add timeout.

Now behavior changes.

Sometimes nothing arrives.
Sometimes it is late.

You handle `.Timeout`.

You realize:
- absence is also a state

---

You add interrupt.

You wake a thread.

No message.

At first it feels strange.

Then you see:
- not every signal carries data

---

You close mailbox.

You get remaining items.

You did not expect them.

They were “in flight”.

Now they are yours again.

You must decide:
- reuse
- free

You understand:
- shutdown is part of normal flow

---

At some point allocations hurt.

Not always.

Only under pressure.

You add pool.

First version is simple.

It works.

Then:
- too many items
- or not enough

You add limits.

You write `on_put`.

You start to decide:
- keep
- drop

You see:
- reuse is not free
- it needs policy

---

You look back at your first code.

You don’t like it.

You rewrite it.

Nothing forces you to keep it.

You keep only:
- what you learned

---

You may not use pool.

It is fine.

You may not use Master.

It is fine.

You may write your own roles.

It is fine.

---

What stays:

- item has owner
- transfer is explicit
- item lives in one place
- every path must end

---

You make mistakes.

You send twice.

You forget to return.

You use wrong id.

It fails.

Not silently.

You see it.

You fix it.

---

Over time:

- you stop guessing ownership
- you stop leaking paths
- you think about shutdown early

---

Matryoshka does not protect you.

It does not hide problems.

It shows them early.

---

You can throw your code away.

You cannot throw away understanding.

---

Use what you need.

Stop when it is enough.

Go deeper when it hurts.

---

It is small.

It stays out of your way.

It is there when things become real.
```
