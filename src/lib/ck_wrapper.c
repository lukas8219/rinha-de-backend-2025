#include <ck_ring.h>
#include <stdlib.h>

// Wrapper functions to expose ConcurrencyKit's inline functions

void ck_ring_init_wrapper(struct ck_ring *ring, unsigned int size) {
    ck_ring_init(ring, size);
}

bool ck_ring_enqueue_spmc_wrapper(struct ck_ring *ring, 
                                  struct ck_ring_buffer *buffer, 
                                  const void *entry) {
    return ck_ring_enqueue_spmc(ring, buffer, entry);
}

bool ck_ring_dequeue_spmc_wrapper(struct ck_ring *ring, 
                                  struct ck_ring_buffer *buffer, 
                                  void **result) {
    return ck_ring_dequeue_spmc(ring, buffer, result);
}

unsigned int ck_ring_size_wrapper(const struct ck_ring *ring) {
    return ck_ring_size(ring);
}

unsigned int ck_ring_capacity_wrapper(const struct ck_ring *ring) {
    return ck_ring_capacity(ring);
}

// Get the actual size of the ck_ring structure
size_t ck_ring_sizeof(void) {
    return sizeof(struct ck_ring);
}

// Get the actual size of the ck_ring_buffer structure
size_t ck_ring_buffer_sizeof(void) {
    return sizeof(struct ck_ring_buffer);
} 