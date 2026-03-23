/*
These examples show how to use mixed-type items in practice:

  - produce_consume: allocate mixed-type items, push to an intrusive list,
    pop and dispatch on id, then free.

  - ownership: use Maybe(^item.PolyNode) as an ownership handle at the
    push/pop boundary.

*/
package examples
