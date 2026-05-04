# Makefile for npi_port_trace
#
# Requires VERDI_HOME to be set.
#
# Build:  make
# Clean:  make clean

ifndef VERDI_HOME
$(error VERDI_HOME is not set)
endif

NPI_INC   = $(VERDI_HOME)/share/NPI/inc
NPI_L1_INC = $(VERDI_HOME)/share/NPI/L1/C/inc
NPI_LIB   = $(VERDI_HOME)/share/NPI/lib/LINUX64

CXX      = g++
CXXFLAGS = -std=c++11 -O2 -I$(NPI_INC) -I$(NPI_L1_INC)
LDFLAGS  = -L$(NPI_LIB) -lNPI -lnpiL1 -ldl -lpthread -lrt -lz \
           -Wl,-rpath,$(NPI_LIB)

TARGET   = npi_port_trace

$(TARGET): npi_port_trace.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)
	@printf '#!/bin/bash\nexec env LD_LIBRARY_PATH="$(NPI_LIB):$$LD_LIBRARY_PATH" "$$(dirname "$$0")/$(TARGET)" "$$@"\n' > $(TARGET).sh
	@chmod +x $(TARGET).sh

clean:
	rm -f $(TARGET) $(TARGET).sh

.PHONY: clean
