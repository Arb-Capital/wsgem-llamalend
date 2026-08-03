#!/usr/bin/env bash
#
# Fork tests against live mainnet state.
#
# Hard-fails without a mainnet RPC. This is deliberate: a "skip if no RPC" branch turns a missing
# RPC into a green CI run, which is exactly how a broken deploy script reaches production.
set -e

[[ "$(cast chain --rpc-url="$ETH_RPC_URL")" == "ethlive" ]] || {
    echo "ETH_RPC_URL must point at Ethereum mainnet (got: $(cast chain --rpc-url="$ETH_RPC_URL" 2>/dev/null || echo unreachable))"
    exit 1
}

# Pin the fork block so the RPC cache is reusable and results are reproducible. Must stay at or
# after 25670242: the live-instance suite reads the deployed oracle, which has no code before it.
export ETH_FORK_BLOCK="${ETH_FORK_BLOCK:-25670300}"

echo "Forking mainnet at block ${ETH_FORK_BLOCK}"

forge test --match-path "test/fork/*" -vvv "$@"
