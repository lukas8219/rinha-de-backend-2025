# TODO
- [ ] Stop sending too much info via PubSub (might kill pubsub at all)
-- [ ] Send uuid + amount as sequence of bytes
- [X] Have shared state circuit breaker
- [ ] Lessen the memory pressure by
-- [ ] Analyze all spots that may need fine granular control of memory using LibC
-- [ ] Better JSON parsing/serializing - needs bench
-- [ ] Change `processor` to be Boolean
-- [ ] Change Batch Array in `src/consumer.cr` to be Array of Pointers - free malloc after `exec`
