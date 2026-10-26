// Laptop market maker for the two-trader exchange, C++17, Windows
// (docs/mm_protocol.md). The strategy is host/mm_strategy.h, shared with the
// Linux build (host/mm_trader.cpp); it matches host/mm_trader.py and the FPGA
// trader. This file adds the Windows socket loop and OS tuning:
//   - busy-poll a non-blocking socket (one core at 100%)
//   - HIGH priority class (REALTIME with --realtime) and a HIGHEST thread
//     (TIME_CRITICAL with --realtime); --cpu N pins the thread to one CPU
//   - power throttling (EcoQoS) off; High performance plan with --power-plan
//   - UDP connection-reset errors off
//
// Network setup as for the Python traders: run host/setup_windows.ps1 first
// (MAC 02:00:00:00:00:01, IP 192.168.10.1, static ARP entry for the exchange).
//
// Usage:
//   mm_trader_windows.exe [--half-spread 1] [--no-quote] [--port 5000]
//                         [--cpu N] [--realtime] [--power-plan]
//
//   --half-spread  dollars each side of fair (default 1; the FPGA uses 2)
//   --no-quote     only pick off, never quote
//   --cpu N        pin to CPU N (default: not pinned). Avoid CPU 0, and on
//                  hybrid Intel CPUs the E-cores (the highest-numbered CPUs).
//   --realtime     REALTIME priority class and TIME_CRITICAL thread (needs
//                  Administrator). Can starve the network driver's own
//                  threads on that CPU: compare with and without.
//   --power-plan   switch to the High performance power plan for the run and
//                  restore the previous one at exit (needs Administrator)
//
// Ctrl+C prints the counts and the user-space receive->last-send time per
// AAPL print. The exchange's event log has the full wire-to-wire figure.
//
// Build (Developer Command Prompt for VS, from host\):
//   cl /O2 /EHsc /std:c++17 mm_trader_windows.cpp
// MinGW-w64:
//   g++ -O3 -std=c++17 mm_trader_windows.cpp -o mm_trader_windows.exe -lws2_32 -static

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
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
#include <string>
#include <vector>

#include "mm_strategy.h"

#pragma comment(lib, "ws2_32.lib")

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif

namespace {

volatile LONG g_stop = 0;
BOOL WINAPI on_ctrl(DWORD) {
    g_stop = 1;
    return TRUE;
}

void win_tune(bool realtime, int cpu) {
    HANDLE proc = GetCurrentProcess();
    HANDLE thr = GetCurrentThread();

    BOOL ok = SetPriorityClass(proc, realtime ? REALTIME_PRIORITY_CLASS : HIGH_PRIORITY_CLASS);
    std::printf("  priority class %s: %s\n", realtime ? "REALTIME" : "HIGH", ok ? "ok" : "FAILED");

    int tp = realtime ? THREAD_PRIORITY_TIME_CRITICAL : THREAD_PRIORITY_HIGHEST;
    ok = SetThreadPriority(thr, tp);
    std::printf("  thread priority %s: %s\n", realtime ? "TIME_CRITICAL" : "HIGHEST", ok ? "ok" : "FAILED");

    if (cpu >= 0) {
        SYSTEM_INFO si;
        GetSystemInfo(&si);
        if (cpu >= static_cast<int>(si.dwNumberOfProcessors)) {
            std::printf("  cpu %d does not exist (have %lu); not pinning\n", cpu, si.dwNumberOfProcessors);
        } else {
            DWORD_PTR old = SetThreadAffinityMask(thr, static_cast<DWORD_PTR>(1) << cpu);
            std::printf("  pinned to CPU %d: %s\n", cpu, old ? "ok" : "FAILED");
        }
    }

    PROCESS_POWER_THROTTLING_STATE st = {};
    st.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
    st.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
    st.StateMask = 0;  // not throttled
    ok = SetProcessInformation(proc, ProcessPowerThrottling, &st, sizeof st);
    std::printf("  power throttling off: %s\n", ok ? "ok" : "not supported / FAILED");
}

// Returns the previous plan's GUID, or "" if the switch failed.
std::string set_power_plan() {
    std::string prev;
    FILE* p = _popen("powercfg /getactivescheme", "r");
    if (p) {
        char line[256] = {};
        if (std::fgets(line, sizeof line, p)) {
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
    int r = std::system("powercfg /setactive SCHEME_MIN >nul 2>&1");
    std::printf("  power plan High performance: %s\n", r == 0 ? "ok" : "FAILED");
    return r == 0 ? prev : std::string();
}

}  // namespace

int main(int argc, char** argv) {
    double half_spread = 1.0;
    bool quoting = true, realtime = false, power_plan = false;
    int port = 5000, cpu = -1;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--half-spread" && i + 1 < argc) half_spread = std::atof(argv[++i]);
        else if (a == "--no-quote") quoting = false;
        else if (a == "--port" && i + 1 < argc) port = std::atoi(argv[++i]);
        else if (a == "--cpu" && i + 1 < argc) cpu = std::atoi(argv[++i]);
        else if (a == "--realtime") realtime = true;
        else if (a == "--power-plan") power_plan = true;
        else {
            std::fprintf(stderr,
                         "usage: %s [--half-spread D] [--no-quote] [--port N] [--cpu N] "
                         "[--realtime] [--power-plan]\n", argv[0]);
            return 2;
        }
    }

    SetConsoleCtrlHandler(on_ctrl, TRUE);
    std::string prev_plan;
    if (power_plan) prev_plan = set_power_plan();
    win_tune(realtime, cpu);

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        std::fprintf(stderr, "WSAStartup failed\n");
        return 1;
    }
    SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) {
        std::fprintf(stderr, "socket failed: %d\n", WSAGetLastError());
        return 1;
    }
    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(static_cast<u_short>(port));
    if (bind(sock, reinterpret_cast<sockaddr*>(&addr), sizeof addr) == SOCKET_ERROR) {
        std::fprintf(stderr, "bind failed: %d\n", WSAGetLastError());
        return 1;
    }
    {
        BOOL flag = FALSE;
        DWORD ret = 0;
        int r = WSAIoctl(sock, SIO_UDP_CONNRESET, &flag, sizeof flag, nullptr, 0, &ret, nullptr, nullptr);
        std::printf("  UDP connreset errors off: %s\n", r == 0 ? "ok" : "FAILED");
    }
    u_long nonblocking = 1;
    ioctlsocket(sock, FIONBIO, &nonblocking);

    mm::MarketMaker trader(static_cast<int>(half_spread * 100 + 0.5), quoting);
    std::printf("market maker on UDP %d: half-spread $%.2f, %s, busy-polling recvfrom\n",
                port, half_spread, quoting ? "quoting" : "no quotes");
    std::printf("  Ctrl+C to stop\n");

    LARGE_INTEGER freq, t0, t1;
    QueryPerformanceFrequency(&freq);
    std::vector<int64_t> lat;  // receive -> last send, per payload that produced output
    lat.reserve(100000);

    char buf[2048];
    char out[mm::kMaxOut][mm::kOutBytes];
    int out_len[mm::kMaxOut];
    long n_in = 0, n_out = 0;
    sockaddr_in from = {};
    while (!g_stop) {
        int from_len = sizeof from;
        int n = recvfrom(sock, buf, sizeof buf, 0, reinterpret_cast<sockaddr*>(&from), &from_len);
        if (n == SOCKET_ERROR) {
            int e = WSAGetLastError();
            if (e == WSAEWOULDBLOCK || e == WSAECONNRESET || e == WSAEMSGSIZE) continue;
            std::fprintf(stderr, "recvfrom error %d\n", e);
            break;
        }
        QueryPerformanceCounter(&t0);
        ++n_in;
        int k = trader.on_payload(reinterpret_cast<const unsigned char*>(buf), n, out, out_len);
        for (int i = 0; i < k; ++i)
            sendto(sock, out[i], out_len[i], 0, reinterpret_cast<sockaddr*>(&from), from_len);
        if (k) {
            QueryPerformanceCounter(&t1);
            if (lat.size() < lat.capacity()) lat.push_back(t1.QuadPart - t0.QuadPart);
        }
        n_out += k;
    }

    closesocket(sock);
    WSACleanup();
    if (!prev_plan.empty()) {
        std::string cmd = "powercfg /setactive " + prev_plan + " >nul 2>&1";
        std::system(cmd.c_str());
    }

    std::printf("\nin %ld, out %ld, pickoff buys %d, sells %d, own fills %d, cancels too late %d\n",
                n_in, n_out, trader.n_buys, trader.n_sells, trader.n_fills, trader.n_too_late);
    if (!lat.empty()) {
        std::sort(lat.begin(), lat.end());
        const double us = 1e6 / static_cast<double>(freq.QuadPart);
        std::printf("receive->last send per AAPL print (us, user space only): n=%zu  min=%.1f  "
                    "median=%.1f  max=%.1f\n",
                    lat.size(), lat.front() * us, lat[lat.size() / 2] * us, lat.back() * us);
    }
    return 0;
}
