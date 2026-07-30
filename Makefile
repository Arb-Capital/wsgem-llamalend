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

coverage    :; forge coverage --no-match-path "test/fork/*"

# Keyless forge-script invocations (dry runs) must strip every wallet-resolving env var a previous
# deploy session may have left exported. forge binds ETH_FROM/--sender, ETH_KEYSTORE/--keystore,
# ETH_KEYSTORE_ACCOUNT/--account and ETH_PASSWORD/--password, and couples them in argument
# parsing, so a stray one turns a keyless simulation into a keystore prompt or a parse failure.
KEYLESS := env -u ETH_FROM -u ETH_KEYSTORE -u ETH_KEYSTORE_ACCOUNT -u ETH_PASSWORD

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

# --- Oracle ------------------------------------------------------------------------------------
#
# The oracle shim is deployable on its own, ahead of the market, so its reported price can be
# watched against the live wsgem across at least one NAV poke before anything depends on it.

oracle-dry  :; make build && $(KEYLESS) forge script script/WstGBP.s.sol:WstGBPOracleScript \
	--rpc-url ${ETH_RPC_URL} -vvvv

oracle-deploy :
	@$(call require_deploy_env)
	make build
	forge script script/WstGBP.s.sol:WstGBPOracleScript \
		--rpc-url $(ETH_RPC_URL) --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --verify --slow --broadcast -vvvv

# --- Market ------------------------------------------------------------------------------------
#
# Deploys the rate calculator, the monetary policy (from vendored initcode) and then calls
# LendFactory.create. Market creation is permissionless, but the market ships with a zero borrow
# cap -- see docs/06-post-deployment.md.
#
# WSGEM_ORACLE selects an already-deployed oracle shim; unset means the script deploys a fresh
# one in the same run.

market-dry  :; make build && $(KEYLESS) forge script script/WstGBP.s.sol:WstGBPMarketScript \
	--rpc-url ${ETH_RPC_URL} -vvvv

market-deploy :
	@$(call require_deploy_env)
	make build
	forge script script/WstGBP.s.sol:WstGBPMarketScript \
		--rpc-url $(ETH_RPC_URL) --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --verify --slow --broadcast -vvvv

.PHONY: all deps build clean sizes fmt test test-fork coverage \
	oracle-dry oracle-deploy market-dry market-deploy
