#ifndef JSON_GENERATOR_H
#define JSON_GENERATOR_H

// Generate payment summary JSON with 4 numeric parameters
// Returns a malloc'd string that must be freed by the caller
char* generate_payment_summary_json(int default_requests, double default_amount, 
                                   int fallback_requests, double fallback_amount);

#endif 