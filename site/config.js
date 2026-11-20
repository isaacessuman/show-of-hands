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
  // Writes "how often you voted with the crowd" into the ERC-8004 Reputation Registry as ONE live lifetime score
  // per person (v2). Same deterministic deployer as the others. v1 kept for history.
  crowdScore: "0xA43Fa81D92c9229A9883379f943Ad6E170a9003E",
  crowdScoreV1: "0x1a912bc6d6fA8E3a3E9Eb28ff31B6bF1610Ecff3",
  erc8004Identity: "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432",
  // Price questions settled on-chain from Chainlink (BNB/BTC/ETH in USD). v2 can always be settled (or voided after
  // 30 days); all new questions go there. v1 is read-only history. Same deterministic deployer.
  predictions: "0x27299aBe7c2226b95CCA017ee0A2210F2f8D5C92",
  predictionsV1: "0x77a23A374729B6482Bc7034cFFC3c78f96869c8a",
  // The project's own Agent ID (showofhands). Its polls are the daily "Question of the Day".
  official: "0x5cDA0229C5D11c2a1Ac5Ce0EfD07CABAea061Dc9",
  gas: { vote: 250000, createPoll: 1300000, applyProject: 450000, back: 300000, claim: 150000, refund: 120000, finalise: 3000000, link: 700000, attest: 900000, predCreate: 300000, predVote: 250000, settle: 300000, pattest: 900000, void: 100000 },
};
