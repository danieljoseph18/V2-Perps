CHAIN_ID := 84532
OPTIMIZER_RUNS := 200
COMPILER_VERSION := 0.8.23

# Default values
SCRIPT_PATH :=
NETWORK :=

# Script settings
ACCOUNT := testKey
SENDER := 0x02A2012c36644f4e4b36A14EBe13E23c96f4C5b6

# Load environment variables from .env file
include .env

# Set RPC URL based on the network
ifeq ($(NETWORK),testnet)
	RPC_URL := ${BASE_SEPOLIA_RPC_URL}
    ACCOUNT := testKey
    SENDER := 0x02A2012c36644f4e4b36A14EBe13E23c96f4C5b6
else ifeq ($(NETWORK),mainnet)
	RPC_URL := ${BASE_RPC_URL}
    ACCOUNT := print3rKey
    SENDER := 0x4F6e437f7E90087f7090AcfE967D77ba0B4c7444
else
	$(error Invalid network. Please specify 'testnet' or 'mainnet'.)
endif

verify:
	@forge verify-contract --chain-id ${CHAIN_ID} --num-of-optimizations ${OPTIMIZER_RUNS} --watch

clean:
	@forge clean

build:
	@forge build --optimize --optimizer-runs ${OPTIMIZER_RUNS} --compiler-version ${COMPILER_VERSION}

test:
	@forge test --optimize --optimizer-runs ${OPTIMIZER_RUNS} --compiler-version ${COMPILER_VERSION}

script:
	@forge script ${SCRIPT_PATH} --rpc-url ${RPC_URL} --account ${ACCOUNT} --sender ${SENDER} --broadcast

.PHONY: verify clean build test script