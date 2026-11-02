.PHONY: install build test journey gas coverage params params-write fmt lint anvil deploy-local clean

install:
	forge install

build:
	forge build

test:
	forge test

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

anvil:
	anvil --port 8546

# Requires `make anvil` in another terminal.
deploy-local:
	forge script script/DeployLocal.s.sol:DeployLocal \
		--rpc-url http://127.0.0.1:8546 --broadcast

deploy-amoy:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url amoy --broadcast --verify --slow

clean:
	forge clean
