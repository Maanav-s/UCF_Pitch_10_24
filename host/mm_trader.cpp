// Laptop market maker for the two-trader exchange, C++17, Linux
// (docs/mm_protocol.md). The same strategy as host/mm_trader.py and the FPGA
// trader (class MarketMaker in tools/mm_model.py), with a busy-polled UDP
// socket and no allocation or syscalls on the hot path other than receive
// and send.
//
//   mm_trader [--half-spread 1] [--no-quote] [--port 5000] [--cpu N] [--busy-poll]
//
// Messages are the fixed-width FIX layouts of tools/mm_fix.py; fields are
// read and written at the constant payload offsets printed by
// "python tools/mm_fix.py". Ctrl+C prints the counts.
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

namespace {

constexpr int kFairNum = 3;
constexpr int kFairDen = 10;
constexpr int kFairOffCents = 2000;

// Payload offsets (see python tools/mm_fix.py).
constexpr int kTypeOff = 19;
// X: symbol 33-36, entry 42, price 48-54, size 60-64
// 8: clordid 42-46, exectype 52, side 70
// 9: reason 72
constexpr int kXLen = 73, kERLen = 99, kCRLen = 81;

volatile sig_atomic_t g_stop = 0;
void on_sigint(int) { g_stop = 1; }

int price_cents(const unsigned char* p) {   // "DDDD.DD"
    int d = 0;
    for (int i = 0; i < 4; ++i) d = d * 10 + (p[i] - '0');
    return d * 100 + (p[5] - '0') * 10 + (p[6] - '0');
}

int digits(const unsigned char* p, int n) {
    int v = 0;
    for (int i = 0; i < n; ++i) v = v * 10 + (p[i] - '0');
    return v;
}

// Append "tag=value<SOH>" to buf at pos; returns the new pos.
int put(char* buf, int pos, const char* tag, const char* val) {
    int n = std::snprintf(buf + pos, 64, "%s=%s\x01", tag, val);
    return pos + n;
}

// Wrap a body in 8=, 9= and 10=; returns the message length.
int fix_wrap(char* out, const char* body, int body_len) {
    int n = std::snprintf(out, 32, "8=FIX.4.4\x01" "9=%03d\x01", body_len);
    std::memcpy(out + n, body, body_len);
    n += body_len;
    unsigned sum = 0;
    for (int i = 0; i < n; ++i) sum += static_cast<unsigned char>(out[i]);
    n += std::snprintf(out + n, 16, "10=%03u\x01", sum % 256);
    return n;
}

struct Own {
    bool valid = false;
    int clordid = 0;
    int price = 0;
};

class MarketMaker {
public:
    MarketMaker(int half_spread_cents, bool quoting) : hs_(half_spread_cents), quoting_(quoting) {}

    // Handles one payload; fills out[]/out_len[] with up to 5 messages, returns their count.
    int on_payload(const unsigned char* p, int len, char out[][160], int out_len[]) {
        if (len < 30 || std::memcmp(p, "8=FIX.4.4\x01", 10) != 0) return 0;
        char t = p[kTypeOff];
        if (t == 'X' && len == kXLen) {
            int cents = price_cents(p + 48);
            int size = digits(p + 60, 5);
            if (std::memcmp(p + 33, "AAPL", 4) == 0 && p[42] == '2') return on_aapl(cents, out, out_len);
            if (std::memcmp(p + 33, "ETF ", 4) == 0) {
                if (p[42] == '0') { bid_valid_ = size != 0; bid_ = cents; }
                else if (p[42] == '1') { ask_valid_ = size != 0; ask_ = cents; }
            }
            return 0;
        }
        if (t == '8' && len == kERLen) {
            int clordid = digits(p + 42, 5);
            Own& o = (p[70] == '1') ? own_bid_ : own_ask_;
            if (o.valid && o.clordid == clordid) {
                if (p[52] != '0') o.valid = false;
                if (p[52] == 'F') ++n_fills;
            }
            return 0;
        }
        if (t == '9' && len == kCRLen && p[72] == '0') ++n_too_late;
        return 0;
    }

    int n_buys = 0, n_sells = 0, n_fills = 0, n_too_late = 0;
    int fair = -1;

private:
    int on_aapl(int cents, char out[][160], int out_len[]) {
        fair = (kFairNum * cents) / kFairDen + kFairOffCents;
        int n = 0;
        bool cxl_bid = own_bid_.valid, cxl_ask = own_ask_.valid;
        int cxl_bid_id = own_bid_.clordid, cxl_ask_id = own_ask_.clordid;
        if (ask_valid_ && ask_ < fair && !(own_ask_.valid && own_ask_.price == ask_)) {
            out_len[n] = order(out[n], '1', ask_); ++n; ++n_buys;
        } else if (bid_valid_ && bid_ > fair && !(own_bid_.valid && own_bid_.price == bid_)) {
            out_len[n] = order(out[n], '2', bid_); ++n; ++n_sells;
        }
        if (cxl_bid) {
            out_len[n] = cancel(out[n], '1', cxl_bid_id); ++n;
            if (own_bid_.valid && own_bid_.clordid == cxl_bid_id) own_bid_.valid = false;
        }
        if (cxl_ask) {
            out_len[n] = cancel(out[n], '2', cxl_ask_id); ++n;
            if (own_ask_.valid && own_ask_.clordid == cxl_ask_id) own_ask_.valid = false;
        }
        if (quoting_) {
            if (fair > hs_) { out_len[n] = order(out[n], '1', fair - hs_); ++n; }
            out_len[n] = order(out[n], '2', fair + hs_); ++n;
        }
        return n;
    }

    int next_seq() { seq_ = (seq_ + 1) % 100000; return seq_; }
    int next_clordid() { int c = clordid_; clordid_ = (clordid_ + 1) % 100000; return c; }

    int order(char* out, char side, int cents) {
        int c = next_clordid();
        Own& o = (side == '1') ? own_bid_ : own_ask_;
        o = Own{true, c, cents};
        char body[128], v[16];
        int pos = 0;
        pos = put(body, pos, "35", "D");
        std::snprintf(v, sizeof v, "%05d", next_seq()); pos = put(body, pos, "34", v);
        std::snprintf(v, sizeof v, "%05d", c);          pos = put(body, pos, "11", v);
        pos = put(body, pos, "55", "ETF ");
        v[0] = side; v[1] = 0;                           pos = put(body, pos, "54", v);
        pos = put(body, pos, "38", "00100");
        pos = put(body, pos, "40", "2");
        std::snprintf(v, sizeof v, "%04d.%02d", cents / 100, cents % 100); pos = put(body, pos, "44", v);
        return fix_wrap(out, body, pos);
    }

    int cancel(char* out, char side, int orig) {
        char body[128], v[16];
        int pos = 0;
        pos = put(body, pos, "35", "F");
        std::snprintf(v, sizeof v, "%05d", next_seq());        pos = put(body, pos, "34", v);
        std::snprintf(v, sizeof v, "%05d", next_clordid());    pos = put(body, pos, "11", v);
        std::snprintf(v, sizeof v, "%05d", orig);              pos = put(body, pos, "41", v);
        pos = put(body, pos, "55", "ETF ");
        v[0] = side; v[1] = 0;                                  pos = put(body, pos, "54", v);
        return fix_wrap(out, body, pos);
    }

    int hs_;
    bool quoting_;
    bool bid_valid_ = false, ask_valid_ = false;
    int bid_ = 0, ask_ = 0;
    Own own_bid_, own_ask_;
    int seq_ = 0, clordid_ = 1;
};

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

    MarketMaker mm(static_cast<int>(half_spread * 100 + 0.5), quoting);
    std::printf("market maker on UDP %d: half-spread $%.2f, %s, busy-polling recvfrom\n",
                port, half_spread, quoting ? "quoting" : "no quotes");

    unsigned char buf[2048];
    char out[8][160];
    int out_len[8];
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
        int k = mm.on_payload(buf, static_cast<int>(n), out, out_len);
        for (int i = 0; i < k; ++i)
            sendto(sock, out[i], out_len[i], 0, reinterpret_cast<sockaddr*>(&from), from_len);
        n_out += k;
    }
    std::printf("\nin %ld, out %ld, pickoff buys %d, sells %d, own fills %d, cancels too late %d\n",
                n_in, n_out, mm.n_buys, mm.n_sells, mm.n_fills, mm.n_too_late);
    close(sock);
    return 0;
}
