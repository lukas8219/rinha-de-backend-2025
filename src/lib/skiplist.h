#ifndef ZSKIPLIST_H
#define ZSKIPLIST_H

#define ZSKIPLIST_MAXLEVEL 32
#define ZSKIPLIST_P 0.25

typedef struct zskiplistNode {
    double score;
    long ele;  // Changed from char* to long for integer storage
    struct zskiplistNode *backward;
    struct zskiplistLevel {
        struct zskiplistNode *forward;
        unsigned int span;
    } level[];
} zskiplistNode;

typedef struct zskiplist {
    struct zskiplistNode *header, *tail;
    unsigned long length;
    int level;
} zskiplist;

// Structure to hold range scan results
typedef struct zskiplistRange {
    long *elements;
    double *scores;
    unsigned long count;
    unsigned long capacity;
} zskiplistRange;

zskiplist *zslCreate(void);
void zslFree(zskiplist *zsl);
zskiplistNode *zslInsert(zskiplist *zsl, double score, long ele);
int zslDelete(zskiplist *zsl, double score, long ele);
unsigned long zslCount(zskiplist *zsl, double min, double max);
zskiplistRange *zslRange(zskiplist *zsl, double min, double max);
void zslFreeRange(zskiplistRange *range);
void zslPrintSIMDStatus(void);

#endif