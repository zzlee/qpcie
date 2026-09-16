# Re-execute an active PetaLinux project makefile in a prepared toolchain
# environment. PETALINUX_MAKE_READY prevents the recursive invocation from
# dispatching a second time.
PETALINUX_MAKEFILE := $(abspath $(firstword $(MAKEFILE_LIST)))
PETALINUX_PROJECT_DIR := $(CURDIR)
PETALINUX_GOALS := $(if $(MAKECMDGOALS),$(MAKECMDGOALS),all)
PETALINUX_SETTINGS ?= /opt/Xilinx/petalinux/2023.2/settings.sh
PETALINUX_IMAGE ?= petalinux
PETALINUX_RUNNER ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../petalinux-run.sh)
PETALINUX_IN_CONTAINER ?= $(shell test -f /.dockerenv && printf 1)

.DEFAULT_GOAL := petalinux-dispatch
.PHONY: petalinux-dispatch

ifneq ($(MAKECMDGOALS),)
$(MAKECMDGOALS): petalinux-dispatch ;
endif

petalinux-dispatch:
ifeq ($(PETALINUX_IN_CONTAINER),1)
	@test -f "$(PETALINUX_SETTINGS)" || { echo "ERROR: PetaLinux settings not found: $(PETALINUX_SETTINGS)" >&2; exit 1; }
	@/bin/bash -lc 'export SHELL=/bin/bash; command -v petalinux-build >/dev/null 2>&1 || source "$(PETALINUX_SETTINGS)"; exec $(MAKE) -C "$(PETALINUX_PROJECT_DIR)" -f "$(PETALINUX_MAKEFILE)" PETALINUX_MAKE_READY=1 $(MAKEOVERRIDES) $(PETALINUX_GOALS)'
else
	@command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is not installed or not in PATH" >&2; exit 1; }
	@docker image inspect "$(PETALINUX_IMAGE)" >/dev/null 2>&1 || { echo "ERROR: PetaLinux Docker image not found: $(PETALINUX_IMAGE)" >&2; exit 1; }
	@test -x "$(PETALINUX_RUNNER)" || { echo "ERROR: PetaLinux runner not found: $(PETALINUX_RUNNER)" >&2; exit 1; }
	@$(PETALINUX_RUNNER) "$(PETALINUX_IMAGE)" /bin/bash -lc 'export SHELL=/bin/bash; source "$(PETALINUX_SETTINGS)" && exec make -C "$(PETALINUX_PROJECT_DIR)" -f "$(PETALINUX_MAKEFILE)" PETALINUX_MAKE_READY=1 $(MAKEOVERRIDES) $(PETALINUX_GOALS)'
endif
