#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "skiplist.h"
#include <stdint.h>

// SIMD support detection
#if defined(__ARM_NEON) || defined(__aarch64__)
    #include <arm_neon.h>
    #define SIMD_SUPPORTED 1
    #define SIMD_WIDTH 2  // ARM NEON processes 2 doubles at once
    #define SIMD_TYPE "ARM NEON"
#elif defined(__AVX2__) || defined(__x86_64__)
    #include <immintrin.h>
    #define SIMD_SUPPORTED 1
    #define SIMD_WIDTH 4  // AVX2 processes 4 doubles at once
    #define SIMD_TYPE "x86 AVX2"
#else
    #define SIMD_SUPPORTED 0
    #define SIMD_WIDTH 1
    #define SIMD_TYPE "None (scalar fallback)"
#endif

// Global counters for SIMD usage tracking
static unsigned long simd_range_calls = 0;
static unsigned long scalar_range_calls = 0;
static unsigned long total_simd_elements = 0;

// Thread-local fast random number generator
static __thread uint64_t rng_state = 1;

// Initialize thread-local RNG with unique seed
static void init_rng(void) {
    if (rng_state == 1) {
        rng_state = (uint64_t)&rng_state ^ (uint64_t)rand();
    }
}

// Function to print SIMD status
void zslPrintSIMDStatus(void) {
    printf("=== SKIPLIST SIMD STATUS ===\n");
    printf("SIMD Support: %s\n", SIMD_SUPPORTED ? "YES" : "NO");
    printf("SIMD Type: %s\n", SIMD_TYPE);
    printf("SIMD Width: %d doubles per instruction\n", SIMD_WIDTH);
    printf("Architecture: ");
#if defined(__aarch64__)
    printf("ARM64 (Apple Silicon)\n");
#elif defined(__x86_64__)
    printf("x86_64 (Intel/AMD)\n");
#else
    printf("Unknown\n");
#endif
    
    printf("\n=== RUNTIME USAGE STATS ===\n");
    printf("SIMD range calls: %lu\n", simd_range_calls);
    printf("Scalar range calls: %lu\n", scalar_range_calls);
    printf("Total elements processed via SIMD: %lu\n", total_simd_elements);
    
    if (simd_range_calls + scalar_range_calls > 0) {
        double simd_percentage = (double)simd_range_calls / (simd_range_calls + scalar_range_calls) * 100.0;
        printf("SIMD usage percentage: %.1f%%\n", simd_percentage);
    }
    printf("=============================\n");
}

// Fast random using xorshift64 - much faster than rand()
static inline uint32_t fast_random(void) {
    init_rng();
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return (uint32_t)rng_state;
}

// Fast random level generation
static int zslRandomLevel(void) {
    int level = 1;
    uint32_t rnd = fast_random();
    while ((rnd & 0xFFFF) < (ZSKIPLIST_P * 0xFFFF) && level < ZSKIPLIST_MAXLEVEL) {
        level++;
        rnd >>= 16; // Use different bits for each level
        if (rnd == 0) rnd = fast_random(); // Get fresh random if exhausted
    }
    return level;
}

// SIMD-optimized range collection helper
#if SIMD_SUPPORTED
static inline int simd_collect_range(zskiplistNode *start_node, double min, double max,
                                   long *elements, double *scores, int max_count) {
    int collected = 0;
    zskiplistNode *current = start_node;
    int simd_batches = 0;
    
    // Prepare SIMD constants
#if defined(__ARM_NEON) || defined(__aarch64__)
    float64x2_t vmin = vdupq_n_f64(min);
    float64x2_t vmax = vdupq_n_f64(max);
    double score_buffer[2];
#elif defined(__AVX2__) || defined(__x86_64__)
    __m256d vmin = _mm256_set1_pd(min);
    __m256d vmax = _mm256_set1_pd(max);
    double score_buffer[4];
#endif
    
    // Collect nodes in groups for SIMD processing
    while (current && collected < max_count) {
        int batch_size = 0;
        zskiplistNode *batch_nodes[SIMD_WIDTH];
        
        // Gather a batch of consecutive nodes
        while (current && batch_size < SIMD_WIDTH && current->score <= max) {
            batch_nodes[batch_size] = current;
            score_buffer[batch_size] = current->score;
            batch_size++;
            current = current->level[0].forward;
        }
        
        if (batch_size == 0) break;
        
        // Process batch with SIMD
        if (batch_size >= SIMD_WIDTH) {
            simd_batches++;
#if defined(__ARM_NEON) || defined(__aarch64__)
            float64x2_t scores = vld1q_f64(score_buffer);
            uint64x2_t ge_min = vcgeq_f64(scores, vmin);
            uint64x2_t le_max = vcleq_f64(scores, vmax);
            uint64x2_t in_range = vandq_u64(ge_min, le_max);
            
            // Unroll manually since lane index must be compile-time constant
            if (vgetq_lane_u64(in_range, 0) && collected < max_count) {
                elements[collected] = batch_nodes[0]->ele;
                scores[collected] = batch_nodes[0]->score;
                collected++;
            }
            if (vgetq_lane_u64(in_range, 1) && collected < max_count) {
                elements[collected] = batch_nodes[1]->ele;
                scores[collected] = batch_nodes[1]->score;
                collected++;
            }
#elif defined(__AVX2__) || defined(__x86_64__)
            __m256d batch_scores = _mm256_loadu_pd(score_buffer);
            __m256d ge_min = _mm256_cmp_pd(batch_scores, vmin, _CMP_GE_OQ);
            __m256d le_max = _mm256_cmp_pd(batch_scores, vmax, _CMP_LE_OQ);
            __m256d in_range = _mm256_and_pd(ge_min, le_max);
            
            int mask = _mm256_movemask_pd(in_range);
            for (int i = 0; i < 4; i++) {
                if ((mask & (1 << i)) && collected < max_count) {
                    elements[collected] = batch_nodes[i]->ele;
                    scores[collected] = batch_nodes[i]->score;
                    collected++;
                }
            }
#endif
        } else {
            // Handle remaining nodes sequentially
            for (int i = 0; i < batch_size && collected < max_count; i++) {
                if (batch_nodes[i]->score >= min && batch_nodes[i]->score <= max) {
                    elements[collected] = batch_nodes[i]->ele;
                    scores[collected] = batch_nodes[i]->score;
                    collected++;
                }
            }
        }
        
        // Break if we went past max score
        if (current && current->score > max) break;
    }
    
    // Update global stats
    simd_range_calls++;
    total_simd_elements += collected;
    
    // Optional: Print debug info for verification
    #ifdef DEBUG_SIMD
    if (simd_batches > 0) {
        printf("SIMD: processed %d batches, collected %d elements\n", simd_batches, collected);
    }
    #endif
    
    return collected;
}
#endif

// Create a new skiplist node
zskiplistNode *zslCreateNode(int level, double score, long ele) {
    zskiplistNode *zn = malloc(sizeof(*zn) + level * sizeof(struct zskiplistLevel));
    if (!zn) return NULL;
    
    zn->score = score;
    zn->ele = ele;
    zn->backward = NULL;
    
    // Initialize forward pointers and spans
    for (int i = 0; i < level; i++) {
        zn->level[i].forward = NULL;
        zn->level[i].span = 0;
    }
    
    return zn;
}

// Create a new skiplist
zskiplist *zslCreate(void) {
    zskiplist *zsl = malloc(sizeof(*zsl));
    if (!zsl) return NULL;
    
    zsl->level = 1;
    zsl->length = 0;
    
    // Create header node with maximum level
    zsl->header = zslCreateNode(ZSKIPLIST_MAXLEVEL, 0, 0);
    if (!zsl->header) {
        free(zsl);
        return NULL;
    }
    
    zsl->tail = NULL;
    return zsl;
}

// Free the skiplist
void zslFree(zskiplist *zsl) {
    if (!zsl) return;
    
    zskiplistNode *node = zsl->header->level[0].forward;
    free(zsl->header);
    
    while (node) {
        zskiplistNode *next = node->level[0].forward;
        free(node);
        node = next;
    }
    
    free(zsl);
}

// Insert a new element
zskiplistNode *zslInsert(zskiplist *zsl, double score, long ele) {
    zskiplistNode *update[ZSKIPLIST_MAXLEVEL];
    unsigned int rank[ZSKIPLIST_MAXLEVEL];
    zskiplistNode *x = zsl->header;
    
    // Find insertion point
    for (int i = zsl->level - 1; i >= 0; i--) {
        rank[i] = (i == zsl->level - 1) ? 0 : rank[i + 1];
        
        while (x->level[i].forward &&
               (x->level[i].forward->score < score ||
                (x->level[i].forward->score == score && x->level[i].forward->ele < ele))) {
            rank[i] += x->level[i].span;
            x = x->level[i].forward;
        }
        update[i] = x;
    }
    
    // Generate random level for new node
    int level = zslRandomLevel();
    
    // If new level is higher than current max, initialize new levels
    if (level > zsl->level) {
        for (int i = zsl->level; i < level; i++) {
            rank[i] = 0;
            update[i] = zsl->header;
            update[i]->level[i].span = zsl->length;
        }
        zsl->level = level;
    }
    
    // Create and insert new node
    x = zslCreateNode(level, score, ele);
    if (!x) return NULL;
    
    for (int i = 0; i < level; i++) {
        x->level[i].forward = update[i]->level[i].forward;
        update[i]->level[i].forward = x;
        
        // Update spans
        x->level[i].span = update[i]->level[i].span - (rank[0] - rank[i]);
        update[i]->level[i].span = (rank[0] - rank[i]) + 1;
    }
    
    // Update spans for untouched levels
    for (int i = level; i < zsl->level; i++) {
        update[i]->level[i].span++;
    }
    
    // Set backward pointer
    x->backward = (update[0] == zsl->header) ? NULL : update[0];
    if (x->level[0].forward) {
        x->level[0].forward->backward = x;
    } else {
        zsl->tail = x;
    }
    
    zsl->length++;
    return x;
}

// Delete an element
int zslDelete(zskiplist *zsl, double score, long ele) {
    zskiplistNode *update[ZSKIPLIST_MAXLEVEL];
    zskiplistNode *x = zsl->header;
    
    // Find the node to delete
    for (int i = zsl->level - 1; i >= 0; i--) {
        while (x->level[i].forward &&
               (x->level[i].forward->score < score ||
                (x->level[i].forward->score == score && x->level[i].forward->ele < ele))) {
            x = x->level[i].forward;
        }
        update[i] = x;
    }
    
    x = x->level[0].forward;
    if (x && x->score == score && x->ele == ele) {
        // Remove the node
        for (int i = 0; i < zsl->level; i++) {
            if (update[i]->level[i].forward == x) {
                update[i]->level[i].span += x->level[i].span - 1;
                update[i]->level[i].forward = x->level[i].forward;
            } else {
                update[i]->level[i].span--;
            }
        }
        
        // Update backward pointers
        if (x->level[0].forward) {
            x->level[0].forward->backward = x->backward;
        } else {
            zsl->tail = x->backward;
        }
        
        // Remove empty levels
        while (zsl->level > 1 && zsl->header->level[zsl->level - 1].forward == NULL) {
            zsl->level--;
        }
        
        free(x);
        zsl->length--;
        return 1;
    }
    
    return 0;
}

// Count elements in range
unsigned long zslCount(zskiplist *zsl, double min, double max) {
    zskiplistNode *x = zsl->header;
    
    // Find first node >= min
    for (int i = zsl->level - 1; i >= 0; i--) {
        while (x->level[i].forward && x->level[i].forward->score < min) {
            x = x->level[i].forward;
        }
    }
    
    x = x->level[0].forward;
    
    // Count nodes in range
    unsigned long count = 0;
    while (x && x->score <= max) {
        count++;
        x = x->level[0].forward;
    }
    
    return count;
}

// Get range of elements with SIMD optimization
zskiplistRange *zslRange(zskiplist *zsl, double min, double max) {
    // First count to allocate exactly what we need
    unsigned long count = zslCount(zsl, min, max);
    
    // Allocate range structure (even for empty ranges)
    zskiplistRange *range = malloc(sizeof(zskiplistRange));
    if (!range) return NULL;
    
    if (count == 0) {
        // Return empty range structure
        range->elements = NULL;
        range->scores = NULL;
        range->capacity = 0;
        range->count = 0;
        return range;
    }
    
    range->elements = malloc(count * sizeof(long));
    range->scores = malloc(count * sizeof(double));
    
    if (!range->elements || !range->scores) {
        free(range->elements);
        free(range->scores);
        free(range);
        return NULL;
    }
    
    range->capacity = count;
    range->count = 0;
    
    // Find first node >= min
    zskiplistNode *x = zsl->header;
    for (int i = zsl->level - 1; i >= 0; i--) {
        while (x->level[i].forward && x->level[i].forward->score < min) {
            x = x->level[i].forward;
        }
    }
    
    x = x->level[0].forward;
    
    // Use SIMD collection if supported and beneficial
#if SIMD_SUPPORTED
    if (count >= SIMD_WIDTH * 2) {  // Only use SIMD for larger ranges
        range->count = simd_collect_range(x, min, max, range->elements, range->scores, count);
    } else {
#endif
        // Collect elements in range (sequential fallback)
        scalar_range_calls++;  // Track scalar usage
        while (x && x->score <= max && range->count < count) {
            range->elements[range->count] = x->ele;
            range->scores[range->count] = x->score;
            range->count++;
            x = x->level[0].forward;
        }
#if SIMD_SUPPORTED
    }
#endif
    
    return range;
}

// Free range structure
void zslFreeRange(zskiplistRange *range) {
    if (!range) return;
    free(range->elements);
    free(range->scores);
    free(range);
}
