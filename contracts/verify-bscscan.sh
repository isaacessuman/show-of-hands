#!/usr/bin/env bash
# Verify the Show of Hands contracts on BscScan (the hackathon requires BscScan verification).
# Needs a free Etherscan API key (one key works for BscScan through Etherscan API v2):
#   1. Sign in at https://etherscan.io/myapikey and create a key.
#   2. Run:  ETHERSCAN_API_KEY=<your key> ./verify-bscscan.sh
# The key is only passed to forge for this run. It is not saved anywhere.
set -uo pipefail
cd "$(dirname "$0")"
: "${ETHERSCAN_API_KEY:?Set ETHERSCAN_API_KEY first (see the comment at the top of this file).}"

AGENT_ID=0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
ERC8004_IDENTITY=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
ERC8004_REPUTATION=0x8004BAa17C55a88189AE136b182e5fdA19dE9b63
POLLS=0x0EB39713C32f9Cf6f9120818E14a101D35aa2aC4
ROUNDS=0x3510B0Cd977a1bc759f674Ef6b5B6Ac769701D7B
ATTESTOR=0x3f2e6f06856421054906c335586c129c1D2EC09F
CROWDSCORE=0x1a912bc6d6fA8E3a3E9Eb28ff31B6bF1610Ecff3
PREDICTIONS=0x77a23A374729B6482Bc7034cFFC3c78f96869c8a

RESULTS=()
v() {
  echo; echo "=== $2 at $1"
  if forge verify-contract "$1" "$2" --chain 56 --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" \
       --constructor-args "$3" --watch; then RESULTS+=("OK      $2"); else RESULTS+=("FAILED  $2 (see the error above)"); fi
}

v "$POLLS"    src/Polls.sol:Polls                 "$(cast abi-encode 'c(address)' $AGENT_ID)"
v "$ROUNDS"   src/FundingRounds.sol:FundingRounds "$(cast abi-encode 'c(address)' $AGENT_ID)"
v "$ATTESTOR" src/Attestor.sol:Attestor           "$(cast abi-encode 'c(address,address,address)' $ROUNDS $ERC8004_IDENTITY $ERC8004_REPUTATION)"
if [ "$(cast code $CROWDSCORE --rpc-url https://bsc-dataseed.bnbchain.org 2>/dev/null)" != "0x" ]; then
  v "$CROWDSCORE" src/CrowdScore.sol:CrowdScore "$(cast abi-encode 'c(address,address,address)' $POLLS $ERC8004_IDENTITY $ERC8004_REPUTATION)"
else RESULTS+=("SKIPPED CrowdScore (not deployed yet)"); fi
if [ "$(cast code $PREDICTIONS --rpc-url https://bsc-dataseed.bnbchain.org 2>/dev/null)" != "0x" ]; then
  v "$PREDICTIONS" src/Predictions.sol:Predictions "$(cast abi-encode 'c(address,address[3],address,address,address)' $AGENT_ID '[0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE,0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf,0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e]' $CROWDSCORE $ERC8004_IDENTITY $ERC8004_REPUTATION)"
else RESULTS+=("SKIPPED Predictions (not deployed yet)"); fi
echo; echo "=== Summary"; printf '%s\n' "${RESULTS[@]}"
echo "Check: https://bscscan.com/address/$POLLS#code  https://bscscan.com/address/$ROUNDS#code  https://bscscan.com/address/$ATTESTOR#code  https://bscscan.com/address/$CROWDSCORE#code  https://bscscan.com/address/$PREDICTIONS#code"
