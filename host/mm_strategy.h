// Market-making strategy shared by the C++ laptop traders, host/mm_trader.cpp
// (Linux) and host/mm_trader_windows.cpp (docs/mm_protocol.md). The same
// strategy as class MarketMaker in tools/mm_model.py and the FPGA trader;
// host/check_mm_strategy.py checks this one byte-exact against the model.
//
// Plain C++17, no OS headers. Messages are the fixed-width FIX layouts of
// tools/mm_fix.py ("python tools/mm_fix.py" prints the offsets): fields are
// read at constant payload offsets, and outgoing messages are stored
// templates with seq, ClOrdID, side, price and CheckSum patched in, as the
// FPGA builds them. No allocation and no formatting on the hot path.
#pragma once

#include <cstdint>
#include <cstring>

namespace mm {

constexpr int kFairNum = 3;
constexpr int kFairDen = 10;
constexpr int kFairOffCents = 2000;

// Received payloads. X: symbol 33-36, entry 42, price 48-54, size 60-64.
// 8: clordid 42-46, exectype 52, side 70. 9: reason 72.
constexpr int kTypeOff = 19;
constexpr int kXLen = 73, kERLen = 99, kCRLen = 81;

// Sent payloads: template, then value offsets.
// D: 34 at 24-28, 11 at 33-37, 54 at 50, 44 at 69-75, 10 at 80-82.
constexpr char kDTemplate[] =
    "8=FIX.4.4\x01" "9=061\x01" "35=D\x01" "34=00000\x01" "11=00000\x01" "55=ETF \x01"
    "54=1\x01" "38=00100\x01" "40=2\x01" "44=0000.00\x01" "10=000\x01";
constexpr int kDLen = 84;
// F: 34 at 24-28, 11 at 33-37, 41 at 42-46, 54 at 59, 10 at 64-66.
constexpr char kFTemplate[] =
    "8=FIX.4.4\x01" "9=045\x01" "35=F\x01" "34=00000\x01" "11=00000\x01" "41=00000\x01"
    "55=ETF \x01" "54=1\x01" "10=000\x01";
constexpr int kFLen = 68;
static_assert(sizeof kDTemplate - 1 == kDLen, "D template length");
static_assert(sizeof kFTemplate - 1 == kFLen, "F template length");

constexpr int kMaxOut = 5;     // pickoff + 2 cancels + 2 quotes
constexpr int kOutBytes = 96;  // >= kDLen, kFLen

inline int digits(const unsigned char* p, int n) {
    int v = 0;
    for (int i = 0; i < n; ++i) v = v * 10 + (p[i] - '0');
    return v;
}

inline int price_cents(const unsigned char* p) {  // "DDDD.DD"
    return digits(p, 4) * 100 + digits(p + 5, 2);
}

inline void put_digits(char* p, int v, int n) {
    for (int i = n - 1; i >= 0; --i) { p[i] = static_cast<char>('0' + v % 10); v /= 10; }
}

// CheckSum (10): byte sum of everything before "10=", mod 256, at len-4..len-2.
inline void put_checksum(char* p, int len) {
    unsigned sum = 0;
    for (int i = 0; i < len - 7; ++i) sum += static_cast<unsigned char>(p[i]);
    put_digits(p + len - 4, static_cast<int>(sum % 256), 3);
}

struct Own {
    bool valid = false;
    int clordid = 0;
    int price = 0;
};

class MarketMaker {
public:
    MarketMaker(int half_spread_cents, bool quoting) : hs_(half_spread_cents), quoting_(quoting) {}

    // Handles one payload; fills out[]/out_len[] with up to kMaxOut messages,
    // returns their count.
    int on_payload(const unsigned char* p, int len, char out[][kOutBytes], int out_len[]) {
        if (len < 30 || std::memcmp(p, "8=FIX.4.4\x01", 10) != 0) return 0;
        char t = static_cast<char>(p[kTypeOff]);
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
            // Every report is for one of our orders. A fill counts even when
            // the order is no longer the tracked one on its side (a pickoff
            // order's slot is taken over by the requote that follows it).
            if (p[52] == 'F') ++n_fills;
            int clordid = digits(p + 42, 5);
            Own& o = (p[70] == '1') ? own_bid_ : own_ask_;
            if (o.valid && o.clordid == clordid && p[52] != '0') o.valid = false;
            return 0;
        }
        if (t == '9' && len == kCRLen && p[72] == '0') ++n_too_late;
        return 0;
    }

    int n_buys = 0, n_sells = 0, n_fills = 0, n_too_late = 0;
    int fair = -1;

private:
    int on_aapl(int cents, char out[][kOutBytes], int out_len[]) {
        fair = (kFairNum * cents) / kFairDen + kFairOffCents;
        int n = 0;
        // Cancels are decided before the pickoff order, which takes over the
        // own-order slot of its side.
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
        std::memcpy(out, kDTemplate, kDLen);
        put_digits(out + 24, next_seq(), 5);
        put_digits(out + 33, c, 5);
        out[50] = side;
        put_digits(out + 69, cents / 100, 4);
        put_digits(out + 74, cents % 100, 2);
        put_checksum(out, kDLen);
        return kDLen;
    }

    int cancel(char* out, char side, int orig) {
        std::memcpy(out, kFTemplate, kFLen);
        put_digits(out + 24, next_seq(), 5);
        put_digits(out + 33, next_clordid(), 5);
        put_digits(out + 42, orig, 5);
        out[59] = side;
        put_checksum(out, kFLen);
        return kFLen;
    }

    int hs_;
    bool quoting_;
    bool bid_valid_ = false, ask_valid_ = false;
    int bid_ = 0, ask_ = 0;
    Own own_bid_, own_ask_;
    int seq_ = 0, clordid_ = 1;
};

}  // namespace mm
