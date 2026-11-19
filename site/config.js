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
  gas: { vote: 250000, createPoll: 900000, applyProject: 450000, back: 300000, claim: 150000, refund: 120000, finalise: 3000000 },
};
