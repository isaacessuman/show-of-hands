#!/usr/bin/env bash
# Verify the three Show of Hands contracts on BscScan (the hackathon requires BscScan verification).
# Needs a free Etherscan API key (one key works for BscScan through Etherscan API v2):
#   1. Sign in at https://etherscan.io/myapikey and create a key.
#   2. Run:  ETHERSCAN_API_KEY=<your key> ./verify-bscscan.sh
# The key is only passed to forge for this run. It is not saved anywhere.
set -euo pipefail
cd "$(dirname "$0")"
: "${ETHERSCAN_API_KEY:?Set ETHERSCAN_API_KEY first (see the comment at the top of this file).}"

AGENT_ID=0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
ERC8004_IDENTITY=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
ERC8004_REPUTATION=0x8004BAa17C55a88189AE136b182e5fdA19dE9b63
POLLS=0x0EB39713C32f9Cf6f9120818E14a101D35aa2aC4
ROUNDS=0x3510B0Cd977a1bc759f674Ef6b5B6Ac769701D7B
ATTESTOR=0x3f2e6f06856421054906c335586c129c1D2EC09F

v() { forge verify-contract "$1" "$2" --chain 56 --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" \
        --constructor-args "$3" --watch; }

v "$POLLS"    src/Polls.sol:Polls                 "$(cast abi-encode 'c(address)' $AGENT_ID)"
v "$ROUNDS"   src/FundingRounds.sol:FundingRounds "$(cast abi-encode 'c(address)' $AGENT_ID)"
v "$ATTESTOR" src/Attestor.sol:Attestor           "$(cast abi-encode 'c(address,address,address)' $ROUNDS $ERC8004_IDENTITY $ERC8004_REPUTATION)"
echo "Done. Check https://bscscan.com/address/$POLLS#code"
