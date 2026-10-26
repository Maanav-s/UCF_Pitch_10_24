# Linux build of the C++ laptop market maker (docs/mm_protocol.md).
#   make -C host
#   sudo ./host/mm_trader --half-spread 1 --cpu 2 --busy-poll
#   make -C host check    # strategy byte-exact against tools/mm_model.py

CXX      ?= g++
CXXFLAGS ?= -O3 -march=native -std=c++17 -Wall -Wextra

mm_trader: mm_trader.cpp mm_strategy.h
	$(CXX) $(CXXFLAGS) -o $@ $<

check:
	python3 check_mm_strategy.py

clean:
	rm -f mm_trader mm_strategy_check

.PHONY: check clean
