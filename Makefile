# Plain Makefile for the RubikNxNxNSolver command-line tool.
# Works on macOS and Linux (anywhere Free Pascal is installed) -- no
# autoconf, no cmake, just fpc.

FPC      := fpc
TARGET   := project1
SOURCES  := $(wildcard *.pas) project1.lpr

# Ask fpc itself for its target CPU/OS names, rather than guessing from
# `uname`, so the unit output directory matches what Lazarus/lazbuild uses.
FPC_CPU  := $(shell $(FPC) -iTP)
FPC_OS   := $(shell $(FPC) -iTO)
UNITDIR  := lib/$(FPC_CPU)-$(FPC_OS)

FPCFLAGS := -MObjFPC -Sh -O2 -FU$(UNITDIR)

.PHONY: all run clean

all: $(TARGET)

$(TARGET): $(SOURCES)
	@mkdir -p $(UNITDIR)
	$(FPC) $(FPCFLAGS) -o$(TARGET) project1.lpr

run: all
	./$(TARGET)

clean:
	rm -rf $(UNITDIR) $(TARGET) $(TARGET).o $(TARGET).ppu
