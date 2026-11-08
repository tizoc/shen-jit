CC ?= cc
# Functions start on 32 bytes, so that a hot one's loops keep their alignment
# whatever else in the C code changes: on a Ryzen 5 5600X, an unrelated edit made
# 32-item vector equality take 1.32 times as long.
CFLAGS ?= -std=c11 -O2 -g -Wall -Wextra -Wno-unused-parameter -falign-functions=32
# The maths library, for floor and the like, libdl, for dladdr in the profiler,
# and libpthread, for threads: glibc keeps them apart from libc (libdl and
# libpthread until 2.34).
ifeq ($(OS),Windows_NT)
# Static, so that the executable needs nothing but Windows, with the C stack of Linux's default.
LDLIBS ?= -static -lm -lpthread -Wl,--stack,8388608
# Windows runs only what is named .exe, so executables are written under both names.
AS_EXE = cp $(1) $(1).exe
EXE := .exe
else
LDLIBS ?= -lm -ldl -lpthread
AS_EXE = :
EXE :=
endif
# SLJIT without its debug checks and verbose output, which made the runtime a
# quarter larger at the same speed. Its compiler struct changes with them, so
# everything that includes its header gets the same flags. test-san and
# test-x86 compile everything with SLJIT's defaults, so its assertions still
# run there.
SLJIT_FLAGS := -DSLJIT_DEBUG=0 -DSLJIT_VERBOSE=0
# MAP_ANON, which glibc hides under -std=c11: without it SLJIT maps /dev/zero
# for its code, which fails where /dev is mounted noexec, as on Ubuntu. Empty,
# as the runtime sources define it, so test-san and test-x86, which compile
# them in one command, see no redefinition.
SLJIT_SRC_FLAGS := -D_DEFAULT_SOURCE=
BUILD := build
# The library that C written for Shen is tested with, for test-ffi and test-kernel.
FFI_TEST_LIB := $(BUILD)/ffi_test$(if $(EXE),.dll,.so)
CURL_ADAPTER := $(BUILD)/shen-curl$(if $(EXE),.dll,.so)
FS_ADAPTER := $(BUILD)/shen-fs$(if $(EXE),.dll,.so)
PROCESS_ADAPTER := $(BUILD)/shen-process$(if $(EXE),.dll,.so)
TREE_SITTER_ADAPTER := $(BUILD)/shen-tree-sitter$(if $(EXE),.dll,.so)
# Your own paths and targets, which git ignores: see the variables below.
-include local.mk
.DEFAULT_GOAL := all
# STATIC=1 links statically, for a Linux executable that runs anywhere. It gives up loading
# libraries (docs/ffi.md): glibc's static dlopen loads a second libc.
ifdef STATIC
LDLIBS := -static -lm -ldl -lpthread
$(BUILD)/ffi.o: CFLAGS += -DSHEN_JIT_STATIC
endif
# The release number: *release* and *port* in the image, and the tarball's
# name.
VERSION := $(shell cat VERSION)

RUNTIME_SRC := src/runtime/heap.c src/runtime/objects.c src/runtime/image.c src/runtime/prims.c \
               src/runtime/reader.c src/runtime/loader.c src/runtime/jit.c src/runtime/dict.c \
               src/runtime/profile.c src/runtime/thread.c src/runtime/ffi.c src/runtime/win32.c
RUNTIME_HDR := src/runtime/value.h src/runtime/vm.h src/runtime/ops.h src/runtime/reader.h src/runtime/jit.h src/runtime/win32.h src/runtime/file.h include/shen.h
SLJIT_OBJ := $(BUILD)/sljitLir.o
RUNTIME_OBJ := $(patsubst src/runtime/%.c,$(BUILD)/%.o,$(RUNTIME_SRC))

# shasum comes with perl, which a system with only a C compiler may not have.
SHA256 := $(shell command -v sha256sum 2>/dev/null || echo shasum -a 256)
# An image loads only into the build that wrote it.
BUILD_ID := $(shell cat $(RUNTIME_SRC) $(RUNTIME_HDR) | $(SHA256) | cut -c1-16)

.PHONY: all release install stlib test-stlib test-thorn test-native test-buffer test-json test-io test-http test-datalog test-datalog-swipl bench-datalog bench-datalog-souffle test-ffi test-differential test-overrides differential-scheme fuzz-native generated update-generated check-generated deps host guide dist test test-san test-x86 test-jit test-ops test-kl test-kl-stress test-kernel test-kernel-stress test-lib-stress test-core test-libs test-ctrlc-windows test-linux bench bench-independent bench-numeric stage0 check-lowerer measure load-kernel clean

all: $(BUILD)/shen-jit

# Optional: the runtime itself has no libcurl dependency.
.PHONY: curl test-curl
curl: $(CURL_ADAPTER)

$(CURL_ADAPTER): lib/curl.c lib/build-curl.sh include/shen.h | $(BUILD)
	CC="$(CC)" CFLAGS="$(CFLAGS)" sh lib/build-curl.sh $@

test-curl: $(BUILD)/shen-jit
	CC="$(CC)" sh tests/curl.sh $(SHEN_JIT)

.PHONY: fs test-fs
fs: $(FS_ADAPTER)

$(FS_ADAPTER): lib/fs.c lib/build-fs.sh include/shen.h | $(BUILD)
	CC="$(CC)" CFLAGS="$(CFLAGS)" sh lib/build-fs.sh $@

test-fs: $(BUILD)/shen-jit
	CC="$(CC)" sh tests/fs.sh $(SHEN_JIT)

.PHONY: process test-process
process: $(PROCESS_ADAPTER)

$(PROCESS_ADAPTER): lib/process.c lib/process-posix.h lib/process-win.h lib/build-process.sh include/shen.h | $(BUILD)
	CC="$(CC)" CFLAGS="$(CFLAGS)" sh lib/build-process.sh $@

test-process: $(BUILD)/shen-jit
	CC="$(CC)" sh tests/process.sh $(SHEN_JIT)

.PHONY: tree-sitter test-tree-sitter deps-tree-sitter
tree-sitter: $(TREE_SITTER_ADAPTER)

$(TREE_SITTER_ADAPTER): lib/tree-sitter.c lib/build-tree-sitter.sh include/shen.h | $(BUILD)
	CC="$(CC)" CFLAGS="$(CFLAGS)" sh lib/build-tree-sitter.sh $@

deps-tree-sitter:
	sh tools/tree-sitter-deps.sh .deps

test-tree-sitter: $(BUILD)/shen-jit
	CC="$(CC)" sh tests/tree_sitter.sh $(SHEN_JIT)

# The runtime alone, and the image stage 1 writes with it from the stage 0
# output.
$(BUILD)/runtime: src/runtime/main.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(RUNTIME_HDR) VERSION
	$(CC) $(CFLAGS) $(SLJIT_FLAGS) -DSJ_VERSION='"$(VERSION)"' -o $@ src/runtime/main.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(LDLIBS)

$(BUILD)/shen-jit.img: $(BUILD)/runtime $(BUILD)/stage0/.done
	$(BUILD)/runtime --stage1 $(BUILD)/stage0 $@

# The executable: the runtime with the image appended, which it reads from the
# end of its own file. On macOS the
# linker's ad-hoc signature still runs, though strict verification
# (codesign --verify) rejects the appended data.
$(BUILD)/shen-jit: $(BUILD)/runtime $(BUILD)/shen-jit.img
	cat $^ > $@
	chmod +x $@
	$(call AS_EXE,$@)

# The release build: the same executable, with the runtime stripped of its
# symbols and debug information before the image is appended, as strip would
# drop the image. The code is the same; on Linux, gcc's debug information made
# the runtime 1.3 MB instead of 0.2.
release: $(BUILD)/runtime $(BUILD)/shen-jit.img
	cp $(BUILD)/runtime$(EXE) $(BUILD)/runtime-stripped$(EXE)
	strip $(BUILD)/runtime-stripped$(EXE)
	cat $(BUILD)/runtime-stripped$(EXE) $(BUILD)/shen-jit.img > $(BUILD)/shen-jit
	chmod +x $(BUILD)/shen-jit
	$(call AS_EXE,$(BUILD)/shen-jit)
	rm $(BUILD)/runtime-stripped$(EXE)

# The executable is all there is to install: it carries its image. Not with
# install -s, which would drop the image.
PREFIX ?= /usr/local
install: $(BUILD)/shen-jit
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(BUILD)/shen-jit $(DESTDIR)$(PREFIX)/bin/shen-jit

$(BUILD)/%.o: src/runtime/%.c $(RUNTIME_HDR) | $(BUILD)
	$(CC) $(CFLAGS) $(SLJIT_FLAGS) -DSJ_BUILD_ID='"$(BUILD_ID)"' -c $< -o $@

# The build identifier covers every runtime source.
$(BUILD)/image.o: $(RUNTIME_SRC)
$(BUILD)/objects.o: vendor/xxhash/xxhash.h

$(SLJIT_OBJ): vendor/sljit/sljit_src/sljitLir.c | $(BUILD)
	$(CC) -std=c11 -O2 -g -w $(SLJIT_FLAGS) $(SLJIT_SRC_FLAGS) -c $< -o $@

$(BUILD)/test_runtime: tests/test_runtime.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(RUNTIME_HDR)
	$(CC) $(CFLAGS) $(SLJIT_FLAGS) -o $@ tests/test_runtime.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(LDLIBS)

# Generated inputs: what takes a Shen to make, the stage 0 output, the lowerer as
# KLambda and the lowered test programs. A release tarball carries them in
# generated/ (make dist) and builds from there with a C compiler alone, whatever
# the files' times; a checkout makes them from the kernel under BOOTSTRAP, the
# earlier release of Shen/JIT that tools/ci-deps.sh names. Shen/Scheme can take its
# place, and makes the same files. make deps fetches the kernel and that release
# into .deps, checked by hash, and generated.sha256 holds the hashes of what they
# make, which check-generated compares.
BOOTSTRAP ?= .deps/shen-jit/shen-jit$(EXE)
KERNEL_KL ?= .deps/kernel/klambda
GENERATED := stage0/*.sbc stage0/*.forms port/lower.kl bench/programs.sbc kl/ops.sbc stlib/stlib.kl

ifneq ($(wildcard generated/stage0),)
$(BUILD)/generated.done:
	mkdir -p $(BUILD)
	cp -R generated/. $(BUILD)/
	touch $(BUILD)/stage0/.done $@

$(BUILD)/stage0/.done $(BUILD)/port/lower.kl $(BUILD)/bench/programs.sbc $(BUILD)/kl/ops.sbc $(BUILD)/stlib/stlib.kl: $(BUILD)/generated.done
	@:
else
# The kernel's precompiled standard library, for make stlib.
$(BUILD)/stlib/stlib.kl: $(KERNEL_KL)/stlib.kl | host
	mkdir -p $(BUILD)/stlib
	cp $< $@

# What the tools run under the host, with the lowerer's names changed, as a host
# that is Shen/JIT has its own lowerer sealed under them (src/lowerer/host.shen).
STAGE0_TOOLS := src/lowerer/host.shen src/lowerer/stage0.shen $(BUILD)/tools/lower.shen
$(BUILD)/tools/%.shen: src/lowerer/%.shen
	mkdir -p $(BUILD)/tools
	sed -e 's/shen-jit\.lower\./stage0.lower./g' -e 's/(shen-jit\.sealed? /(stage0.sealed? /g' \
	  -e 's/(shen-jit\.inline-body /(stage0.inline-body /g' $< > $@
$(BUILD)/tools/%.shen: lib/%.shen
	mkdir -p $(BUILD)/tools
	sed -e 's/shen-jit\.lower\./stage0.lower./g' $< > $@

# The benchmark programs and the opcode tests, lowered by the lowerer.
$(BUILD)/bench/programs.sbc: tests/bench/programs.kl $(STAGE0_TOOLS) | host
	mkdir -p $(BUILD)/bench
	$(BOOTSTRAP) script src/lowerer/stage0.shen tests/bench/ $(BUILD)/bench/ programs > /dev/null

$(BUILD)/kl/ops.sbc: tests/kl/ops.kl $(STAGE0_TOOLS) | host
	mkdir -p $(BUILD)/kl
	$(BOOTSTRAP) script src/lowerer/stage0.shen tests/kl/ $(BUILD)/kl/ ops > /dev/null

# Stage 0: the lowerer compiled to KLambda, then the kernel, the port and the
# lowerer lowered under the host.
$(BUILD)/port/lower.kl: src/lowerer/lower.shen src/lowerer/tokl.shen | host
	mkdir -p $(BUILD)/port
	$(BOOTSTRAP) script src/lowerer/tokl.shen $@ > /dev/null

$(BUILD)/stage0/.done: $(BUILD)/port/lower.kl src/port/shen-jit.kl $(STAGE0_TOOLS) | host
	mkdir -p $(BUILD)/stage0
	$(BOOTSTRAP) script src/lowerer/stage0.shen $(KERNEL_KL)/ $(BUILD)/stage0/ > /dev/null
	touch $@
endif

# What a checkout needs to make the generated files.
deps:
	sh tools/ci-deps.sh kernel .deps/kernel > /dev/null
	sh tools/ci-deps.sh shen-jit .deps/shen-jit > /dev/null

# With a clearer message than the first command would give.
host:
	@command -v $(BOOTSTRAP) > /dev/null || { echo "no host at $(BOOTSTRAP): run make deps, or set BOOTSTRAP"; exit 1; }
	@test -d $(KERNEL_KL) || { echo "no kernel at $(KERNEL_KL): run make deps, or set KERNEL_KL"; exit 1; }

generated: $(BUILD)/stage0/.done $(BUILD)/port/lower.kl $(BUILD)/bench/programs.sbc $(BUILD)/kl/ops.sbc $(BUILD)/stlib/stlib.kl

# A change to the lowerer, the port or the test programs updates the manifest
# in the same commit; any other difference is drift.
update-generated: generated
	export LC_ALL=C; cd $(BUILD) && $(SHA256) $(GENERATED) > ../generated.sha256

# In C order: where /bin/sh is bash, a glob's order follows the locale.
check-generated: generated
	@export LC_ALL=C; cd $(BUILD) && $(SHA256) $(GENERATED) | sed 's/ \*/  /' > generated.sha256 && \
	  if diff -u ../generated.sha256 generated.sha256; then echo "generated files match generated.sha256"; \
	  else echo "generated files differ from generated.sha256 (make update-generated with the change that made them)"; exit 1; fi

# The guide, docs/guide.md, with the documents that have a page of their own, as GitHub Pages
# serves them and release archives carry them.
GUIDE_PAGES := design semantics bytecode ffi buffers grammar io fs processes tree-sitter framing io-sockets deadlines http-head http http-streaming http-listener json datalog curl
GUIDE_PANDOC := pandoc -f gfm -t html --standalone --toc --toc-depth=2 --section-divs --wrap=none \
  --template=site/template.html --lua-filter=site/guide.lua
guide:
	rm -rf $(BUILD)/guide && mkdir -p $(BUILD)/guide/assets
	$(GUIDE_PANDOC) --shift-heading-level-by=-1 -o $(BUILD)/guide/index.html docs/guide.md
	for page in $(GUIDE_PAGES); do $(GUIDE_PANDOC) -M doc -o $(BUILD)/guide/$$page.html docs/$$page.md || exit 1; done
	cp assets/*.png $(BUILD)/guide/assets/

# A release tarball: the tracked files, generated/, which builds without a host,
# and guide/, the rendered guide, which saves each platform from needing pandoc. The
# generated files must match the manifest first.
DIST := shen-jit-$(VERSION)
dist: check-generated guide
	rm -rf $(BUILD)/$(DIST) && mkdir -p $(BUILD)/$(DIST)/generated
	git ls-files -z | tar --null -T - -cf - | tar -C $(BUILD)/$(DIST) -xf -
	cd $(BUILD) && tar -cf - $(GENERATED) | tar -C $(DIST)/generated -xf -
	cp -R $(BUILD)/guide $(BUILD)/$(DIST)/guide
	COPYFILE_DISABLE=1 tar -C $(BUILD) --no-xattrs -czf $(BUILD)/$(DIST).tar.gz $(DIST) # no macOS metadata
	rm -rf $(BUILD)/$(DIST)
	@echo "wrote $(BUILD)/$(DIST).tar.gz"

$(BUILD)/test_jit: tests/test_jit.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(RUNTIME_HDR)
	$(CC) $(CFLAGS) $(SLJIT_FLAGS) -o $@ tests/test_jit.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(LDLIBS)

test-jit: $(BUILD)/test_jit $(BUILD)/bench/programs.sbc
	cd $(BUILD) && ./test_jit bench/programs.sbc

$(BUILD)/test_ops: tests/test_ops.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(RUNTIME_HDR)
	$(CC) $(CFLAGS) $(SLJIT_FLAGS) -o $@ tests/test_ops.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(LDLIBS)

test-ops: $(BUILD)/test_ops $(BUILD)/kl/ops.sbc
	cd $(BUILD) && ./test_ops kl/ops.sbc

stage0: $(BUILD)/stage0/.done

check-lowerer: $(BUILD)/stage0/.done $(BUILD)/tools/native.shen
	$(BOOTSTRAP) script src/lowerer/check.shen $(KERNEL_KL)/ $(BUILD)/stage0/ | tail -1 | awk '{ print } END { exit !/^0 failures/ }'

$(BUILD)/test_kl: tests/test_kl.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(RUNTIME_HDR)
	$(CC) $(CFLAGS) $(SLJIT_FLAGS) -o $@ tests/test_kl.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(LDLIBS)

test-kl: $(BUILD)/test_kl $(BUILD)/stage0/.done
	cd $(BUILD) && ./test_kl stage0 ../tests/kl/eval-cases.kl

# The eval-kl cases with a collection before every allocation (slow).
test-kl-stress: $(BUILD)/test_kl $(BUILD)/stage0/.done
	cd $(BUILD) && ./test_kl stage0 ../tests/kl/eval-cases.kl --stress

# The kernel's test suite, the extension tests and the contract
# examples, run by the executable. The kernel harness asks whether to continue
# after a failure, so the answers are scripted; each run ends with its counts,
# which awk shows and checks (tee /dev/stderr would reopen a redirected log on
# Linux, truncating it).
KERNEL_DIR ?= .deps/kernel
SHEN_JIT := $(abspath $(BUILD)/shen-jit)
RESULTS := grep -A1 '^passed \.\.\.' | tail -2 | awk '{ print } END { exit !/failed \.\.\. 0$$/ }'

test-kernel: all $(FFI_TEST_LIB)
	cd $(KERNEL_DIR)/tests && yes y | head -200 | \
	  SHEN_JIT_GC_STRESS=$(GC_STRESS) $(SHEN_JIT) script runme.shen | $(RESULTS)
	rm -rf $(BUILD)/kernel-tests && mkdir -p $(BUILD)/kernel-tests
	cp -R $(KERNEL_DIR)/tests $(KERNEL_DIR)/extensions $(BUILD)/kernel-tests/ && chmod -R u+w $(BUILD)/kernel-tests
	cd $(BUILD)/kernel-tests && SHEN_JIT_GC_STRESS=$(GC_STRESS) \
	  $(SHEN_JIT) script $(abspath tests/kernel-extensions.shen) < /dev/null | $(RESULTS)
	SHEN_JIT_GC_STRESS=$(GC_STRESS) $(SHEN_JIT) script contract/examples.shen | \
	  tail -1 | awk '{ print } END { exit !/ 0 failed/ }'
	SHEN_JIT_GC_STRESS=$(GC_STRESS) sh tests/cli.sh $(SHEN_JIT)

# The same with a collection after every 1000 words allocated (about 2 minutes).
test-kernel-stress:
	$(MAKE) test-kernel GC_STRESS=1000
	$(MAKE) test-stlib GC_STRESS=1000
	$(MAKE) test-native GC_STRESS=1000
	$(MAKE) test-ffi GC_STRESS=1000
	cd $(BUILD) && SHEN_JIT_GC_STRESS=1 ./shen-jit eval -l ../lib/ffi.shen -l ../tests/ffi_c.shen | $(FFI_RESULT)

# What a change to the runtime, the JIT, the lowerer or the port must pass (about 20 s).
test-core: test test-jit test-ops test-kl check-lowerer check-generated test-kernel test-stlib test-thorn \
  test-native test-ffi test-overrides

# Every library's suite, without the collections test-lib-stress adds (about 30 s).
test-libs: test-buffer test-json test-io test-fs test-process test-tree-sitter test-http test-datalog test-curl

# The libraries' saved images reloaded with a collection at every allocation, which their own suites
# leave out for speed.
LIB_IMAGE_TESTS = buffer_image json_image io_image frame_image io_socket_image http_image \
  http_request_image http_stream_image http_listener
test-lib-stress: $(BUILD)/shen-jit
	for t in $(LIB_IMAGE_TESTS); do TEST_GC_STRESS=1 sh tests/$$t.sh $(SHEN_JIT) || exit 1; done
	TEST_GC_STRESS=1 CC="$(CC)" sh tests/curl.sh $(SHEN_JIT)

# The optional standard library: an executable of its own, with the kernel's
# precompiled stlib in its image (docs/guide.md, "The standard library").
stlib: $(BUILD)/shen-jit-stlib

$(BUILD)/shen-jit-stlib: $(BUILD)/shen-jit $(BUILD)/stlib/stlib.kl tools/stlib.shen
	$(BUILD)/shen-jit script tools/stlib.shen $(BUILD)/stlib/stlib.kl $@ > /dev/null
	$(call AS_EXE,$@)

test-stlib: $(BUILD)/shen-jit-stlib
	cd $(BUILD) && SHEN_JIT_GC_STRESS=$(GC_STRESS) ./shen-jit-stlib script ../tests/stlib.shen | \
	  tail -1 | awk '{ print } END { exit !/ 0 failed/ }'

# What a prover computes, against counts that Shen/Scheme gives too (tests/thorn.sh).
test-thorn: $(BUILD)/shen-jit-stlib
	sh tests/thorn.sh $(abspath $(BUILD)/shen-jit-stlib) $(KERNEL_DIR)

# Native code written by hand (docs/bytecode.md, "Native code written by hand"). A macro
# applies only to files read after it, so the tests load as a file of their own.
test-native: $(BUILD)/shen-jit
	SHEN_JIT_GC_STRESS=$(GC_STRESS) $(BUILD)/shen-jit eval -l lib/native.shen -l tests/native.shen | \
	  grep '^[0-9]* passed' | awk '{ print } END { exit !/ 0 failed/ }'

# Byte views and cursors, and grammars over them, independent of native assembly or kernel streams.
# A macro applies only to files read after it, so the grammar tests load as a file of their own.
test-buffer: $(BUILD)/shen-jit
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/cursor.shen -l tests/buffer.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/grammar.shen -l tests/grammar.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/grammar.shen -l tests/grammar_stream.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/grammar.shen -e '(tc +)' -l tests/grammar_typed.shen | $(FFI_RESULT)
	sh tests/grammar_typed.sh $(SHEN_JIT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/cursor.shen \
	  -l lib/grammar.shen -l lib/json.shen -l tools/buffer-parsers.shen -l tests/buffer_examples.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/cursor.shen -e '(tc +)' -l tests/buffer_typed.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/memory.shen -l lib/handle.shen \
	  -l lib/buffer.shen -l lib/cursor.shen -l tests/buffer_memory.shen | $(FFI_RESULT)
	sh tests/buffer_image.sh $(SHEN_JIT)

# Complete UTF-8 JSON and bounded output, without FFI or kernel streams.
test-json: $(BUILD)/shen-jit
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/grammar.shen -l lib/json.shen -l tests/json.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/grammar.shen -l lib/json.shen -l tests/json_stream.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/grammar.shen -l lib/json.shen -e '(tc +)' -l tests/json_typed.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/memory.shen -l lib/buffer.shen -l lib/grammar.shen -l lib/json.shen \
	  -l tests/json_memory.shen | $(FFI_RESULT)
	sh tests/json_image.sh $(SHEN_JIT)

# Independent chunk I/O, native file descriptors, typed results and image/GC safety.
test-io: $(BUILD)/shen-jit
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l tests/io.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/io-file.shen \
	  -e '(tc +)' -l tests/io_typed.shen | $(FFI_RESULT)
	sh tests/io_file.sh $(SHEN_JIT)
	sh tests/io_image.sh $(SHEN_JIT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/frame.shen -l tests/frame.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/socket.shen -l lib/buffer.shen -l lib/io.shen \
	  -l lib/io-socket.shen -l lib/frame.shen -e '(tc +)' -l tests/frame_typed.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/socket.shen -l lib/buffer.shen -l lib/io.shen \
	  -l lib/io-socket.shen -l lib/frame.shen -l tools/frame-echo.shen -l tests/io_socket.shen | $(FFI_RESULT)
	sh tests/frame_image.sh $(SHEN_JIT)
	sh tests/io_socket_image.sh $(SHEN_JIT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/deadline.shen -l tests/deadline.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/deadline.shen \
	  -l lib/http-head.shen -l tests/http_head.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/socket.shen -l lib/buffer.shen -l lib/io.shen \
	  -l lib/deadline.shen -l lib/clock.shen -l lib/io-socket.shen -l tests/io_deadline.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/socket.shen -l lib/buffer.shen -l lib/io.shen \
	  -l lib/deadline.shen -l lib/clock.shen -l lib/io-socket.shen -l lib/http-head.shen \
	  -e '(tc +)' -l tests/http_typed.shen | $(FFI_RESULT)
	sh tests/http_image.sh $(SHEN_JIT)

# Complete request parsing, bounded bodies, response streams and persistent connections.
test-http: $(BUILD)/shen-jit
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/deadline.shen -l lib/grammar.shen -l lib/http-head.shen \
	  -l lib/http-request.shen -l lib/http-response.shen -l tests/http_stream.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/deadline.shen -l lib/grammar.shen -l lib/http-head.shen \
	  -l lib/http-request.shen -l lib/http-response.shen -l tests/http_chunked.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/grammar.shen -l lib/http-head.shen \
	  -l lib/http-request.shen -l lib/http-response.shen -l tests/http_request.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/deadline.shen -l lib/grammar.shen -l lib/http-head.shen \
	  -l lib/http-request.shen -l tests/http_read.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/socket.shen -l lib/buffer.shen -l lib/io.shen \
	  -l lib/deadline.shen -l lib/clock.shen -l lib/io-socket.shen -l lib/grammar.shen -l lib/http-head.shen \
	  -l lib/http-request.shen -l lib/http-response.shen -l lib/http-server.shen \
	  -e '(tc +)' -l tests/http_request_typed.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/socket.shen -l lib/buffer.shen -l lib/io.shen \
	  -l lib/deadline.shen -l lib/clock.shen -l lib/io-socket.shen -l lib/grammar.shen -l lib/http-head.shen \
	  -l lib/http-request.shen -l lib/http-response.shen -l lib/http-server.shen \
	  -e '(tc +)' -l tests/http_stream_typed.shen | $(FFI_RESULT)
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/socket.shen -l lib/buffer.shen -l lib/io.shen \
	  -l lib/deadline.shen -l lib/clock.shen -l lib/io-socket.shen -l lib/grammar.shen -l lib/http-head.shen \
	  -l lib/http-request.shen -l lib/http-response.shen -l lib/http-server.shen \
	  -l lib/memory.shen -l tests/http_server.shen | $(FFI_RESULT)
	sh tests/http_request_image.sh $(SHEN_JIT)
	sh tests/http_stream_image.sh $(SHEN_JIT)
	sh tests/http_listener.sh $(SHEN_JIT)

fuzz-native: $(BUILD)/shen-jit
	python3 tests/native_fuzz.py

# Each primitive over generated values, however it is compiled and through C (about a minute).
test-differential: $(BUILD)/shen-jit
	sh tests/differential.sh $(SHEN_JIT) $(BUILD)/differential

# The port's overrides against the kernel's own definitions, as compiled and through C (a second). The
# limit refuses a huge vector soon, and the kernel's shen.f-error asks a question.
OVERRIDES_TEST = SHEN_JIT_MAX_HEAP=256M $(1) $(BUILD)/shen-jit script tests/overrides.shen $(KERNEL_DIR) src/port/shen-jit.kl $(BUILD)/overrides < /dev/null | \
	  grep -a 'FAIL\|uncaught\| checks, ' | awk '{ print } END { exit !/ 0 failed$$/ }'

test-overrides: $(BUILD)/shen-jit
	mkdir -p $(BUILD)/overrides
	$(call OVERRIDES_TEST,)
	$(call OVERRIDES_TEST,SHEN_JIT_SLOW_PRIMS=1)

# Datalog (lib/datalog.shen): fixtures by hand, its kernels, and generated programs against its reference. A macro
# applies only to files read after it, so the tests load as a file of their own.
test-datalog: $(BUILD)/shen-jit
	SHEN_JIT_GC_STRESS=$(GC_STRESS) $(BUILD)/shen-jit eval -l lib/native.shen -l lib/datalog.shen -l tests/datalog-generate.shen -l tests/datalog.shen < /dev/null | \
	  grep -a 'FAIL\|uncaught\| checks, ' | awk '{ print } END { exit !/ 0 failed$$/ }'
	sh example-apps/depends/test.sh $(BUILD)/shen-jit $(KERNEL_DIR)/klambda

# The workloads against Soufflé, if souffle and a C++ compiler are there: results, then time.
bench-datalog-souffle: $(BUILD)/shen-jit
	sh tests/bench/datalog-souffle.sh $(BUILD)/shen-jit

# The same programs against SWI-Prolog's tabling, an engine that shares nothing with it, if swipl is there.
test-datalog-swipl: $(BUILD)/shen-jit
	sh tests/datalog-swipl.sh $(BUILD)/shen-jit

# What differs from Shen/Scheme, to read: either may be wrong, so it checks nothing.
differential-scheme: $(BUILD)/shen-jit
	python3 tests/differential_scheme.py $(BUILD)/shen-jit $(SHEN_SCHEME) $(BUILD)/differential-scheme

# C functions called from Shen (lib/ffi.shen), against a library made for it, then from
# typed code, which needs (tc +) before the file is read, and C written for Shen, and the
# libraries over them. A suite's result is its failures and its count: -a, as a failure may
# print raw bytes, which would make grep hide the count.
FFI_RESULT := grep -a '^FAIL \|^[0-9]* passed' | awk '{ print } END { exit !/ 0 failed/ }'
# The tests that any kind of build runs, given how to run the executable.
FFI_SUITES = $(1) eval -l ../lib/ffi.shen -l ../tests/ffi.shen | $(FFI_RESULT) && \
	  $(1) eval -l ../lib/ffi.shen -l ../tests/ffi_c.shen | $(FFI_RESULT) && \
	  $(1) eval -l ../lib/ffi.shen -l ../lib/sqlite.shen -l ../tests/sqlite.shen | $(FFI_RESULT) && \
	  $(1) eval -l ../lib/ffi.shen -l ../lib/socket.shen -l ../tests/socket.shen | $(FFI_RESULT) && \
	  $(1) eval -l ../lib/ffi.shen -l ../lib/native.shen -l ../lib/memory.shen -l ../tests/memory.shen | $(FFI_RESULT) && \
	  $(1) eval -l ../lib/ffi.shen -l ../lib/memory.shen -l ../lib/handle.shen -l ../tests/handle.shen | $(FFI_RESULT) && \
	  $(1) eval -l ../lib/ffi.shen -l ../lib/mmap.shen -l ../lib/handle.shen -l ../tests/mmap.shen | $(FFI_RESULT)

$(FFI_TEST_LIB): tests/ffi_lib.c include/shen.h | $(BUILD)
	$(CC) -std=c11 -O1 -g -Wall -Wextra -Wno-unused-parameter -Iinclude -shared -fPIC -pthread -o $@ $<

test-ffi: $(BUILD)/shen-jit $(FFI_TEST_LIB)
	cd $(BUILD) && SHEN_JIT_GC_STRESS=$(GC_STRESS) ./shen-jit eval -l ../lib/ffi.shen -e '(tc +)' -l ../tests/ffi_typed.shen | $(FFI_RESULT)
	cd $(BUILD) && $(call FFI_SUITES,SHEN_JIT_GC_STRESS=$(GC_STRESS) ./shen-jit)

# A real Ctrl-C to the REPL on Windows, which tests/cli.sh cannot send there.
test-ctrlc-windows: $(BUILD)/shen-jit
	python3 tests/ctrlc_windows.py $(BUILD)/shen-jit$(EXE)

# The suites on Linux arm64 and x86-64, in Docker (tests/linux.sh).
test-linux:
	sh tests/linux.sh

# The kernel's benchmarks and Shen/Scheme's realistic ones, run by shen-jit
# and Shen/Scheme and compared (best of BENCH_SAMPLES; run counts divided by
# 10^BENCH_OFFSET). Shen/Scheme's results are kept, since they do not change.
# SEAL=1 runs shen-jit with user definitions sealed (shen-jit --seal).
SHEN_SCHEME ?= .deps/shen-scheme/bin/shen-scheme
BENCH_DIR ?= .deps/shen-scheme-src
BENCH_OFFSET ?= 1
BENCH_SAMPLES ?= 3
BENCH_ARGS = eval -e '(set bench-offset $(BENCH_OFFSET))' -e '(set bench-samples $(BENCH_SAMPLES))' \
             -e '(load "$(abspath tests/bench/suite.shen)")'
BENCH_REF := $(BUILD)/bench/shen-scheme-$(BENCH_OFFSET)-$(BENCH_SAMPLES).txt

$(BENCH_REF): tests/bench/suite.shen
	mkdir -p $(BUILD)/bench
	cd $(BENCH_DIR) && $(abspath $(SHEN_SCHEME)) $(BENCH_ARGS) > $(abspath $@)

BENCH_OUT := $(BUILD)/bench/shen-jit$(if $(SEAL),-sealed).txt

bench: all $(BENCH_REF)
	cd $(BENCH_DIR) && $(SHEN_JIT) $(if $(SEAL),--seal) $(BENCH_ARGS) > $(abspath $(BENCH_OUT))
	python3 tests/bench/compare.py $(BENCH_OUT) $(BENCH_REF)

# Workloads never used for tuning (tests/bench/independent.py): the kernel's
# test suite and extension tests, installing the standard library, the
# contract examples and startup, against Shen/Scheme.
STLIB_DIR ?=
INDEPENDENT_ROUNDS ?= 7

bench-independent: all
	python3 tests/bench/independent.py --rounds $(INDEPENDENT_ROUNDS) --kernel $(KERNEL_DIR) \
	  $(if $(STLIB_DIR),--stlib $(STLIB_DIR)) --scheme $(SHEN_SCHEME) $(SHEN_JIT)

# Numeric programs in C, in Shen with boxed reals, and in Shen with real registers.
NUMERIC_RESULT := grep -a '^[a-z]* [0-9.e-]* s check'
# Datalog's workloads: a generated graph of each shape, and the call graph of the kernel's KL, closed and analysed.
bench-datalog: $(BUILD)/shen-jit
	$(BUILD)/shen-jit eval -l lib/native.shen -l lib/datalog.shen -l tests/bench/datalog.shen -e '(db.main "$(KERNEL_DIR)/klambda")' < /dev/null | \
	  grep -a ' | \|^facts\|uncaught'
	for c in chain-a chain-b small-a small-b large-a large-b; do for a in false true; do \
	  $(BUILD)/shen-jit eval -l lib/native.shen -l lib/datalog.shen -l tests/bench/datalog.shen -l tests/bench/datalog-orders.shen -e "(do.run $$c $$a)" < /dev/null | grep -a ' | ' | head -1; \
	done; done

bench-numeric: $(BUILD)/shen-jit
	$(CC) -O2 -ffp-contract=off -o $(BUILD)/numeric-c tests/bench/numeric.c -lm
	$(BUILD)/numeric-c
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/memory.shen -l tests/bench/numeric.shen | $(NUMERIC_RESULT)
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/native.shen -l lib/memory.shen -l tests/bench/numeric-raw.shen | $(NUMERIC_RESULT)
	$(CC) -O2 -ffp-contract=off -o $(BUILD)/trace-c tests/bench/trace.c -lm
	$(BUILD)/trace-c
	$(BUILD)/shen-jit eval -l lib/ffi.shen -l lib/native.shen -l lib/memory.shen -l lib/mmap.shen -l lib/handle.shen -l tests/bench/trace.shen | $(NUMERIC_RESULT)

measure: $(BUILD)/test_jit $(BUILD)/bench/programs.sbc
	cd $(BUILD) && ./test_jit bench/programs.sbc --measure

$(BUILD):
	mkdir -p $(BUILD)

test: $(BUILD)/test_runtime
	cd $(BUILD) && ./test_runtime

# The same tests under AddressSanitizer and UndefinedBehaviorSanitizer, and as
# x86-64 code (under Rosetta on Apple silicon).
SAN_FLAGS := -std=c11 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer
TESTS := test_runtime test_jit test_ops test_kl
TEST_ARGS_test_runtime :=
TEST_ARGS_test_jit := bench/programs.sbc
TEST_ARGS_test_ops := kl/ops.sbc
TEST_ARGS_test_kl := stage0 ../tests/kl/eval-cases.kl

test-san: $(BUILD)/bench/programs.sbc $(BUILD)/kl/ops.sbc $(BUILD)/stage0/.done $(FFI_TEST_LIB) | $(BUILD)
	for t in $(TESTS); do \
	  $(CC) $(SAN_FLAGS) $(SLJIT_SRC_FLAGS) -DSJ_BUILD_ID='"$(BUILD_ID)"' -o $(BUILD)/$$t-san tests/$$t.c $(RUNTIME_SRC) vendor/sljit/sljit_src/sljitLir.c $(LDLIBS) || exit 1; done
	cd $(BUILD) && ./test_runtime-san && ./test_jit-san $(TEST_ARGS_test_jit) && ./test_ops-san $(TEST_ARGS_test_ops) && ./test_kl-san $(TEST_ARGS_test_kl)
	$(CC) $(SAN_FLAGS) $(SLJIT_SRC_FLAGS) -DSJ_BUILD_ID='"$(BUILD_ID)"' -DSJ_VERSION='"$(VERSION)"' -o $(BUILD)/shen-jit-san src/runtime/main.c $(RUNTIME_SRC) vendor/sljit/sljit_src/sljitLir.c $(LDLIBS)
	cd $(BUILD) && ./shen-jit-san --stage1 stage0 shen-jit-san.img && \
	  $(call FFI_SUITES,ASAN_OPTIONS=detect_leaks=0:allocator_may_return_null=1 SHEN_JIT_IMAGE=shen-jit-san.img ./shen-jit-san)
	ASAN_OPTIONS=detect_leaks=0:allocator_may_return_null=1 SHEN_JIT_IMAGE=$(abspath $(BUILD)/shen-jit-san.img) \
	  CC="$(CC)" CFLAGS="$(SAN_FLAGS)" sh tests/curl.sh $(BUILD)/shen-jit-san$(EXE)
	ASAN_OPTIONS=detect_leaks=0:allocator_may_return_null=1 SHEN_JIT_IMAGE=$(abspath $(BUILD)/shen-jit-san.img) \
	  CC="$(CC)" CFLAGS="$(SAN_FLAGS)" sh tests/fs.sh $(BUILD)/shen-jit-san$(EXE)
	ASAN_OPTIONS=detect_leaks=0:allocator_may_return_null=1 SHEN_JIT_IMAGE=$(abspath $(BUILD)/shen-jit-san.img) \
	  CC="$(CC)" CFLAGS="$(SAN_FLAGS)" sh tests/process.sh $(BUILD)/shen-jit-san$(EXE)
	ASAN_OPTIONS=detect_leaks=0:allocator_may_return_null=1 SHEN_JIT_IMAGE=$(abspath $(BUILD)/shen-jit-san.img) \
	  CC="$(CC)" CFLAGS="$(SAN_FLAGS)" sh tests/tree_sitter.sh $(BUILD)/shen-jit-san$(EXE)

test-x86: $(BUILD)/bench/programs.sbc $(BUILD)/kl/ops.sbc $(BUILD)/stage0/.done | $(BUILD)
	for t in $(TESTS); do \
	  $(CC) -arch x86_64 -std=c11 -O2 -w $(SLJIT_SRC_FLAGS) -DSJ_BUILD_ID='"$(BUILD_ID)"' -o $(BUILD)/$$t-x86 tests/$$t.c $(RUNTIME_SRC) vendor/sljit/sljit_src/sljitLir.c $(LDLIBS) || exit 1; done
	cd $(BUILD) && ./test_runtime-x86 && ./test_jit-x86 $(TEST_ARGS_test_jit) && ./test_ops-x86 $(TEST_ARGS_test_ops) && ./test_kl-x86 $(TEST_ARGS_test_kl)
	$(CC) -arch x86_64 -std=c11 -O2 -w $(SLJIT_SRC_FLAGS) -DSJ_BUILD_ID='"$(BUILD_ID)"' -DSJ_VERSION='"$(VERSION)"' -o $(BUILD)/shen-jit-x86 src/runtime/main.c $(RUNTIME_SRC) vendor/sljit/sljit_src/sljitLir.c $(LDLIBS)
	$(CC) -arch x86_64 -arch arm64 -std=c11 -O1 -w -Iinclude -shared -o $(FFI_TEST_LIB) tests/ffi_lib.c
	cd $(BUILD) && ./shen-jit-x86 --stage1 stage0 shen-jit-x86.img && \
	  $(call FFI_SUITES,SHEN_JIT_IMAGE=shen-jit-x86.img ./shen-jit-x86)

clean:
	rm -f $(BUILD)/*.o $(BUILD)/test_* $(BUILD)/load_kernel $(BUILD)/*.img $(BUILD)/runtime $(BUILD)/shen-jit

$(BUILD)/load_kernel: tests/load_kernel.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(RUNTIME_HDR)
	$(CC) $(CFLAGS) $(SLJIT_FLAGS) -o $@ tests/load_kernel.c $(RUNTIME_OBJ) $(SLJIT_OBJ) $(LDLIBS)

# Loads the lowerer's stage 0 output and checks an image round trip.
load-kernel: $(BUILD)/load_kernel $(BUILD)/shen-jit.img
	cd $(BUILD) && ./load_kernel stage0/*.sbc && cmp kernel-code.img kernel-code2.img && echo "image round trip identical"
	cd $(BUILD) && ./load_kernel --image shen-jit.img && cmp shen-jit.img image2.img && echo "kernel-scale image round trip identical"
