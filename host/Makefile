# Linux build of the C++ laptop market maker (docs/mm_protocol.md).
#   make -C host
#   sudo ./host/mm_trader --half-spread 1 --cpu 2 --busy-poll

CXX      ?= g++
CXXFLAGS ?= -O3 -march=native -std=c++17 -Wall -Wextra

mm_trader: mm_trader.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<

clean:
	rm -f mm_trader

.PHONY: clean
