#include <stdio.h>
#include <stdlib.h>
#include "json_generator.h"

char* generate_payment_summary_json(int default_requests, double default_amount, 
                                   int fallback_requests, double fallback_amount) {
    // Pre-allocate buffer - JSON structure is fixed, numbers are variable
    // Worst case: ~200 bytes should be enough for the full JSON
    char* buffer = malloc(256);
    if (!buffer) return NULL;
    
    // Use sprintf for maximum speed - no JSON library overhead
    // The format is fixed, only numbers change
    sprintf(buffer, 
        "{\"default\":{\"totalRequests\":%d,\"totalAmount\":%.2f},"
        "\"fallback\":{\"totalRequests\":%d,\"totalAmount\":%.2f}}",
        default_requests, default_amount, fallback_requests, fallback_amount);
    
    return buffer;
} 