// Contract addresses are fixed here and nowhere else. The site never accepts addresses from the URL,
// so a shared link cannot point people at a different contract.
export const CONFIG = {
  chainId: 56,
  rpc: "https://bsc-dataseed.bnbchain.org",
  explorer: "https://bscscan.com",
  agentId: "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F",
  polls: "0x0EB39713C32f9Cf6f9120818E14a101D35aa2aC4",
  fundingRounds: "0x3510B0Cd977a1bc759f674Ef6b5B6Ac769701D7B",
  attestor: "0x3f2e6f06856421054906c335586c129c1D2EC09F",
  // Writes "how often you voted with the crowd" into the ERC-8004 Reputation Registry. Same deterministic deployer as the others.
  crowdScore: "0x1a912bc6d6fA8E3a3E9Eb28ff31B6bF1610Ecff3",
  erc8004Identity: "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432",
  // Price questions settled on-chain from Chainlink (BNB/BTC/ETH in USD). Same deterministic deployer.
  predictions: "0x77a23A374729B6482Bc7034cFFC3c78f96869c8a",
  // The project's own Agent ID (showofhands). Its polls are the daily "Question of the Day".
  official: "0x5cDA0229C5D11c2a1Ac5Ce0EfD07CABAea061Dc9",
  gas: { vote: 250000, createPoll: 900000, applyProject: 450000, back: 300000, claim: 150000, refund: 120000, finalise: 3000000, link: 200000, attest: 600000, predCreate: 300000, predVote: 200000, settle: 150000 },
};
