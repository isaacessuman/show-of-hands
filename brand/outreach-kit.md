# Outreach kit (plan steps Nov 21–30)

Everything here is posted or sent **by you**, by hand. Change a few words each time: never paste the same text twice (X treats that as spam).
Rules in every message: no rewards, no airdrop, nothing promised to voters or backers, never show someone's wallet next to their name.

Links you'll use:
- Today's question: https://showofhands.io/p/1
- Funding Round 1 (after it's opened): https://showofhands.io/#/round/0, where builders apply in 30 seconds with the "List your project" box
- Safety facts: https://showofhands.io/#/rules

---

## 1. Replies under other builders' posts (Sat Nov 21 – Sun Nov 22)

Pick 10–15. These are token-free, open-code entries that overlap our idea, so their followers already care about voting or safety. Reply under their latest hackathon post.

| Builder | Why them | Reply (adapt) |
|---|---|---|
| Agent Senate (@realmasrur) | proposals + agent reasoning on-chain, no owner | "Agent reasoning on-chain before a vote is the right idea. We did the crowd side: one Agent ID = one vote, polls + quadratic funding. Want a slot in our Round 1 (Dec 1)? No token needed. showofhands.io/#/round/0" |
| Agent Voice (@0xShinju_0) | polls with copy-paste agent prompts | "Same instinct here: copy-paste prompt, agent previews, human says yes. Ours adds a verdict API agents can read. Happy to list you in Round 1 so our voters can back you." |
| AgentShield (@yingxiang15) | 1 .ai = 1 vote safety votes | "Crowd safety votes ftw. We run Crowd Check too (showofhands.io/#/check). Let's not split the crowd: want to be listed in our Round 1 so holders can back your work directly?" |
| agentid.im Red Packets (@agentid_im) | one share per Agent ID, no owner | "One share per Agent ID, no owner: same design rule as ours. Our Round 1 matches by *how many* different Agent IDs back you. You'd fit. showofhands.io/#/round/0" |
| AgentPoll (irawanjong-commits, RIPAYYYYY on GitHub) | open-source poll contracts | "Nice clean contract. If you want real voters on it, list it in our Round 1. Each different Agent ID that backs you raises your match." |
| AgentWorks (@0xPacific) | escrow + reputation by .ai | "Reputation by .ai is the right anchor. Our CrowdScore writes one live ERC-8004 score per person. Could plug into your job board. Also: Round 1 slot is yours if you want it." |
| AgentMark | badges, chasing 30 Agent IDs | "We're both chasing the 30. Want to swap? List in our Round 1, and we'll point our voters at your badge." *(only if they have no token)* |
| AgentTrust (@jettyleex) | 1 KYC = 1 vote reviews | "1 KYC = 1 vote reviews + our quadratic funding = the crowd both rates and funds. Round 1 slot open." |
| Signal Garden (@zidanpratama027) | proposal board | "Proposal board → our round could fund the winning proposals. Want in?" |
| MintGuard / SkillShield | safety tools | "Free safety tools are exactly what Round 1 is for. Apply here: showofhands.io/#/round/0" |

Skip anything with a token sale, presale, points-for-rewards or betting (Agent Cards, IdeaFun, Pools, JUJIX's token tier, the launchpads).

---

## 2. DMs to 5 Chinese analysts (Mon Nov 23, 08:00–10:00 UTC)

Targets: 泵泵超人 Pumpman (@crypto_pumpman), 子时 (@silverfang88), Ed_x (@Ed_x0101), 就叫19 (@nineteen_888), Kithe (@kuk47377341).

**中文 (adapt the first line to each person):**
> 你好！看到你在聊 Agent ID 黑客松，想请你看一个小项目：举手 Show of Hands（showofhands.io）。
> 一个币安 Agent ID = 一票，机器人和批量钱包刷不了票；还有二次方资助轮，按“多少个不同的人”支持来配捐，而不是按钱多少。合约无 owner、无手续费、已在 BscScan 验证，没有代币。
> 想邀请你用自己的 .ai 名字发起一个投票，问一个你粉丝本来就在争论的问题。我们帮你把题目和选项准备好，你粉丝 30 秒就能投。没有任何报酬或承诺，纯粹是给你的社区一个“真人投票”的工具。
> 感兴趣的话我把一页说明发给你。

**English (if they reply in English):**
> Hi! Saw you covering the Agent ID hackathon. Show of Hands (showofhands.io): one Binance Agent ID = one vote, so bots and wallet farms can't stuff it, plus quadratic funding that matches by how many different people back a builder. No owner, no fee, no token, verified on BscScan. Would you run one poll under your own .ai name, on something your followers already argue about? We'll prep the question, they vote in 30 seconds. No payment, nothing promised; it's just a real-people poll for your community.

---

## 3. 聪哥 Agent ID Call Telegram (Tue Nov 24): their checklist, filled in

Send to t.me/agentidcall:

> **举手 Show of Hands: 按你们的清单自查**
> 1. **源码是否验证？** 是。全部合约在 BscScan 和 Sourcify 验证（完全匹配）：
>    - Polls 0x0EB39713C32f9Cf6f9120818E14a101D35aa2aC4
>    - FundingRounds 0x3510B0Cd977a1bc759f674Ef6b5B6Ac769701D7B
>    - Attestor 0x3f2e6f06856421054906c335586c129c1D2EC09F
>    - CrowdScore v2 0xA43Fa81D92c9229A9883379f943Ad6E170a9003E
>    - Predictions v2 0x27299aBe7c2226b95CCA017ee0A2210F2f8D5C92
> 2. **Owner 能做什么？** 什么都不能。没有 owner、没有管理员、没有升级、没有手续费、没有任何把钱转去别处的函数。资助轮的“管理人”只能在结算前批准/下架项目或取消本轮；下架或取消都会把钱退还给支持者。管理人永远拿不到支持者的钱。
> 3. **BNB 去哪里？** 投票、预测、声誉：不收任何 BNB，只有 gas（约 $0.003）。资助轮：支持的 BNB 存在合约里，结算后只能由项目自己的钱包领取；配捐池按公式分配，没用完的退回出资人。
> 4. **能退款吗？** 能。项目被下架或本轮取消时，支持者调用 refund() 取回；出资人调用 withdrawPool() 取回未用部分。
> 5. **有代币/授权吗？** 没有代币、没有铸造、不需要 approve，只用原生 BNB。
> 代码：github.com/isaacessuman/show-of-hands · 规则页：showofhands.io/#/rules

---

## 4. Boltbook project wiki page (Tue Nov 24)

> **Show of Hands (举手)**: one Agent ID, one voice.
> Free polls, Chainlink-settled price questions and quadratic funding rounds on BNB Chain, where each Binance Agent ID counts exactly once.
> - Agents: read the crowd with `GET https://showofhands.io/api/verdict?poll=latest` (no key). Act only when `decided` is true.
> - Skill: https://showofhands.io/skill.md (always previews, waits for the human's yes).
> - Contracts: no owner, no fee, no token, verified. Addresses at showofhands.io/llms.txt.
> - Round 1 (Dec 1–4): token-free builders can apply at showofhands.io/#/round/0.

---

## 5. Round 1 announcement (post the day the round is opened)

**EN**
> Funding Round 1 is open for applications. 🤲
>
> Builders and creators who serve Agent ID holders and have no token to sell: list your project in 30 seconds.
>
> Backing runs Dec 1–4. A 0.1 BNB pool is split by how many *different* Agent IDs back you, not by how much anyone pays. 100 wallets = 1 backer.
>
> showofhands.io/#/round/0

**中文**
> 第一轮资助开放申请 🤲
>
> 为 Agent ID 持有者做事、没有代币要卖的开发者和创作者：30 秒就能申请。
>
> 12 月 1–4 日开放支持。0.1 BNB 配捐池按“多少个不同的 Agent ID 支持你”分配，而不是谁出钱多。100 个钱包 = 1 个支持者。
>
> showofhands.io/#/round/0
