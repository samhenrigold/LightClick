#ifndef LC_OPENCL_DIAGNOSTIC_OPTIONS_H
#define LC_OPENCL_DIAGNOSTIC_OPTIONS_H
#include <ctype.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#define LC_OPENCL_DIAGNOSTIC_SOURCE_SHA "f110a56696746ed66d54450f587bf4c063386815a5e79f5e7b13d83fef730d22"
static inline bool lc_opencl_diagnostic_source_allowed(const char *sha, size_t bytes) {
    return sha && bytes == 154 && !strcmp(sha, LC_OPENCL_DIAGNOSTIC_SOURCE_SHA);
}
// Remove only exact, unquoted unsupported tokens. Every other byte is preserved.
static inline bool lc_opencl_diagnostic_options(const char *input, bool standard, char *output, size_t capacity) {
    const char *removed[] = {"-fapplecl-lax-vector-conversions", "-fapplecl-functional-casts", "-fapplecl-inline-definitions"};
    size_t written = 0, i = 0;
    while (input[i]) {
        size_t start = i;
        bool skip = false;
        if (isspace((unsigned char)input[i])) i++;
        else {
            char quote = 0;
            while (input[i]) {
                char c = input[i];
                if (!quote && isspace((unsigned char)c)) break;
                if (c == '\\' && input[i+1]) { i += 2; continue; }
                if (c == '\'' || c == '"') { if (!quote) quote = c; else if (quote == c) quote = 0; }
                i++;
            }
            if (standard) for (size_t j = 0; j < 3; j++) if (i-start == strlen(removed[j]) && !memcmp(input+start,removed[j],i-start)) skip = true;
        }
        if (!skip) {
            if (i-start >= capacity-written) return false;
            memcpy(output+written,input+start,i-start); written += i-start;
        }
    }
    const char *suffix = standard ? "-std=cl1.2 -x cl" : "-x cl";
    size_t extra = strlen(suffix) + (written ? 1 : 0);
    if (extra >= capacity-written) return false;
    if (written) output[written++] = ' ';
    memcpy(output+written,suffix,strlen(suffix)+1);
    return true;
}
#endif
