# Makefile for mutex_test_kmod - out-of-tree Linux kernel module build.
#
# Usage:
#   make                                          # Build using default gcc
#   make CC=/path/to/gcc-11                       # Build with specific compiler
#   scl enable gcc-toolset-11 'make'              # OL8: use matching gcc version
#   make KDIR=/path/to/kernel/build               # Custom kernel headers path
#   make clean                                    # Remove build artifacts

obj-m += mutex_test_kmod.o

KDIR ?= /lib/modules/$(shell uname -r)/build
CC ?= gcc

all:
	$(MAKE) -C $(KDIR) M=$(PWD) CC=$(CC) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
