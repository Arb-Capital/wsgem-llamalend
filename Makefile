-include .env

# `-include` defines make variables, not environment variables. Without `export`, the fork test
# helper and any other non-forge child would see none of it and silently fall back to defaults.
export

all         :; make deps && make build && make test

deps        :; forge install

build       :; forge build
clean       :; forge clean && rm -rf -- ./cache
sizes       :; forge build --sizes
fmt         :; forge fmt

# Unit and invariant tests. No RPC, no network, no node. Fork tests are excluded on purpose.
test        :; forge test --no-match-path "test/fork/*" -vv

# Fork tests. Hard-fails without a mainnet RPC rather than silently passing.
test-fork   :; ./scripts/forge_test_fork.sh

# Coverage. Fork tests stay excluded for the same reason as `test`. The report is filtered to
# src/ -- the suite and the deploy scripts are not the audited surface. The gas bench is excluded
# from the RUN, not just the report: coverage builds are instrumented with the optimizer off, so
# it would overwrite snapshots/WsgemGasBench.json with meaningless numbers, and it exercises no
# path the functional suites do not. The local invariant suite is fast (no RPC) and stays in.
COVERAGE_EXCLUDE := (test/|script/)
COVERAGE_SKIP    := (GasBench)
COVERAGE_ARGS    := --no-match-path "test/fork/*" --no-match-coverage "$(COVERAGE_EXCLUDE)" --no-match-contract "$(COVERAGE_SKIP)"

coverage    :; forge coverage $(COVERAGE_ARGS)

# Full HTML report into docs/coverage-report/ (gitignored). Regenerates lcov.info. Needs lcov's
# genhtml.
gen-report  :; forge coverage $(COVERAGE_ARGS) --report lcov && genhtml lcov.info --output-directory docs/coverage-report

# Serve the report at http://localhost:8000 -- a Flatpak/Snap browser opening index.html directly
# routes through the xdg document portal, which shares only that one file with the sandbox and so
# drops the report's CSS/images.
serve-report :; python3 -m http.server 8000 --directory docs/coverage-report

# Keyless forge-script invocations (dry runs) must strip every wallet-resolving env var a previous
# deploy session may have left exported. forge binds ETH_FROM/--sender, ETH_KEYSTORE/--keystore,
# ETH_KEYSTORE_ACCOUNT/--account and ETH_PASSWORD/--password, and couples them in argument
# parsing, so a stray one turns a keyless simulation into a keystore prompt or a parse failure.
# The gas vars are stripped too: forge reads ETH_GAS_PRICE/ETH_PRIO_FEE from the environment
# directly, an empty one is a parse error, and a simulation prices nothing anyway.
KEYLESS := env -u ETH_FROM -u ETH_KEYSTORE -u ETH_KEYSTORE_ACCOUNT -u ETH_PASSWORD \
               -u ETH_GAS_PRICE -u ETH_PRIO_FEE

# Gas overrides are optional, so they must be omitted entirely when unset rather than passed empty:
# `--priority-gas-price` with no value swallows the next flag as its argument, and forge exits.
# Both are `$(if ...)`, which expands to nothing when the variable is empty or undefined.
#
# ETH_GAS_PRICE maps to --with-gas-price, NOT --base-fee. `--base-fee` is an alias for
# `--block-base-fee-per-gas`, which sets the base fee of the SIMULATED block -- it does not price
# the broadcast transaction. `--with-gas-price` is the transaction knob (max fee per gas on an
# EIP-1559 transaction). Getting this wrong silently sends at forge's estimate instead of yours.
GAS_FLAGS := $(if $(ETH_PRIO_FEE),--priority-gas-price $(ETH_PRIO_FEE)) \
             $(if $(ETH_GAS_PRICE),--with-gas-price $(ETH_GAS_PRICE))

# Guards for the variables a broadcast cannot proceed without. Tested as $${VAR} rather than
# $(VAR) so make does not bake the value into the recipe text, where `make -n` would print it.
define require_deploy_env
	test -n "$${ETH_RPC_URL}"        || { echo "ETH_RPC_URL is required";                  exit 1; }; \
	test -n "$${ETH_FROM}"           || { echo "ETH_FROM (deployer address) is required";  exit 1; }; \
	test -n "$${ETH_KEYSTORE}"       || { echo "ETH_KEYSTORE (keystore path) is required"; exit 1; }; \
	test -n "$${ETHERSCAN_API_KEY}"  || { echo "ETHERSCAN_API_KEY is required for --verify"; exit 1; }
endef

# The dry runs need only the RPC, but they need it guarded for the same reason GAS_FLAGS is: an
# empty ${ETH_RPC_URL} makes `--rpc-url` swallow the next flag as its argument.
define require_rpc
	test -n "$${ETH_RPC_URL}" || { echo "ETH_RPC_URL is required"; exit 1; }
endef

# A market run without WSGEM_ORACLE deploys a FRESH oracle -- by definition an unobserved one,
# and the documented order (docs/05) is oracle first, market only after observation. The dry run
# reminds and may simulate the from-scratch pipeline; the broadcast requires the variable here,
# and the script itself reverts on any broadcast without it, however invoked.
define remind_oracle_reuse
	test -n "$${WSGEM_ORACLE}" || { \
	echo "NOTE: WSGEM_ORACLE is unset -- this SIMULATES deploying a fresh oracle and building the"; \
	echo "      market on it. A real market deploy requires WSGEM_ORACLE (docs/05 step 3)."; }
endef

define require_oracle
	test -n "$${WSGEM_ORACLE}" || { \
	echo "WSGEM_ORACLE is required: the market is deployed against an oracle that already exists"; \
	echo "and has been observed across a publication (docs/05 step 2). Deploy and observe the"; \
	echo "oracle first, then export WSGEM_ORACLE=<address>."; exit 1; }
endef

# --- Oracle ------------------------------------------------------------------------------------
#
# The oracle shim is deployable on its own, ahead of the market, so its reported price can be
# watched against the live wsgem across at least one NAV poke before anything depends on it.

# The forge lines are @-silenced: make would otherwise echo the expanded recipe, and the recipe
# contains ETH_RPC_URL -- which for most providers embeds an API key -- into any log of the run.
#
# Every dry run and deploy below starts from `make clean`: forge script broadcasts whatever
# artifact sits in out/, and a stale one -- built from other source or other compiler settings --
# deploys silently. The clean ties the broadcast bytecode to the current tree, at the cost of a
# full rebuild. The dry runs pay it too, so a dry run rehearses exactly what the deploy will do.
oracle-dry  :
	@$(call require_rpc)
	@make clean && make build && $(KEYLESS) forge script script/WstGBP.s.sol:WstGBPOracleScript \
		--rpc-url ${ETH_RPC_URL} -vvvv

oracle-deploy :
	@$(call require_deploy_env)
	make clean && make build
	@forge script script/WstGBP.s.sol:WstGBPOracleScript \
		--rpc-url $(ETH_RPC_URL) --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --verify --slow --broadcast -vvvv

# --- Market ------------------------------------------------------------------------------------
#
# Deploys the rate calculator, the monetary policy (from vendored initcode) and then calls
# LendFactory.create. Market creation is permissionless, but the market ships with a zero borrow
# cap -- see docs/06-post-deployment.md.
#
# WSGEM_ORACLE selects the already-deployed oracle shim. The dry run simulates a from-scratch
# pipeline when it is unset; a broadcast requires it -- the oracle is deployed and observed
# first, per docs/05.

market-dry  :
	@$(call require_rpc)
	@$(call remind_oracle_reuse)
	@make clean && make build && $(KEYLESS) forge script script/WstGBP.s.sol:WstGBPMarketScript \
		--rpc-url ${ETH_RPC_URL} -vvvv

market-deploy :
	@$(call require_deploy_env)
	@$(call require_oracle)
	make clean && make build
	@forge script script/WstGBP.s.sol:WstGBPMarketScript \
		--rpc-url $(ETH_RPC_URL) --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --verify --slow --broadcast -vvvv

# Resuming a partial market broadcast MUST go through this target, never a direct
# `forge script --resume`: forge replays the saved transaction backlog without re-executing the
# script, so the Solidity WSGEM_ORACLE guard cannot run on a resume. This target re-applies it
# here instead. No clean/build -- the backlog's transactions are already fixed; a rebuild cannot
# change what gets resumed.
market-resume :
	@$(call require_deploy_env)
	@$(call require_oracle)
	@forge script script/WstGBP.s.sol:WstGBPMarketScript \
		--rpc-url $(ETH_RPC_URL) --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --verify --slow --broadcast --resume -vvvv

.PHONY: all deps build clean sizes fmt test test-fork coverage gen-report serve-report \
	oracle-dry oracle-deploy market-dry market-deploy market-resume
