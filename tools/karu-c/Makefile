# kaeru-cast: C client for the Kikru cast server. Needs only a C compiler.
CC ?= cc
CFLAGS ?= -std=c99 -Wall -Wextra -Wpedantic -O2
BIN = kaeru-cast

all: $(BIN)

$(BIN): kaeru-cast.c
	$(CC) $(CFLAGS) -o $@ $<

test: $(BIN)
	python3 test/test_kaeru_cast.py

clean:
	rm -f $(BIN)

.PHONY: all test clean
