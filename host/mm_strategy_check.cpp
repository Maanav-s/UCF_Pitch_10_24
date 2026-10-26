// Test driver for host/mm_strategy.h, run by host/check_mm_strategy.py.
// Reads one hex payload per line on stdin and writes one line per input: the
// hex payloads the strategy sends in reply, space-separated (empty if none).
// At end of input, one more line: "# <buys> <sells> <fills>".
//
//   mm_strategy_check <half_spread_cents> <quoting 0|1>

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "mm_strategy.h"

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: %s <half_spread_cents> <quoting 0|1>\n", argv[0]);
        return 2;
    }
    mm::MarketMaker mm(std::atoi(argv[1]), std::atoi(argv[2]) != 0);
    char line[4096];
    unsigned char p[2048];
    char out[mm::kMaxOut][mm::kOutBytes];
    int out_len[mm::kMaxOut];
    while (std::fgets(line, sizeof line, stdin)) {
        int len = 0;
        for (const char* c = line; c[0] && c[1] && c[0] != '\n'; c += 2) {
            unsigned v;
            std::sscanf(c, "%2x", &v);
            p[len++] = static_cast<unsigned char>(v);
        }
        int k = mm.on_payload(p, len, out, out_len);
        for (int i = 0; i < k; ++i) {
            if (i) std::putchar(' ');
            for (int j = 0; j < out_len[i]; ++j) std::printf("%02x", static_cast<unsigned char>(out[i][j]));
        }
        std::putchar('\n');
    }
    std::printf("# %d %d %d\n", mm.n_buys, mm.n_sells, mm.n_fills);
    return 0;
}
