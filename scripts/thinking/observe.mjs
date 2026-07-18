// Zoo DAO — Thinking Chain Observatory, headless CLI reader.
// Same on-chain visibility as observatory.html, but for the terminal / CI:
// one read of every thinking-governance surface (thoughts, validator verdicts,
// value-deciding parameter rounds, Bitcoin-shaped AI economics) with no browser.
//
//   node observe.mjs                      # live Lux testnet (chainId 96368) defaults
//   RPC=… OBSERVATORY=0x… node observe.mjs
//   node observe.mjs --rpc <url> --observatory 0x… --parameters 0x… --reputation 0x…
//
// Reads are pure view calls — no key, no gas, no mutation.
import { createPublicClient, http, formatEther } from './viem.min.mjs';

// ---- config: CLI flags > env > live-testnet defaults -----------------------
const argv = process.argv.slice(2);
const flag = (name, env, def) => {
  const i = argv.indexOf(`--${name}`);
  if (i >= 0 && argv[i + 1]) return argv[i + 1];
  return process.env[env] || def;
};
// Live thinking-governance stack on the Lux testnet (deployments/thinking-96368.json).
// normalize addresses to lowercase so a non-EIP-55-checksummed input (e.g. a
// hand-derived CREATE address) is accepted rather than rejected by viem.
const addr = (s) => (s && /^0x[0-9a-fA-F]{40}$/.test(s) ? s.toLowerCase() : s);
const RPC = flag('rpc', 'RPC', 'https://api.lux-test.network/ext/bc/C/rpc');
const OBS = addr(flag('observatory', 'OBSERVATORY', '0xa1a2cE4377fee42b09Da6376d4887156FeE54c8b'));
const PARAMS = addr(flag('parameters', 'PARAMETERS', '0xDd30113b484671A35Ca236ec5A97C1c5327d72FA'));
const REP = addr(flag('reputation', 'REPUTATION', '0x7803f099cdA82732e98C9f82815e7Acf18CA02C8'));
// AI-mining layer (AICoinMiner): pass --miner 0x… to surface attestation-mining activity
// (verified A-Chain work -> AICoin) alongside governance. No default — it's per-chain.
const MINER = addr(flag('miner', 'MINER', ''));

// ---- ABI (identical shapes to observatory.mjs — one source of truth in spirit)
const tup = (...c) => ({ type: 'tuple', components: c });
const u = (n) => ({ type: n });
const STATUS = ['None', 'Open', 'Settled', 'Failed'];
const VOTE = ['Invalid', 'YES', 'NO', 'Abstain'];

const OVERVIEW = tup(
  { name: 'taskCount', type: 'uint256' }, { name: 'openCount', type: 'uint256' }, { name: 'settledCount', type: 'uint256' },
  { name: 'failedCount', type: 'uint256' }, { name: 'thoughtReceipts', type: 'uint256' }, { name: 'minBond', type: 'uint256' },
  { name: 'openFee', type: 'uint256' }, { name: 'treasury', type: 'address' });
const ECONOMICS = tup(
  { name: 'coin', type: 'address' }, { name: 'hardCap', type: 'uint256' }, { name: 'epoch', type: 'uint256' },
  { name: 'epochSubsidy', type: 'uint256' }, { name: 'unlocked', type: 'uint256' }, { name: 'minted', type: 'uint256' },
  { name: 'burned', type: 'uint256' }, { name: 'circulating', type: 'uint256' }, { name: 'remaining', type: 'uint256' });
const THOUGHT = tup(
  { name: 'taskId', type: 'uint256' }, { name: 'modelSpecHash', type: 'bytes32' }, { name: 'promptHash', type: 'bytes32' },
  { name: 'knobKey', type: 'string' }, { name: 'status', type: 'uint8' }, { name: 'canonicalVote', type: 'uint8' },
  { name: 'canonicalBucket', type: 'uint16' }, { name: 'n', type: 'uint8' }, { name: 'threshold', type: 'uint8' },
  { name: 'submissionCount', type: 'uint8' }, { name: 'agreeCount', type: 'uint8' }, { name: 'openedAt', type: 'uint64' }, { name: 'deadline', type: 'uint64' });
const VERDICT = tup(
  { name: 'operator', type: 'address' }, { name: 'vote', type: 'uint8' }, { name: 'confidenceBucket', type: 'uint16' },
  { name: 'evidenceHash', type: 'bytes32' }, { name: 'submittedAt', type: 'uint64' });
const ROUND = tup(
  { name: 'modelSpecHash', type: 'bytes32' }, { name: 'promptHash', type: 'bytes32' }, { name: 'knobKey', type: 'string' },
  { name: 'lo', type: 'uint256' }, { name: 'hi', type: 'uint256' }, { name: 'n', type: 'uint8' }, { name: 'threshold', type: 'uint8' },
  { name: 'openedAt', type: 'uint64' }, { name: 'deadline', type: 'uint64' }, { name: 'opener', type: 'address' },
  { name: 'status', type: 'uint8' }, { name: 'submissionCount', type: 'uint8' }, { name: 'canonicalValue', type: 'uint256' });
const PROPOSAL = tup(
  { name: 'operator', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'confidenceBucket', type: 'uint16' },
  { name: 'evidenceHash', type: 'bytes32' }, { name: 'submittedAt', type: 'uint64' });

const OBS_ABI = [
  { type: 'function', name: 'overview', stateMutability: 'view', inputs: [], outputs: [OVERVIEW] },
  { type: 'function', name: 'economics', stateMutability: 'view', inputs: [], outputs: [ECONOMICS] },
  { type: 'function', name: 'recentThoughts', stateMutability: 'view', inputs: [u('uint256')], outputs: [{ type: 'tuple[]', components: THOUGHT.components }] },
  { type: 'function', name: 'governor', stateMutability: 'view', inputs: [], outputs: [u('address')] },
];
const GOV_ABI = [{ type: 'function', name: 'getVerdicts', stateMutability: 'view', inputs: [u('uint256')], outputs: [{ type: 'tuple[]', components: VERDICT.components }] }];
const REP_ABI = [{ type: 'function', name: 'weightOf', stateMutability: 'view', inputs: [u('address')], outputs: [u('uint32')] }];
const PARAMS_ABI = [
  { type: 'function', name: 'roundCount', stateMutability: 'view', inputs: [], outputs: [u('uint256')] },
  { type: 'function', name: 'getRound', stateMutability: 'view', inputs: [u('uint256')], outputs: [ROUND] },
  { type: 'function', name: 'getProposals', stateMutability: 'view', inputs: [u('uint256')], outputs: [{ type: 'tuple[]', components: PROPOSAL.components }] },
];
// AI mining: the AICoinMiner turns a verified A-Chain inference receipt into a subsidy mint.
const MINER_ABI = [
  { type: 'function', name: 'coin', stateMutability: 'view', inputs: [], outputs: [u('address')] },
  { type: 'function', name: 'rewardPerReceipt', stateMutability: 'view', inputs: [], outputs: [u('uint256')] },
];
const MINER_COIN_ABI = [
  { type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [u('uint256')] },
  { type: 'function', name: 'mintedSubsidy', stateMutability: 'view', inputs: [], outputs: [u('uint256')] },
  { type: 'function', name: 'cumulativeAllowance', stateMutability: 'view', inputs: [], outputs: [u('uint256')] },
  { type: 'function', name: 'emissionAllowance', stateMutability: 'view', inputs: [], outputs: [u('uint256')] },
];
const MINED_EVENT = {
  type: 'event', name: 'Mined', inputs: [
    { name: 'intentID', type: 'bytes32', indexed: true },
    { name: 'requester', type: 'address', indexed: true },
    { name: 'amount', type: 'uint256', indexed: false },
    { name: 'root', type: 'bytes32', indexed: true },
  ],
};

const ai = (w) => Math.round(Number(formatEther(w))).toLocaleString();
const short = (h) => h.slice(0, 10) + '…';

const client = createPublicClient({ transport: http(RPC) });
const read = (fn, args = []) => client.readContract({ address: OBS, abi: OBS_ABI, functionName: fn, args });

async function main() {
  const chainId = await client.getChainId();
  console.log(`\n🐋 Beluga L3 · Thinking Chain Observatory  (headless read)`);
  console.log(`   rpc=${RPC}  chainId=${chainId}  observatory=${short(OBS)}\n`);

  try {
  const [ov, eco, thoughts] = await Promise.all([read('overview'), read('economics'), read('recentThoughts', [10n])]);

  console.log(`── Governance ───────────────────────────────`);
  console.log(`   thoughts ${ov.taskCount}   open ${ov.openCount}   settled ${ov.settledCount}   failed ${ov.failedCount}   PoT receipts ${ov.thoughtReceipts}`);
  console.log(`   minBond ${formatEther(ov.minBond)}   openFee ${formatEther(ov.openFee)}   treasury ${short(ov.treasury)}`);

  console.log(`\n── AI economics (Bitcoin-shaped: 1B cap, halving, burn) ──`);
  if (eco.coin === '0x0000000000000000000000000000000000000000') {
    console.log(`   (no AI coin pinned on this chain)`);
  } else {
    const pct = eco.hardCap > 0n ? (Number(eco.unlocked * 10000n / eco.hardCap) / 100).toFixed(4) : '0';
    console.log(`   coin ${short(eco.coin)}  epoch ${eco.epoch}`);
    console.log(`   mined ${ai(eco.minted)} AI   burned ${ai(eco.burned)} AI   circulating ${ai(eco.circulating)} AI`);
    console.log(`   ${pct}% of ${ai(eco.hardCap)} AI cap unlocked   remaining subsidy ${ai(eco.remaining)} AI`);
  }

  console.log(`\n── Recent thoughts (binary policy votes) ─────`);
  if (!thoughts.length) {
    console.log(`   none yet — open one with decide.sh (binary) / the live chain has had no rounds`);
  } else {
    for (const t of thoughts) {
      const decided = t.status === 2 ? `${VOTE[t.canonicalVote]} @ ${Number(t.canonicalBucket) / 100}%` : '—';
      console.log(`   #${t.taskId} ${t.knobKey}  [${STATUS[t.status]}]  decided=${decided}  agree ${t.agreeCount}/${t.n} (≥${t.threshold})`);
    }
    // thinking validators' own signed verdicts on the latest thought
    const gov = await read('governor');
    const latest = thoughts[0];
    const vs = await client.readContract({ address: gov, abi: GOV_ABI, functionName: 'getVerdicts', args: [latest.taskId] });
    console.log(`\n   Thinking validators on thought #${latest.taskId} (${latest.knobKey}) — governor ${short(gov)}:`);
    if (!vs.length) console.log(`     (no verdicts submitted yet)`);
    for (let i = 0; i < vs.length; i++) {
      const v = vs[i];
      let rep = '';
      try {
        const w = await client.readContract({ address: REP, abi: REP_ABI, functionName: 'weightOf', args: [v.operator] });
        rep = `  reputation ${Number(w) / 100}%`;
      } catch { /* reputation optional */ }
      console.log(`     validator ${i + 1} ${short(v.operator)}  ${VOTE[v.vote]} @ ${Number(v.confidenceBucket) / 100}% confidence${rep}`);
    }
  }
  } catch (e) {
    console.log(`── Governance ───────────────────────────────`);
    console.log(`   no thinking-governance Observatory on this chain (mining-only): ${e.shortMessage || 'unreadable'}`);
  }

  console.log(`\n── Value-deciding rounds (LLMs propose; chain settles the median) ──`);
  try {
    const rc = await client.readContract({ address: PARAMS, abi: PARAMS_ABI, functionName: 'roundCount' });
    if (rc === 0n) {
      console.log(`   none yet — open one with decide-value.sh`);
    } else {
      const rid = rc - 1n;
      const rd = await client.readContract({ address: PARAMS, abi: PARAMS_ABI, functionName: 'getRound', args: [rid] });
      const props = await client.readContract({ address: PARAMS, abi: PARAMS_ABI, functionName: 'getProposals', args: [rid] });
      const decided = rd.status === 2;
      console.log(`   round #${rid} · ${rd.knobKey} (range ${rd.lo}–${rd.hi})  [${STATUS[rd.status]}]`);
      console.log(`   decided value (median) = ${decided ? rd.canonicalValue.toString() : '—'}   proposals ${props.length}/${rd.n} (≥${rd.threshold} to settle)`);
      for (let i = 0; i < props.length; i++) {
        console.log(`     validator ${i + 1} ${short(props[i].operator)}  proposed ${props[i].value.toString()}  @ ${Number(props[i].confidenceBucket) / 100}% confidence`);
      }
    }
  } catch (e) {
    console.log(`   (parameters contract unreadable: ${e.shortMessage || e.message})`);
  }
  if (MINER) await showMining();

  console.log(`\nread on-chain ${new Date().toISOString()}\n`);
}

// AI-mining visibility: the AICoinMiner turns a verified A-Chain inference receipt into a
// subsidy mint with no trusted key — show what it has minted and to whom. This is the
// newest dimension of "thinking chain behavior": useful AI work, attested and on-chain.
async function showMining() {
  console.log(`\n── AI mining (attestation → AICoin, runs on any EVM) ──`);
  try {
    const coin = addr(await client.readContract({ address: MINER, abi: MINER_ABI, functionName: 'coin' }));
    const [reward, supply, minted, allow] = await Promise.all([
      client.readContract({ address: MINER, abi: MINER_ABI, functionName: 'rewardPerReceipt' }),
      client.readContract({ address: coin, abi: MINER_COIN_ABI, functionName: 'totalSupply' }),
      client.readContract({ address: coin, abi: MINER_COIN_ABI, functionName: 'mintedSubsidy' }),
      client.readContract({ address: coin, abi: MINER_COIN_ABI, functionName: 'emissionAllowance' }),
    ]);
    console.log(`   miner ${short(MINER)}  coin ${short(coin)}  reward ${ai(reward)} AI / verified receipt`);
    console.log(`   mined ${ai(minted)} AI   supply ${ai(supply)} AI   vested-claimable now ${ai(allow)} AI`);
    const latest = await client.getBlockNumber();
    const from = latest > 100000n ? latest - 50000n : 0n;
    const logs = await client.getLogs({ address: MINER, event: MINED_EVENT, fromBlock: from, toBlock: 'latest' });
    console.log(`\n   Recent attestation mints (${logs.length} in last ${(latest - from).toString()} blocks):`);
    if (!logs.length) console.log(`     (none in range)`);
    for (const l of logs.slice(-8)) {
      const a = l.args;
      console.log(`     intent ${short(a.intentID)} → ${ai(a.amount)} AI to ${short(a.requester)}  (root ${short(a.root)})`);
    }
  } catch (e) {
    console.log(`   (miner ${short(MINER)} unreadable: ${e.shortMessage || e.message || e})`);
  }
}

main().catch((e) => {
  console.error(`\n✗ cannot read ${OBS} at ${RPC}\n  ${e.shortMessage || e.message || e}\n`);
  process.exit(1);
});
