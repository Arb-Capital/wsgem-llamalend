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

# @-silencing hides the recipe TEXT, but cast and forge print the full RPC endpoint -- provider
# token included -- in their own stderr diagnostics on transport errors ("error sending request
# for url (...)"). Every network-touching cast/forge stderr below therefore streams through this
# filter: failures stay descriptive, credentials do not survive. The filter works byte-by-byte
# rather than line-by-line so cast's newline-free keystore password prompt still renders live.
# The `2> >(...)` process substitution needs bash (recipes below are otherwise POSIX; bash is a
# superset), and it leaves each command's exit status untouched -- the preflight
# `|| { ...; exit 1; }` handlers keep working.
SHELL  := /bin/bash
REDACT := python3 scripts/redact_rpc_stderr.py

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

# What a plain transaction needs, which is the deploy set MINUS the Etherscan key: `cast send`
# submits nothing to verify, so requiring a verification credential would fail an otherwise
# perfectly good keeper configuration.
define require_send_env
	test -n "$${ETH_RPC_URL}"  || { echo "ETH_RPC_URL is required";                  exit 1; }; \
	test -n "$${ETH_FROM}"     || { echo "ETH_FROM (sender address) is required";    exit 1; }; \
	test -n "$${ETH_KEYSTORE}" || { echo "ETH_KEYSTORE (keystore path) is required"; exit 1; }
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
		--rpc-url ${ETH_RPC_URL} -vvvv 2> >($(REDACT) >&2)

oracle-deploy :
	@$(call require_deploy_env)
	make clean && make build
	@forge script script/WstGBP.s.sol:WstGBPOracleScript \
		--rpc-url $(ETH_RPC_URL) --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --verify --slow --broadcast -vvvv 2> >($(REDACT) >&2)

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
		--rpc-url ${ETH_RPC_URL} -vvvv 2> >($(REDACT) >&2)

market-deploy :
	@$(call require_deploy_env)
	@$(call require_oracle)
	make clean && make build
	@forge script script/WstGBP.s.sol:WstGBPMarketScript \
		--rpc-url $(ETH_RPC_URL) --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --verify --slow --broadcast -vvvv 2> >($(REDACT) >&2)

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
		$(GAS_FLAGS) --verify --slow --broadcast --resume -vvvv 2> >($(REDACT) >&2)

# --- Keeper ------------------------------------------------------------------------------------
#
# Both shims are permissionless and take no arguments. Nothing breaks without this -- both views
# compute from live state -- but a daily poke does two things: it records publications on a market
# with no traffic of its own, and it keeps the oracle's banked upside allowance at one day's worth
# (0.25%) instead of letting it reach MAX_ELAPSED's seven (1.75%). See docs/07-operations.md.
#
# WSGEM_ORACLE and WSGEM_CALC select what to poke. Run it from market creation, not from the DAO
# vote: the borrow_cap == 0 window is exactly when nothing else is driving price_w.
# PREFLIGHT, and why it is not optional here. A call to an address with no code SUCCEEDS on the
# EVM -- it is indistinguishable from a function that returned nothing. So a keeper pointed at the
# wrong chain, or at an address that is right on mainnet and empty on a fork, sends two
# transactions, gets two green receipts, and updates neither checkpoint. A scheduled job would
# report success forever while the banked allowance this target exists to bound kept growing.
# The deploy targets get this from the script's own asserts; a bare `cast send` has none, so the
# checks are here: mainnet, both addresses carry code, and both shims agree on which wsgem they
# are for -- which is what catches a stale address from a previous instance.
poke :
	@$(call require_send_env)
	@test -n "$${WSGEM_ORACLE}" || { echo "WSGEM_ORACLE is required"; exit 1; }
	@test -n "$${WSGEM_CALC}"   || { echo "WSGEM_CALC is required";   exit 1; }
	@# Each result is captured, its exit status checked, and its emptiness checked BEFORE any
	@# comparison. Inlining these as `test "$$(cast ...)" != "0x"` looks equivalent and is not: a
	@# cast that fails writes its diagnostic to stderr and nothing to stdout, so the comparison
	@# becomes `"" != "0x"`, which is TRUE. A preflight whose whole purpose is to refuse to send
	@# blind would then pass precisely when the RPC is unreachable. The wiring comparison degrades
	@# the same way, into `"" = ""`.
	@#
	@# The reads go through KEYLESS for the same reason the dry runs do: `cast` resolves a wallet
	@# from ETH_FROM/ETH_KEYSTORE whenever they are exported, even for an eth_call that needs
	@# neither. An unreadable keystore then fails the READ, and the preflight reports "WSGEM()
	@# reverted" when the contract is fine and only the signing config is wrong.
	@chain_=$$($(KEYLESS) cast chain --rpc-url $${ETH_RPC_URL} 2> >($(REDACT) >&2)) \
		|| { echo "preflight: cast chain failed -- RPC unreachable?"; exit 1; }; \
	test "$$chain_" = "ethlive" \
		|| { echo "ETH_RPC_URL must point at Ethereum mainnet (got: $$chain_)"; exit 1; }; \
	for pair_ in "WSGEM_ORACLE:$${WSGEM_ORACLE}" "WSGEM_CALC:$${WSGEM_CALC}"; do \
		name_=$${pair_%%:*}; addr_=$${pair_#*:}; \
		code_=$$($(KEYLESS) cast code $$addr_ --rpc-url $${ETH_RPC_URL} 2> >($(REDACT) >&2)) \
			|| { echo "preflight: cast code failed for $$name_"; exit 1; }; \
		case "$$code_" in ""|"0x") echo "$$name_ has no code at $$addr_"; exit 1;; esac; \
	done; \
	owsgem_=$$($(KEYLESS) cast call $${WSGEM_ORACLE} 'WSGEM()(address)' --rpc-url $${ETH_RPC_URL} 2> >($(REDACT) >&2)) \
		|| { echo "preflight: WSGEM() reverted on the oracle"; exit 1; }; \
	cwsgem_=$$($(KEYLESS) cast call $${WSGEM_CALC} 'WSGEM()(address)' --rpc-url $${ETH_RPC_URL} 2> >($(REDACT) >&2)) \
		|| { echo "preflight: WSGEM() reverted on the calculator"; exit 1; }; \
	test -n "$$owsgem_" && test -n "$$cwsgem_" \
		|| { echo "preflight: WSGEM() returned nothing -- wrong contract?"; exit 1; }; \
	test "$$owsgem_" = "$$cwsgem_" \
		|| { echo "wired to different wsgems: $$owsgem_ vs $$cwsgem_"; exit 1; }
	@cast send $(WSGEM_ORACLE) "price_w()" \
		--rpc-url $(ETH_RPC_URL) --from $(ETH_FROM) --keystore $(ETH_KEYSTORE) $(GAS_FLAGS) 2> >($(REDACT) >&2)
	@cast send $(WSGEM_CALC) "rate_w()" \
		--rpc-url $(ETH_RPC_URL) --from $(ETH_FROM) --keystore $(ETH_KEYSTORE) $(GAS_FLAGS) 2> >($(REDACT) >&2)

.PHONY: all deps build clean sizes fmt test test-fork coverage gen-report serve-report \
	oracle-dry oracle-deploy market-dry market-deploy market-resume poke
