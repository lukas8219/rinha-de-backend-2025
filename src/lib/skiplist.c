#include <stdlib.h>
#include <string.h>
#include "skiplist.h"

static int zslRandomLevel(void) {
    int level = 1;
    while ((rand() & 0xFFFF) < (ZSKIPLIST_P * 0xFFFF))
        level += 1;
    return (level < ZSKIPLIST_MAXLEVEL) ? level : ZSKIPLIST_MAXLEVEL;
}

static zskiplistNode *zslCreateNode(int level, double score, long ele) {
    zskiplistNode *zn = malloc(sizeof(*zn) + level * sizeof(struct zskiplistLevel));
    zn->score = score;
    zn->ele = ele;  // Direct assignment instead of strdup
    return zn;
}

zskiplist *zslCreate(void) {
    int i;
    zskiplist *zsl = malloc(sizeof *zsl);
    zsl->level = 1;
    zsl->length = 0;
    zsl->header = zslCreateNode(ZSKIPLIST_MAXLEVEL, 0, 0);  // Use 0 instead of ""
    for (i = 0; i < ZSKIPLIST_MAXLEVEL; i++) {
        zsl->header->level[i].forward = NULL;
        zsl->header->level[i].span = 0;
    }
    zsl->header->backward = NULL;
    zsl->tail = NULL;
    return zsl;
}

void zslFree(zskiplist *zsl) {
    zskiplistNode *node = zsl->header->level[0].forward, *next;
    free(zsl->header);  // No need to free ele since it's not a pointer
    while (node) {
        next = node->level[0].forward;
        free(node);  // No need to free ele since it's not a pointer
        node = next;
    }
    free(zsl);
}

zskiplistNode *zslInsert(zskiplist *zsl, double score, long ele) {
    zskiplistNode *update[ZSKIPLIST_MAXLEVEL], *x = zsl->header;
    unsigned int rank[ZSKIPLIST_MAXLEVEL] = {0};
    int i, level;

    for (i = zsl->level - 1; i >= 0; i--) {
        rank[i] = (i == zsl->level - 1) ? 0 : rank[i+1];
        while (x->level[i].forward &&
              (x->level[i].forward->score < score ||
              (x->level[i].forward->score == score &&
               x->level[i].forward->ele < ele))) {  // Direct integer comparison
            rank[i] += x->level[i].span;
            x = x->level[i].forward;
        }
        update[i] = x;
    }
    level = zslRandomLevel();
    if (level > zsl->level) {
        for (i = zsl->level; i < level; i++) {
            rank[i] = 0;
            update[i] = zsl->header;
            update[i]->level[i].span = zsl->length;
        }
        zsl->level = level;
    }
    x = zslCreateNode(level, score, ele);
    for (i = 0; i < level; i++) {
        x->level[i].forward = update[i]->level[i].forward;
        update[i]->level[i].forward = x;
        x->level[i].span = update[i]->level[i].span - (rank[0] - rank[i]);
        update[i]->level[i].span = (rank[0] - rank[i]) + 1;
    }
    for (i = level; i < zsl->level; i++)
        update[i]->level[i].span++;

    x->backward = (update[0] == zsl->header) ? NULL : update[0];
    if (x->level[0].forward)
        x->level[0].forward->backward = x;
    else
        zsl->tail = x;

    zsl->length++;
    return x;
}

int zslDelete(zskiplist *zsl, double score, long ele) {
    zskiplistNode *update[ZSKIPLIST_MAXLEVEL], *x = zsl->header;
    int i;
    for (i = zsl->level -1; i >= 0; i--) {
        while (x->level[i].forward &&
              (x->level[i].forward->score < score ||
              (x->level[i].forward->score == score &&
               x->level[i].forward->ele < ele)))  // Direct integer comparison
            x = x->level[i].forward;
        update[i] = x;
    }
    x = x->level[0].forward;
    if (x && score == x->score && x->ele == ele) {  // Direct integer comparison
        for (i = 0; i < zsl->level; i++) {
            if (update[i]->level[i].forward == x) {
                update[i]->level[i].span += x->level[i].span - 1;
                update[i]->level[i].forward = x->level[i].forward;
            } else {
                update[i]->level[i].span--;
            }
        }
        if (x->level[0].forward)
            x->level[0].forward->backward = x->backward;
        else
            zsl->tail = x->backward;
        while (zsl->level > 1 && zsl->header->level[zsl->level-1].forward == NULL)
            zsl->level--;
        zsl->length--;
        free(x);  // No need to free ele since it's not a pointer
        return 1;
    }
    return 0;
}

unsigned long zslCount(zskiplist *zsl, double min, double max) {
    zskiplistNode *x = zsl->header;
    unsigned long count = 0;
    int i;
    for (i = zsl->level -1; i >= 0; i--) {
        while (x->level[i].forward && x->level[i].forward->score < min)
            x = x->level[i].forward;
    }
    x = x->level[0].forward;
    while (x && x->score <= max) {
        count++;
        x = x->level[0].forward;
    }
    return count;
}

zskiplistRange *zslRange(zskiplist *zsl, double min, double max) {
    zskiplistNode *x = zsl->header;
    zskiplistRange *range = malloc(sizeof(zskiplistRange));
    int i;
    
    int initial_capacity = max - min;
    // Initialize range structure
    range->capacity = initial_capacity;  // Start with small capacity
    range->elements = malloc(sizeof(long) * range->capacity);
    range->scores = malloc(sizeof(double) * range->capacity);
    range->count = 0;
    
    // Find first node in range
    for (i = zsl->level - 1; i >= 0; i--) {
        while (x->level[i].forward && x->level[i].forward->score < min)
            x = x->level[i].forward;
    }
    x = x->level[0].forward;
    
    // Collect all nodes in range
    while (x && x->score <= max) {
        // Resize arrays if needed
        if (range->count >= range->capacity) {
            range->capacity *= 2;
            range->elements = realloc(range->elements, sizeof(long) * range->capacity);
            range->scores = realloc(range->scores, sizeof(double) * range->capacity);
        }
        
        range->elements[range->count] = x->ele;
        range->scores[range->count] = x->score;
        range->count++;
        x = x->level[0].forward;
    }
    
    return range;
}

void zslFreeRange(zskiplistRange *range) {
    if (range) {
        free(range->elements);
        free(range->scores);
        free(range);
    }
}
