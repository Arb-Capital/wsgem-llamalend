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

# Deeper invariant soak on the `intense` profile (512 runs x 256 depth against the default
# 64 x 128). Pre-release confidence runs. Only the invariant suite: the profile changes nothing
# for the unit and fuzz tests, so re-running them here would add minutes and no information.
test-intense :; FOUNDRY_PROFILE=intense forge test --match-path "test/invariant/*" -vv

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
	echo "oracle first, then export WSGEM_ORACLE=<address>."; exit 1; }; \
	echo "using WSGEM_ORACLE=$${WSGEM_ORACLE} for instance $(INSTANCE)"
endef

# The inverse guard, for the ORACLE broadcast. WSGEM_ORACLE being set says an oracle already
# exists (step 1 done, step 2 underway or complete) -- and this target would broadcast a SECOND
# one, most likely because a .env prepared for the market steps was left in place. The scripts
# cannot catch this: WsgemOracleScript never reads the variable, and a duplicate oracle is a
# perfectly valid deployment. Broadcasting a deliberate replacement is done by blanking the
# variable on the command line, which is the one assignment that beats .env. The dry run stays
# exempt on purpose: simulating the oracle pipeline while one is live is useful and sends nothing.
define refuse_duplicate_oracle
	test -z "$${WSGEM_ORACLE}" || { \
	echo "WSGEM_ORACLE is set ($${WSGEM_ORACLE}): an oracle already exists, and this target would"; \
	echo "broadcast a SECOND one. If a replacement oracle is genuinely intended, blank the"; \
	echo "variable for this invocation:  make oracle-deploy WSGEM_ORACLE= INSTANCE=..."; exit 1; }
endef

# --- Which instance --------------------------------------------------------------------------
#
# Every deploy target below is parameterised by INSTANCE, which names the file in script/ and the
# two contracts inside it. The default is the first instance, so every invocation that predates
# this variable behaves exactly as it did.
#
#   make market-dry                          # wstGBP / tGBP
#   make market-dry INSTANCE=WstGBPCrvUSD    # wstGBP / crvUSD
#   make market-dry INSTANCE=WstGBPFrxUSD    # wstGBP / frxUSD
#
# Pass it as a COMMAND-LINE assignment to make, exactly as above -- not as an environment
# variable. This Makefile does `-include .env` and then `export`, which makes every value in .env a
# make file-variable, and file-variables beat environment ones. `INSTANCE=x make target` would work
# only by accident; `make target INSTANCE=x` always does.
#
# WSGEM_ORACLE is NOT per-instance, and that is a sharp edge: every wstGBP instance shares a wsgem,
# a gem, a pip and an upside speed, so an oracle from the wrong instance passes every wiring check
# the deploy script shares. What catches it is `_assertOracleExtra`, which each instance overrides
# with something true only of its own oracle. `require_oracle` echoes the pairing above so the
# mistake is visible before the run rather than after it.
INSTANCE ?= WstGBP

INSTANCE_SCRIPT = script/$(INSTANCE).s.sol
ORACLE_TARGET   = $(INSTANCE_SCRIPT):$(INSTANCE)OracleScript
MARKET_TARGET   = $(INSTANCE_SCRIPT):$(INSTANCE)MarketScript

define require_instance
	test -f "$(INSTANCE_SCRIPT)" || { \
	echo "no such instance: $(INSTANCE) (expected $(INSTANCE_SCRIPT))"; \
	echo "available:"; ls script/*.s.sol | grep -v WsgemLlamalendDeploy | grep -v WstGBPFx.s.sol; \
	exit 1; }
endef

# --- Oracle ------------------------------------------------------------------------------------
#
# The oracle shim is deployable on its own, ahead of the market, so its reported price can be
# watched against the live wsgem across at least one NAV poke before anything depends on it.

# The forge lines are @-silenced so make does not echo them into run logs, and ETH_RPC_URL is
# written $${ETH_RPC_URL} -- expanded by the shell at run time, not by make into the recipe text.
# Both defences matter separately: for most providers the URL embeds an API key, @ keeps it out
# of an ordinary run's log, and the shell-side expansion keeps it out of `make -n`, which prints
# recipes @-silenced or not. The other make-expanded identifiers (sender address, keystore path,
# gas numbers) are not secrets. `export` at the top of this file is what puts .env's values in
# the shell's environment for $${} to find.
#
# Every dry run and deploy below starts from `make clean`: forge script broadcasts whatever
# artifact sits in out/, and a stale one -- built from other source or other compiler settings --
# deploys silently. The clean ties the broadcast bytecode to the current tree, at the cost of a
# full rebuild. The dry runs pay it too, so a dry run rehearses exactly what the deploy will do.
oracle-dry  :
	@$(call require_rpc)
	@$(call require_instance)
	@make clean && make build && $(KEYLESS) forge script $(ORACLE_TARGET) \
		--rpc-url $${ETH_RPC_URL} -vvvv 2> >($(REDACT) >&2)

oracle-deploy :
	@$(call refuse_duplicate_oracle)
	@$(call require_deploy_env)
	@$(call require_instance)
	make clean && make build
	@forge script $(ORACLE_TARGET) \
		--rpc-url $${ETH_RPC_URL} --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
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
	@$(call require_instance)
	@$(call remind_oracle_reuse)
	@make clean && make build && $(KEYLESS) forge script $(MARKET_TARGET) \
		--rpc-url $${ETH_RPC_URL} -vvvv 2> >($(REDACT) >&2)

market-deploy :
	@$(call require_deploy_env)
	@$(call require_instance)
	@$(call require_oracle)
	make clean && make build
	@forge script $(MARKET_TARGET) \
		--rpc-url $${ETH_RPC_URL} --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --verify --slow --broadcast -vvvv 2> >($(REDACT) >&2)

# Resuming a partial market broadcast MUST go through this target, never a direct
# `forge script --resume`: forge replays the saved transaction backlog without re-executing the
# script, so the Solidity WSGEM_ORACLE guard cannot run on a resume. This target re-applies it
# here instead. No clean/build -- the backlog's transactions are already fixed; a rebuild cannot
# change what gets resumed.
market-resume :
	@$(call require_deploy_env)
	@$(call require_instance)
	@$(call require_oracle)
	@forge script $(MARKET_TARGET) \
		--rpc-url $${ETH_RPC_URL} --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --verify --slow --broadcast --resume -vvvv 2> >($(REDACT) >&2)

# --- Keeper ------------------------------------------------------------------------------------
#
# Both shims are permissionless and take no arguments. Nothing breaks without this -- both views
# compute from live state -- but a daily poke does two things: it records publications on a market
# with no traffic of its own, and it keeps the oracle's banked upside allowance at one day's worth
# (0.25%) instead of letting it reach MAX_ELAPSED's seven (1.75%). See docs/07-operations.md.
#
# WSGEM_CONTROLLER selects the MARKET to poke, and the two shims are derived from it. Run it from
# market creation, not from the DAO vote: the borrow_cap == 0 window is exactly when nothing else
# is driving price_w.
#
# WHY THE CONTROLLER AND NOT THE TWO SHIM ADDRESSES. Every wstGBP instance shares a wsgem, so a
# preflight that only checked "both shims agree on which wsgem" would pass an oracle from one
# market paired with a calculator from another: two green receipts, and the checkpoints the keeper
# exists to advance left untouched on both markets. The controller is the only address that knows
# which oracle and which calculator are actually wired into one market, so both are READ OUT of it
# rather than supplied -- there is nothing left to mispaste.
#
#   controller.amm().price_oracle_contract()          -> the oracle this market prices with
#   controller.monetary_policy().RATE_CALCULATOR()    -> the calculator this market rates with
#
# WSGEM_ORACLE and WSGEM_CALC remain honoured as ASSERTIONS: if either is set it must match what
# the market says, so a stale value left in `.env` fails loudly instead of being ignored.
#
# PREFLIGHT, and why it is not optional here. A call to an address with no code SUCCEEDS on the
# EVM -- it is indistinguishable from a function that returned nothing. So a keeper pointed at the
# wrong chain, or at an address that is right on mainnet and empty on a fork, sends two
# transactions, gets two green receipts, and updates neither checkpoint. A scheduled job would
# report success forever while the banked allowance this target exists to bound kept growing.
# The deploy targets get this from the script's own asserts; a bare `cast send` has none, so the
# checks are here: mainnet, the controller carries code, and both shims are the ones it names.
#
# The two sends are then status-checked INDIVIDUALLY, and the recipe fails if either did. A plain
# `a; b` would report the recipe's status as b's alone -- so a failed `price_w()` followed by a
# successful `rate_w()` would exit 0, which is the same false-green this preflight exists to
# prevent, arriving one step later. Both are still ATTEMPTED on a failure, because they are
# independent: a publication worth recording is worth recording even if the oracle poke did not
# land. What is not acceptable is a scheduled job that says it worked when half of it did not.
poke :
	@$(call require_send_env)
	@test -n "$${WSGEM_CONTROLLER}" || { \
	echo "WSGEM_CONTROLLER is required: the keeper pokes a MARKET, and the controller is the only"; \
	echo "address that knows which oracle and calculator belong to it. Take it from the instance"; \
	echo "sheet in docs/instances/, or from the market deploy's report block."; exit 1; }
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
	code_=$$($(KEYLESS) cast code $${WSGEM_CONTROLLER} --rpc-url $${ETH_RPC_URL} 2> >($(REDACT) >&2)) \
		|| { echo "preflight: cast code failed for WSGEM_CONTROLLER"; exit 1; }; \
	case "$$code_" in ""|"0x") echo "WSGEM_CONTROLLER has no code at $${WSGEM_CONTROLLER}"; exit 1;; esac; \
	amm_=$$($(KEYLESS) cast call $${WSGEM_CONTROLLER} 'amm()(address)' --rpc-url $${ETH_RPC_URL} 2> >($(REDACT) >&2)) \
		|| { echo "preflight: amm() reverted -- is WSGEM_CONTROLLER a Llamalend controller?"; exit 1; }; \
	mp_=$$($(KEYLESS) cast call $${WSGEM_CONTROLLER} 'monetary_policy()(address)' --rpc-url $${ETH_RPC_URL} 2> >($(REDACT) >&2)) \
		|| { echo "preflight: monetary_policy() reverted on the controller"; exit 1; }; \
	test -n "$$amm_" && test -n "$$mp_" \
		|| { echo "preflight: the controller returned nothing -- wrong contract?"; exit 1; }; \
	oracle_=$$($(KEYLESS) cast call $$amm_ 'price_oracle_contract()(address)' --rpc-url $${ETH_RPC_URL} 2> >($(REDACT) >&2)) \
		|| { echo "preflight: price_oracle_contract() reverted on the AMM"; exit 1; }; \
	calc_=$$($(KEYLESS) cast call $$mp_ 'RATE_CALCULATOR()(address)' --rpc-url $${ETH_RPC_URL} 2> >($(REDACT) >&2)) \
		|| { echo "preflight: RATE_CALCULATOR() reverted -- is this market on HyperbolicDynamicMP?"; exit 1; }; \
	test -n "$$oracle_" && test -n "$$calc_" \
		|| { echo "preflight: the market named nothing -- wrong contract?"; exit 1; }; \
	for pair_ in "oracle:$$oracle_" "calculator:$$calc_"; do \
		name_=$${pair_%%:*}; addr_=$${pair_#*:}; \
		c_=$$($(KEYLESS) cast code $$addr_ --rpc-url $${ETH_RPC_URL} 2> >($(REDACT) >&2)) \
			|| { echo "preflight: cast code failed for the $$name_"; exit 1; }; \
		case "$$c_" in ""|"0x") echo "the market's $$name_ has no code at $$addr_"; exit 1;; esac; \
	done; \
	if test -n "$${WSGEM_ORACLE}"; then \
		test "$$($(KEYLESS) cast to-check-sum-address $${WSGEM_ORACLE})" = "$$oracle_" \
			|| { echo "WSGEM_ORACLE=$${WSGEM_ORACLE} is not this market's oracle ($$oracle_)"; exit 1; }; \
	fi; \
	if test -n "$${WSGEM_CALC}"; then \
		test "$$($(KEYLESS) cast to-check-sum-address $${WSGEM_CALC})" = "$$calc_" \
			|| { echo "WSGEM_CALC=$${WSGEM_CALC} is not this market's calculator ($$calc_)"; exit 1; }; \
	fi; \
	echo "poking market $${WSGEM_CONTROLLER}: oracle $$oracle_, calculator $$calc_"; \
	rc_=0; \
	cast send $$oracle_ "price_w()" \
		--rpc-url $${ETH_RPC_URL} --from $${ETH_FROM} --keystore $${ETH_KEYSTORE} $(GAS_FLAGS) 2> >($(REDACT) >&2) \
		|| { echo "poke: price_w() FAILED on $$oracle_ -- the upside allowance was NOT reset"; rc_=1; }; \
	cast send $$calc_ "rate_w()" \
		--rpc-url $${ETH_RPC_URL} --from $${ETH_FROM} --keystore $${ETH_KEYSTORE} $(GAS_FLAGS) 2> >($(REDACT) >&2) \
		|| { echo "poke: rate_w() FAILED on $$calc_ -- a publication may go unobserved"; rc_=1; }; \
	test $$rc_ -eq 0 \
		|| { echo "poke: at least one call failed; see above. This run did NOT do its job."; exit 1; }

.PHONY: all deps build clean sizes fmt test test-fork test-intense coverage gen-report serve-report \
	oracle-dry oracle-deploy market-dry market-deploy market-resume poke
