
.PHONY: clean distclean deps deps-polkadot                           \
        build                                                        \
        polkadot-runtime-source polkadot-runtime-loaded              \
        specs                                                        \
        test test-can-build-specs test-python-config test-fuse-rules

# Settings
# --------

BUILD_DIR       := .build
DEPS_DIR        := deps
DEFN_DIR        := $(BUILD_DIR)/defn
KWASM_SUBMODULE := $(DEPS_DIR)/wasm-semantics

K_RELEASE := $(KWASM_SUBMODULE)/deps/k/k-distribution/target/release/k
K_BIN     := $(K_RELEASE)/bin
K_LIB     := $(K_RELEASE)/lib

KWASM_DIR  := .
KWASM_MAKE := make --directory $(KWASM_SUBMODULE) BUILD_DIR=../../$(BUILD_DIR)

export K_RELEASE
export KWASM_DIR

PATH := $(CURDIR)/$(KWASM_SUBMODULE):$(CURDIR)/$(K_BIN):$(PATH)
export PATH

PYTHONPATH := $(K_LIB)
export PYTHONPATH

PANDOC_TANGLE_SUBMODULE := $(KWASM_SUBMODULE)/deps/pandoc-tangle
TANGLER                 := $(PANDOC_TANGLE_SUBMODULE)/tangle.lua
LUA_PATH                := $(PANDOC_TANGLE_SUBMODULE)/?.lua;;
export TANGLER
export LUA_PATH

KPOL := ./kpol

clean:
	rm -rf $(DEFN_DIR) tests/*.out

distclean: clean
	rm -rf $(BUILD_DIR)

deps:
	git submodule update --init --recursive -- $(KWASM_SUBMODULE)
	$(KWASM_MAKE) deps

# Polkadot Setup
# --------------

POLKADOT_SUBMODULE    := $(DEPS_DIR)/substrate
POLKADOT_RUNTIME_WASM := $(POLKADOT_SUBMODULE)/target/release/wbuild/node-template-runtime/node_template_runtime.compact.wasm

deps-polkadot:
	rustup update nightly
	rustup target add wasm32-unknown-unknown --toolchain nightly
	cargo install --git https://github.com/alexcrichton/wasm-gc

# Useful Builds
# -------------

KOMPILE_OPTIONS :=

MAIN_MODULE        := WASM-WITH-K-TERM
MAIN_SYNTAX_MODULE := WASM-WITH-K-TERM-SYNTAX
MAIN_DEFN_FILE     := wasm-with-k-term

SUBDEFN := kwasm
export SUBDEFN

build: build-llvm build-haskell

# Semantics Build
# ---------------

build-%: $(DEFN_DIR)/$(SUBDEFN)/%/$(MAIN_DEFN_FILE).k
	$(KWASM_MAKE) build-$*                       \
	    DEFN_DIR=../../$(DEFN_DIR)/$(SUBDEFN)    \
	    MAIN_MODULE=$(MAIN_MODULE)               \
	    MAIN_SYNTAX_MODULE=$(MAIN_SYNTAX_MODULE) \
	    MAIN_DEFN_FILE=$(MAIN_DEFN_FILE)         \
	    KOMPILE_OPTIONS=$(KOMPILE_OPTIONS)

.SECONDARY: $(DEFN_DIR)/$(SUBDEFN)/llvm/$(MAIN_DEFN_FILE).k    \
            $(DEFN_DIR)/$(SUBDEFN)/haskell/$(MAIN_DEFN_FILE).k

$(DEFN_DIR)/$(SUBDEFN)/llvm/%.k: %.md $(TANGLER)
	@mkdir -p $(dir $@)
	pandoc --from markdown --to $(TANGLER) --metadata=code:".k" $< > $@

$(DEFN_DIR)/$(SUBDEFN)/haskell/%.k: %.md $(TANGLER)
	@mkdir -p $(dir $@)
	pandoc --from markdown --to $(TANGLER) --metadata=code:".k" $< > $@

# Verification Source Build
# -------------------------

CONCRETE_BACKEND := llvm
SYMBOLIC_BACKEND := haskell

polkadot-runtime-source: src/polkadot-runtime.wat
polkadot-runtime-loaded: src/polkadot-runtime.loaded.json

src/polkadot-runtime.loaded.json: src/polkadot-runtime.wat.json
	$(KPOL) run --backend $(CONCRETE_BACKEND) $< --parser cat --output json > $@

src/polkadot-runtime.wat.json: src/polkadot-runtime.env.wat src/polkadot-runtime.wat
	cat $^ | $(KPOL) kast --backend $(CONCRETE_BACKEND) - json > $@

src/polkadot-runtime.wat: $(POLKADOT_RUNTIME_WASM)
	wasm2wat $< > $@

$(POLKADOT_RUNTIME_WASM):
	git submodule update --init --recursive -- $(POLKADOT_SUBMODULE)
	cd $(POLKADOT_SUBMODULE) && cargo build --package node-template --release

# Generate Execution Traces
# -------------------------

# TODO: Hacky way for selecting coverage file  because `--coverage-file` is not respected at all
#       So we have to forcibly remove any existing coverage files, and pick up the generated one with a wildcard
#       Would be better without the `rm -rf ...`, and with these:
#           $(KPOL) run --backend $(CONCRETE_BACKEND) $(SIMPLE_TESTS)/$*.wast --coverage-file $(SIMPLE_TESTS)/$*.wast.$(CONCRETE_BACKEND)-coverage
#           ./translateCoverage.py _ _ $(SIMPLE_TESTS)/$*.wast.$(SYMBOLIC_BACKEND)-coverage
$(KWASM_SUBMODULE)/tests/simple/%.wast.coverage-$(CONCRETE_BACKEND): $(KWASM_SUBMODULE)/tests/simple/%.wast
	rm -rf $(DEFN_DIR)/coverage/$(CONCRETE_BACKEND)/$(MAIN_DEFN_FILE)-kompiled/*_coverage.txt
	SUBDEFN=coverage $(KPOL) run --backend $(CONCRETE_BACKEND) $<
	mv $(DEFN_DIR)/coverage/$(CONCRETE_BACKEND)/$(MAIN_DEFN_FILE)-kompiled/*_coverage.txt $@

$(KWASM_SUBMODULE)/tests/simple/%.wast.coverage-$(SYMBOLIC_BACKEND): $(KWASM_SUBMODULE)/tests/simple/%.wast.coverage-$(CONCRETE_BACKEND)
	./translateCoverage.py $(DEFN_DIR)/coverage/$(CONCRETE_BACKEND)/$(MAIN_DEFN_FILE)-kompiled \
	                       $(DEFN_DIR)/kwasm/$(SYMBOLIC_BACKEND)/$(MAIN_DEFN_FILE)-kompiled    \
	                       $< > $@
	# SUBDEFN=coverage $(KPOL) run --backend $(SYMBOLIC_BACKEND) $*.wast.coverage-$(SYMBOLIC_BACKEND) --rule-sequence

# Specification Build
# -------------------

SPEC_NAMES := set-free-balance

SPECS_DIR := $(BUILD_DIR)/specs
ALL_SPECS := $(patsubst %, $(SPECS_DIR)/%-spec.k, $(SPEC_NAMES))

specs: $(ALL_SPECS)

$(SPECS_DIR)/%-spec.k: %.md
	@mkdir -p $(SPECS_DIR)
	pandoc --from markdown --to $(TANGLER) --metadata=code:.k $< > $@

# Testing
# -------

CHECK := git --no-pager diff --no-index --ignore-all-space

test: test-can-build-specs test-fuse-rules

test-can-build-specs: $(ALL_SPECS:=.can-build)

$(SPECS_DIR)/%-spec.k.can-build: $(SPECS_DIR)/%-spec.k
	kompile --backend $(SYMBOLIC_BACKEND) -I $(SPECS_DIR)                  \
	    --main-module   $(shell echo $* | tr '[:lower:]' '[:upper:]')-SPEC \
	    --syntax-module $(shell echo $* | tr '[:lower:]' '[:upper:]')-SPEC \
	    $<
	rm -rf $*-kompiled

all_simple_tests := $(wildcard $(KWASM_SUBMODULE)/tests/simple/*.wast)
bad_simple_tests := $(KWASM_SUBMODULE)/tests/simple/arithmetic.wast \
                    $(KWASM_SUBMODULE)/tests/simple/comparison.wast \
                    $(KWASM_SUBMODULE)/tests/simple/memory.wast
simple_tests     := $(filter-out $(bad_simple_tests), $(all_simple_tests))

test-fuse-rules: $(KWASM_SUBMODULE)/tests/simple/branching.wast.coverage-$(SYMBOLIC_BACKEND)

# Python Configuration Build
# --------------------------

test-python-config:
	python3 pykWasm.py
