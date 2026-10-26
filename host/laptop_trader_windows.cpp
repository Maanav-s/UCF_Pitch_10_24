// Optimized laptop trader for the FPGA exchange (Windows, C++).
//
// Listens on UDP port 5000. For each datagram equal to the standard market
// data, sends the standard buy reply back to the sender and records the
// receive->send time.
//
// Optimizations (always on):
//   - busy-poll a non-blocking socket (one core at 100%)
//   - HIGH priority class (REALTIME with --realtime), TIME_CRITICAL thread,
//     pinned to one CPU, 1 ms timer resolution, power throttling off
//   - connect() to the exchange after the first packet and use send/recv
//     (skip with --no-connect)
//   - UDP connection-reset errors off
//
// The two packets are compiled in from packets.h, which dump_packets.py
// generates from tools/fix_test_packet.py, so they are byte-identical to what
// the exchange sends and expects. Run `python dump_packets.py` before
// building, and again whenever fix_test_packet.py changes. The resulting .exe
// is self-contained: no data files are needed at run time.
//
// Build (Developer Command Prompt for VS):
//   cl /O2 /EHsc /std:c++17 laptop_trader_windows.cpp
// MinGW-w64 (on Windows):
//   g++ -O2 -std=c++17 laptop_trader_windows.cpp -o laptop_trader_windows.exe -lws2_32 -lwinmm
// Cross-compile from macOS:
//   x86_64-w64-mingw32-g++ -O2 -std=c++17 -static laptop_trader_windows.cpp \
//       -o laptop_trader_windows.exe -lws2_32 -lwinmm
//
// Usage:
//   laptop_trader_windows.exe [--realtime] [--power-plan] [--no-connect]
//                             [--cpu N] [--verbose]
//
//   --realtime    REALTIME priority class instead of HIGH (needs Administrator)
//   --power-plan  switch to the High performance power plan for the run and
//                 restore the previous plan at exit (needs Administrator)
//   --no-connect  skip connect(); use this if the exchange's source port
//                 varies, because a connected socket only accepts packets
//                 from the exact source ip:port of the first packet
//   --cpu N       CPU to pin to (default 2). Avoid CPU 0, and on hybrid Intel
//                 CPUs avoid E-cores (the highest-numbered logical CPUs).
//   --verbose     print one line per message (slows the next message)
//
// Ctrl+C prints the statistics (user-space receive->send only; the exchange's
// own number also includes NIC, driver, interrupts and the wire).

#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "packets.h"  // MD_BYTES, REPLY_BYTES (from dump_packets.py)

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "winmm.lib")

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif

static const int PORT = 5000;

static volatile LONG g_stop = 0;
static BOOL WINAPI on_ctrl(DWORD) {
    g_stop = 1;
    return TRUE;
}

static void win_tune(bool realtime, int cpu) {
    HANDLE proc = GetCurrentProcess();
    HANDLE thr = GetCurrentThread();

    bool ok = SetPriorityClass(proc, realtime ? REALTIME_PRIORITY_CLASS : HIGH_PRIORITY_CLASS);
    printf("  priority class %s: %s\n", realtime ? "REALTIME" : "HIGH", ok ? "ok" : "FAILED");

    ok = SetThreadPriority(thr, THREAD_PRIORITY_TIME_CRITICAL);
    printf("  thread priority TIME_CRITICAL: %s\n", ok ? "ok" : "FAILED");

    SYSTEM_INFO si;
    GetSystemInfo(&si);
    if (cpu < 0 || cpu >= (int)si.dwNumberOfProcessors) {
        printf("  cpu %d does not exist (have %lu); not pinning\n", cpu, si.dwNumberOfProcessors);
    } else {
        DWORD_PTR old = SetThreadAffinityMask(thr, (DWORD_PTR)1 << cpu);
        printf("  pinned to CPU %d: %s\n", cpu, old ? "ok" : "FAILED");
    }

    ok = timeBeginPeriod(1) == TIMERR_NOERROR;
    printf("  timer resolution 1 ms: %s\n", ok ? "ok" : "FAILED");

    PROCESS_POWER_THROTTLING_STATE st = {};
    st.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
    st.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
    st.StateMask = 0;  // not throttled
    ok = SetProcessInformation(proc, ProcessPowerThrottling, &st, sizeof(st));
    printf("  power throttling off: %s\n", ok ? "ok" : "not supported / FAILED");
}

static std::string set_power_plan() {
    std::string prev;
    FILE* p = _popen("powercfg /getactivescheme", "r");
    if (p) {
        char line[256] = {};
        if (fgets(line, sizeof line, p)) {
            std::string s(line);
            size_t c = s.find(':');
            if (c != std::string::npos) {
                size_t b = s.find_first_not_of(" \t", c + 1);
                size_t e = s.find_first_of(" \t\r\n", b);
                if (b != std::string::npos) prev = s.substr(b, e - b);
            }
        }
        _pclose(p);
    }
    int r = system("powercfg /setactive SCHEME_MIN >nul 2>&1");
    printf("  power plan High performance: %s\n", r == 0 ? "ok" : "FAILED");
    return r == 0 ? prev : std::string();
}

int main(int argc, char** argv) {
    int cpu = 2;
    bool realtime = false, power_plan = false, no_connect = false, verbose = false;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--realtime") realtime = true;
        else if (a == "--power-plan") power_plan = true;
        else if (a == "--no-connect") no_connect = true;
        else if (a == "--verbose") verbose = true;
        else if (a == "--cpu" && i + 1 < argc) cpu = atoi(argv[++i]);
        else {
            fprintf(stderr, "unknown argument %s (see header comment for usage)\n", a.c_str());
            return 2;
        }
    }

    const bool want_connect = !no_connect;
    printf("optimizations: busy-poll, tuning, connect=%d, connreset off\n", want_connect);

    SetConsoleCtrlHandler(on_ctrl, TRUE);
    std::string prev_plan;
    if (power_plan) prev_plan = set_power_plan();
    win_tune(realtime, cpu);

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        fprintf(stderr, "WSAStartup failed\n");
        return 1;
    }
    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    sockaddr_in me = {};
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = htonl(INADDR_ANY);
    me.sin_port = htons((u_short)PORT);
    if (bind(s, (sockaddr*)&me, sizeof me) == SOCKET_ERROR) {
        fprintf(stderr, "bind failed: %d\n", WSAGetLastError());
        return 1;
    }
    {
        BOOL flag = FALSE;
        DWORD ret = 0;
        int r = WSAIoctl(s, SIO_UDP_CONNRESET, &flag, sizeof flag, nullptr, 0, &ret, nullptr, nullptr);
        printf("  UDP connreset errors off: %s\n", r == 0 ? "ok" : "FAILED");
    }
    {
        u_long nb = 1;
        ioctlsocket(s, FIONBIO, &nb);
    }

    printf("listening on UDP %d; expecting %zu-byte market data, replying with %zu-byte buy\n",
           PORT, sizeof MD_BYTES, sizeof REPLY_BYTES);
    printf("  Ctrl+C to stop\n");

    LARGE_INTEGER freq;
    QueryPerformanceFrequency(&freq);
    const size_t CAP = 2000000;
    std::vector<int64_t> lat;
    lat.reserve(CAP);

    char buf[2048];
    const char* mdp = (const char*)MD_BYTES;
    const char* rp = (const char*)REPLY_BYTES;
    const int mdlen = (int)sizeof MD_BYTES, rlen = (int)sizeof REPLY_BYTES;
    uint64_t buys = 0, other = 0;
    bool connected = false;
    sockaddr_in from = {};
    LARGE_INTEGER t0, t1;

    while (!g_stop) {
        int n;
        if (connected) {
            n = recv(s, buf, sizeof buf, 0);
        } else {
            int fl = sizeof from;
            n = recvfrom(s, buf, sizeof buf, 0, (sockaddr*)&from, &fl);
        }
        if (n == SOCKET_ERROR) {
            int e = WSAGetLastError();
            if (e == WSAEWOULDBLOCK || e == WSAECONNRESET || e == WSAEMSGSIZE) continue;
            fprintf(stderr, "recv error %d\n", e);
            break;
        }
        QueryPerformanceCounter(&t0);
        if (n == mdlen && memcmp(buf, mdp, n) == 0) {
            if (connected) send(s, rp, rlen, 0);
            else sendto(s, rp, rlen, 0, (sockaddr*)&from, sizeof from);
            QueryPerformanceCounter(&t1);
            buys++;
            if (lat.size() < CAP) lat.push_back(t1.QuadPart - t0.QuadPart);
            if (want_connect && !connected) {
                // Off the timed path. From now on only packets from this exact
                // source ip:port are received.
                if (connect(s, (sockaddr*)&from, sizeof from) == 0) connected = true;
            }
            if (verbose) {
                char ip[32];
                inet_ntop(AF_INET, &from.sin_addr, ip, sizeof ip);
                printf("buy #%llu to %s:%u  receive->send %.1f us\n", (unsigned long long)buys, ip,
                       ntohs(from.sin_port),
                       (t1.QuadPart - t0.QuadPart) * 1e6 / (double)freq.QuadPart);
            }
        } else {
            other++;
            if (verbose) printf("ignored %d bytes\n", n);
        }
    }

    closesocket(s);
    WSACleanup();
    if (!prev_plan.empty()) {
        std::string cmd = "powercfg /setactive " + prev_plan + " >nul 2>&1";
        system(cmd.c_str());
    }

    printf("\nbuys %llu, ignored %llu\n", (unsigned long long)buys, (unsigned long long)other);
    if (lat.empty()) return 0;

    std::sort(lat.begin(), lat.end());
    const double us = 1e6 / (double)freq.QuadPart;
    auto pct = [&](double p) {
        size_t i = std::min(lat.size() - 1, (size_t)(p / 100.0 * lat.size()));
        return lat[i] * us;
    };
    double sum = 0;
    for (int64_t t : lat) sum += t;
    printf("receive->send latency (us), user-space only:\n");
    printf("  n=%zu  min=%.1f  median=%.1f  mean=%.1f  p90=%.1f  p99=%.1f  p99.9=%.1f  max=%.1f\n",
           lat.size(), lat.front() * us, pct(50), sum / lat.size() * us, pct(90), pct(99),
           pct(99.9), lat.back() * us);
    return 0;
}