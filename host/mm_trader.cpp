// Laptop market maker for the two-trader exchange, C++17, Linux
// (docs/mm_protocol.md). The strategy is host/mm_strategy.h, shared with the
// Windows build; it matches host/mm_trader.py and the FPGA trader (class
// MarketMaker in tools/mm_model.py). This file adds a busy-polled UDP
// socket and no allocation or syscalls on the hot path other than receive
// and send.
//
//   mm_trader [--half-spread 1] [--no-quote] [--port 5000] [--cpu N] [--busy-poll]
//
// Ctrl+C prints the counts.
//
// Build: make -C host   (g++ -O3 -march=native -std=c++17)

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sched.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "mm_strategy.h"

namespace {

volatile sig_atomic_t g_stop = 0;
void on_sigint(int) { g_stop = 1; }

}  // namespace

int main(int argc, char** argv) {
    double half_spread = 1.0;
    bool quoting = true, busy_poll = false;
    int port = 5000, cpu = -1;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--half-spread" && i + 1 < argc) half_spread = std::atof(argv[++i]);
        else if (a == "--no-quote") quoting = false;
        else if (a == "--port" && i + 1 < argc) port = std::atoi(argv[++i]);
        else if (a == "--cpu" && i + 1 < argc) cpu = std::atoi(argv[++i]);
        else if (a == "--busy-poll") busy_poll = true;
        else {
            std::fprintf(stderr, "usage: %s [--half-spread D] [--no-quote] [--port N] [--cpu N] [--busy-poll]\n", argv[0]);
            return 2;
        }
    }
    if (cpu >= 0) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(cpu, &set);
        if (sched_setaffinity(0, sizeof set, &set) != 0) std::perror("sched_setaffinity");
    }

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { std::perror("socket"); return 1; }
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(static_cast<uint16_t>(port));
    if (bind(sock, reinterpret_cast<sockaddr*>(&addr), sizeof addr) != 0) { std::perror("bind"); return 1; }
    if (busy_poll) {
#ifdef SO_BUSY_POLL
        int us = 50;
        if (setsockopt(sock, SOL_SOCKET, SO_BUSY_POLL, &us, sizeof us) != 0) std::perror("SO_BUSY_POLL");
#endif
    }
    signal(SIGINT, on_sigint);

    mm::MarketMaker trader(static_cast<int>(half_spread * 100 + 0.5), quoting);
    std::printf("market maker on UDP %d: half-spread $%.2f, %s, busy-polling recvfrom\n",
                port, half_spread, quoting ? "quoting" : "no quotes");

    unsigned char buf[2048];
    char out[mm::kMaxOut][mm::kOutBytes];
    int out_len[mm::kMaxOut];
    long n_in = 0, n_out = 0;
    sockaddr_in from{};
    socklen_t from_len = sizeof from;
    while (!g_stop) {
        ssize_t n = recvfrom(sock, buf, sizeof buf, MSG_DONTWAIT,
                             reinterpret_cast<sockaddr*>(&from), &from_len);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
            std::perror("recvfrom");
            break;
        }
        ++n_in;
        int k = trader.on_payload(buf, static_cast<int>(n), out, out_len);
        for (int i = 0; i < k; ++i)
            sendto(sock, out[i], out_len[i], 0, reinterpret_cast<sockaddr*>(&from), from_len);
        n_out += k;
    }
    std::printf("\nin %ld, out %ld, pickoff buys %d, sells %d, own fills %d, cancels too late %d\n",
                n_in, n_out, trader.n_buys, trader.n_sells, trader.n_fills, trader.n_too_late);
    close(sock);
    return 0;
}
