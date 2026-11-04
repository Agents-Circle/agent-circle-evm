.PHONY: install build test invariant verify-deploy journey gas coverage params params-write fmt lint anvil deploy-local hl-deploy-local deploy-amoy deploy-hl-testnet clean

install:
	forge install

build:
	forge build

test:
	forge test

# The invariant suites at CI depth (256 runs x 500 calls). `make test` runs them shallow.
invariant:
	FOUNDRY_PROFILE=ci forge test --match-path "test/**/*.invariant.t.sol"

# Read a deployed HyperEVM stack back and check it. Sends nothing. Needs REGISTRY,
# WHITELIST, FACTORY, GOVERNANCE, GUARDIAN, TREASURY, PLATFORM_BUILDER and RPC_URL.
verify-deploy:
	forge script script/hyperliquid/VerifyDeploy.s.sol --rpc-url $(RPC_URL)

# The whole product as a printed walkthrough. Start here.
journey:
	forge test --match-contract Journey -vv

gas:
	forge snapshot --check || forge snapshot

coverage:
	# --ir-minimum because coverage disables the optimizer, and the generated getter for
	# the twelve-field Vault struct goes stack-too-deep without it.
	forge coverage --ir-minimum --no-match-coverage "(test|script)"

# Fails if the locked parameters have drifted between the JSON, Solidity, Anchor and
# the docs. Reads the Anchor constants and the docs page from sibling checkouts when
# they are there, and from raw GitHub otherwise.
params:
	python3 script/check-params.py

# Regenerates the docs parameter table from parameters.json. Needs mintlify-docs beside
# this repo.
params-write:
	python3 script/check-params.py --write

fmt:
	forge fmt

lint:
	forge fmt --check && forge build

# --chain-id 999 because HLConstants resolves USDC and the Core deposit wallet from
# block.chainid. On anvil's default 31337 both point at nothing and the deposit path
# reverts somewhere that looks unrelated.
anvil:
	anvil --port 8546 --chain-id 999

# Requires `make anvil` in another terminal.
deploy-local:
	forge script script/DeployLocal.s.sol:DeployLocal \
		--rpc-url http://127.0.0.1:8546 --broadcast

# The HyperEVM journey against a live local node. Installs the HyperCore mocks first,
# because the precompiles and the CoreWriter are chain features rather than contracts the
# script can deploy. Requires `make anvil` in another terminal.
hl-deploy-local:
	./script/hyperliquid/install-local-core.sh
	forge script script/hyperliquid/DeployLocal.s.sol:DeployLocalHyperliquid \
		--rpc-url http://127.0.0.1:8546 --broadcast

deploy-amoy:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url amoy --broadcast --verify --slow

# HyperEVM testnet (chain 998). Needs GOVERNANCE, GUARDIAN, TREASURY,
# PLATFORM_BUILDER and HYPEREVM_TESTNET_RPC_URL in the environment, and a funded
# deployer key passed the way you prefer (--private-key, --keystore, --ledger).
#
# No --verify: there is no [etherscan] entry for HyperEVM, so asking to verify
# fails the run after the contracts are already deployed.
#
# --slow because a large deploy wants HyperEVM big blocks (1 min, 30M gas) rather
# than small blocks (1 s, 3M gas); a revert on gas is usually that.
deploy-hl-testnet:
	forge script script/hyperliquid/Deploy.s.sol:DeployHyperliquid \
		--rpc-url hyperevm_testnet --broadcast --slow

clean:
	forge clean
