// Zoo DAO — Thinking Chain Observatory (read-only on-chain visibility).
// viem is vendored same-origin (./viem.min.mjs) — no third-party CDN at runtime,
// so the page's CSP can pin script-src to 'self' and a poisoned/replaced CDN
// dependency cannot execute in a DAO member's browser.
import { createPublicClient, http, formatEther } from './viem.min.mjs';

const q = new URLSearchParams(location.search);
const RPC = q.get('rpc') || 'http://127.0.0.1:8546';
// deterministic Beluga L3 deploy address from beluga-l3-live.sh (acct0 nonce 2)
const OBS = q.get('observatory') || '0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0';
const REP = q.get('reputation') || '';
const PARAMS = q.get('parameters') || '';

const el = id => document.getElementById(id);
el('addr').textContent = `${RPC} · ${OBS.slice(0, 10)}…`;

// editable address bar — seed inputs from the active config, navigate on submit
el('in-rpc').value = RPC;
el('in-obs').value = OBS;
el('in-rep').value = REP;
el('in-par').value = PARAMS;
el('bar').addEventListener('submit', (e) => {
  e.preventDefault();
  const p = new URLSearchParams();
  const rpc = el('in-rpc').value.trim();
  const obs = el('in-obs').value.trim();
  const rep = el('in-rep').value.trim();
  const par = el('in-par').value.trim();
  if (rpc) p.set('rpc', rpc);
  if (obs) p.set('observatory', obs);
  if (rep) p.set('reputation', rep);
  if (par) p.set('parameters', par);
  location.search = p.toString();
});

// local-demo banner when the RPC is a loopback dev chain
try {
  const h = new URL(RPC).hostname;
  if (h === '127.0.0.1' || h === 'localhost' || h === '0.0.0.0' || h === '[::1]') {
    el('demo-rpc').textContent = RPC;
    el('demo').classList.add('show');
  }
} catch (_) { /* malformed RPC — leave banner hidden, tick() will surface the error */ }

const STATUS = ['None', 'Open', 'Settled', 'Failed'];
const VOTE = ['Invalid', 'YES', 'NO', 'Abstain'];
const PSTATUS = ['None', 'Open', 'Settled', 'Failed'];
const tup = (...c) => ({ type: 'tuple', components: c });
const u = (n) => ({ type: n });

const THOUGHT = tup(
  { name: 'taskId', type: 'uint256' }, { name: 'modelSpecHash', type: 'bytes32' }, { name: 'promptHash', type: 'bytes32' },
  { name: 'knobKey', type: 'string' }, { name: 'status', type: 'uint8' }, { name: 'canonicalVote', type: 'uint8' },
  { name: 'canonicalBucket', type: 'uint16' }, { name: 'n', type: 'uint8' }, { name: 'threshold', type: 'uint8' },
  { name: 'submissionCount', type: 'uint8' }, { name: 'agreeCount', type: 'uint8' }, { name: 'openedAt', type: 'uint64' }, { name: 'deadline', type: 'uint64' });
const RECEIPT = tup(
  { name: 'modelId', type: 'bytes32' }, { name: 'promptHash', type: 'bytes32' }, { name: 'outputHash', type: 'bytes32' },
  { name: 'paymentHash', type: 'bytes32' }, { name: 'quorumProof', type: 'bytes32' }, { name: 'payer', type: 'address' },
  { name: 'operator', type: 'address' }, { name: 'cost', type: 'uint96' }, { name: 'registeredAt', type: 'uint64' }, { name: 'blockNumber', type: 'uint64' });
const OVERVIEW = tup(
  { name: 'taskCount', type: 'uint256' }, { name: 'openCount', type: 'uint256' }, { name: 'settledCount', type: 'uint256' },
  { name: 'failedCount', type: 'uint256' }, { name: 'thoughtReceipts', type: 'uint256' }, { name: 'minBond', type: 'uint256' },
  { name: 'openFee', type: 'uint256' }, { name: 'treasury', type: 'address' });
const ECONOMICS = tup(
  { name: 'coin', type: 'address' }, { name: 'hardCap', type: 'uint256' }, { name: 'epoch', type: 'uint256' },
  { name: 'epochSubsidy', type: 'uint256' }, { name: 'unlocked', type: 'uint256' }, { name: 'minted', type: 'uint256' },
  { name: 'burned', type: 'uint256' }, { name: 'circulating', type: 'uint256' }, { name: 'remaining', type: 'uint256' });
const ABI = [
  { type: 'function', name: 'overview', stateMutability: 'view', inputs: [], outputs: [OVERVIEW] },
  { type: 'function', name: 'economics', stateMutability: 'view', inputs: [], outputs: [ECONOMICS] },
  { type: 'function', name: 'recentThoughts', stateMutability: 'view', inputs: [u('uint256')], outputs: [{ type: 'tuple[]', components: THOUGHT.components }] },
  { type: 'function', name: 'recentReceipts', stateMutability: 'view', inputs: [u('uint256')], outputs: [{ type: 'tuple[]', components: RECEIPT.components }] },
  { type: 'function', name: 'governor', stateMutability: 'view', inputs: [], outputs: [u('address')] },
];
// each thinking-validator's own signed verdict, read straight from the governor
const VERDICT = tup(
  { name: 'operator', type: 'address' }, { name: 'vote', type: 'uint8' }, { name: 'confidenceBucket', type: 'uint16' },
  { name: 'evidenceHash', type: 'bytes32' }, { name: 'submittedAt', type: 'uint64' });
const GOV_ABI = [
  { type: 'function', name: 'getVerdicts', stateMutability: 'view', inputs: [u('uint256')], outputs: [{ type: 'tuple[]', components: VERDICT.components }] },
];
// Proof-of-AI reputation (no slashing): earned weight, read from ThinkingReputation
const REP_ABI = [
  { type: 'function', name: 'weightOf', stateMutability: 'view', inputs: [u('address')], outputs: [u('uint32')] },
];
// Value-deciding governance: the validators' LLMs PROPOSE a knob value; the chain
// settles the median. Read rounds + proposals from ThinkingParameters.
const ROUND = tup(
  { name: 'modelSpecHash', type: 'bytes32' }, { name: 'promptHash', type: 'bytes32' }, { name: 'knobKey', type: 'string' },
  { name: 'lo', type: 'uint256' }, { name: 'hi', type: 'uint256' }, { name: 'n', type: 'uint8' }, { name: 'threshold', type: 'uint8' },
  { name: 'openedAt', type: 'uint64' }, { name: 'deadline', type: 'uint64' }, { name: 'opener', type: 'address' },
  { name: 'status', type: 'uint8' }, { name: 'submissionCount', type: 'uint8' }, { name: 'canonicalValue', type: 'uint256' });
const PROPOSAL = tup(
  { name: 'operator', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'confidenceBucket', type: 'uint16' },
  { name: 'evidenceHash', type: 'bytes32' }, { name: 'submittedAt', type: 'uint64' });
const PARAMS_ABI = [
  { type: 'function', name: 'roundCount', stateMutability: 'view', inputs: [], outputs: [u('uint256')] },
  { type: 'function', name: 'getRound', stateMutability: 'view', inputs: [u('uint256')], outputs: [ROUND] },
  { type: 'function', name: 'getProposals', stateMutability: 'view', inputs: [u('uint256')], outputs: [{ type: 'tuple[]', components: PROPOSAL.components }] },
];

const client = createPublicClient({ transport: http(RPC) });
const read = (fn, args = []) => client.readContract({ address: OBS, abi: ABI, functionName: fn, args });
let GOV_ADDR = null;
const short = h => h.slice(0, 8) + '…';
// escape on-chain strings before they enter an innerHTML sink. knobKey is an
// attacker-controlled free-text field (openThought only checks it's non-empty),
// so without this a knob like `<img src=x onerror=...>` is stored XSS executing
// in every DAO member's browser. All other rendered fields are numeric/hash/enum.
const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function card(n, l) { return `<div class="card"><div class="n">${n}</div><div class="l">${l}</div></div>`; }

async function tick() {
  try {
    const [ov, eco, thoughts, receipts] = await Promise.all([read('overview'), read('economics'), read('recentThoughts', [10n]), read('recentReceipts', [10n])]);
    el('conn').innerHTML = '<span class="dot"></span>live';
    el('cards').innerHTML =
      card(ov.taskCount, 'thoughts') + card(ov.openCount, 'open') +
      `<div class="card"><div class="n" style="color:var(--yes)">${ov.settledCount}</div><div class="l">settled</div></div>` +
      `<div class="card"><div class="n" style="color:var(--no)">${ov.failedCount}</div><div class="l">failed</div></div>` +
      card(ov.thoughtReceipts, 'PoT receipts');

    // AI economics — the chain's issuance behavior, straight from economics()
    if (eco.coin === '0x0000000000000000000000000000000000000000') {
      el('econ').innerHTML = '<div class="empty">no AI coin on this chain</div>';
    } else {
      const ai = w => Math.round(Number(formatEther(w))).toLocaleString();
      const pct = eco.hardCap > 0n ? (Number(eco.unlocked * 10000n / eco.hardCap) / 100).toFixed(2) : '0';
      el('econ').innerHTML =
        card(ai(eco.minted) + ' AI', 'mined') +
        `<div class="card"><div class="n" style="color:var(--no)">${ai(eco.burned)} AI</div><div class="l">burned (deflationary)</div></div>` +
        card(ai(eco.circulating) + ' AI', 'circulating') +
        `<div class="card"><div class="n">${pct}%</div><div class="l">of 1B cap unlocked (epoch ${eco.epoch})</div></div>` +
        card(ai(eco.remaining) + ' AI', 'remaining subsidy');
    }

    el('thoughts').innerHTML = thoughts.length ? thoughts.map(t => {
      const st = STATUS[t.status], vt = VOTE[t.canonicalVote], conf = Number(t.canonicalBucket) / 100;
      const decided = t.status === 2 ? `<span class="v-${vt}">${vt}</span>` : '<span class="mono">—</span>';
      const cbar = t.status === 2 ? `<span class="bar"><i style="width:${conf}%"></i></span> ${conf}%` : '<span class="mono">—</span>';
      return `<tr><td>${t.taskId}</td><td>${esc(t.knobKey)}</td>
        <td><span class="pill s-${st}">${st}</span></td><td>${decided}</td><td>${cbar}</td>
        <td class="mono">${t.agreeCount}/${t.n} (≥${t.threshold})</td></tr>`;
    }).join('') : '<tr><td colspan="6" class="empty">no thoughts yet — run beluga-l3-live.sh</td></tr>';

    // each thinking-validator's own verdict + earned Proof-of-AI reputation on the latest thought
    if (thoughts.length) {
      if (!GOV_ADDR) GOV_ADDR = await read('governor');
      const latest = thoughts[0];
      const vs = await client.readContract({ address: GOV_ADDR, abi: GOV_ABI, functionName: 'getVerdicts', args: [latest.taskId] });
      el('vhead').textContent = `Thinking validators — verdicts on thought #${latest.taskId} (${latest.knobKey})`;
      if (!vs.length) { el('verdicts').innerHTML = '<div class="empty">no verdicts submitted yet</div>'; }
      else {
        const cards = await Promise.all(vs.map(async (v, i) => {
          const vt = VOTE[v.vote];
          let rep = '';
          if (REP) {
            try {
              const w = await client.readContract({ address: REP, abi: REP_ABI, functionName: 'weightOf', args: [v.operator] });
              rep = `<div class="mono" style="color:var(--acc)">reputation ${Number(w) / 100}%</div>`;
            } catch (_) { }
          }
          return `<div class="vcard"><div class="vi">validator ${i + 1}</div><div class="mono">${short(v.operator)}</div>
            <div class="vv v-${vt}">${vt}</div><div class="mono">${Number(v.confidenceBucket) / 100}% confidence</div>${rep}</div>`;
        }));
        el('verdicts').innerHTML = cards.join('');
      }
    } else { el('verdicts').innerHTML = '<div class="empty">—</div>'; }

    // Parameter decisions — the values the validators' LLMs proposed + the median
    if (PARAMS) {
      try {
        const rc = await client.readContract({ address: PARAMS, abi: PARAMS_ABI, functionName: 'roundCount' });
        if (rc > 0n) {
          const rid = rc - 1n;
          const rd = await client.readContract({ address: PARAMS, abi: PARAMS_ABI, functionName: 'getRound', args: [rid] });
          const props = await client.readContract({ address: PARAMS, abi: PARAMS_ABI, functionName: 'getProposals', args: [rid] });
          const decided = rd.status === 2;
          el('phead').textContent = `Parameter Decisions — round #${rid} · ${esc(rd.knobKey)} (range ${rd.lo}–${rd.hi})`;
          el('paramcards').innerHTML =
            `<div class="card"><div class="n" style="color:${decided ? 'var(--yes)' : 'var(--fg)'}">${decided ? rd.canonicalValue.toString() : '—'}</div><div class="l">decided value (median)</div></div>` +
            card(props.length + '/' + rd.n, 'proposals') +
            `<div class="card"><div class="n">${PSTATUS[rd.status]}</div><div class="l">status (≥${rd.threshold} to settle)</div></div>`;
          el('paramprops').innerHTML = props.length ? props.map((p, i) =>
            `<div class="vcard"><div class="vi">validator ${i + 1}</div><div class="mono">${short(p.operator)}</div>
             <div class="vv" style="color:var(--acc);font-size:1.3em">${p.value.toString()}</div>
             <div class="mono">${Number(p.confidenceBucket) / 100}% confidence</div></div>`).join('')
            : '<div class="empty">no proposals yet</div>';
        } else { el('paramcards').innerHTML = '<div class="empty">no parameter rounds yet</div>'; }
      } catch (_) { el('paramcards').innerHTML = '<div class="empty">—</div>'; }
    } else { el('paramcards').innerHTML = '<div class="empty">pass ?parameters=0x… to view</div>'; }

    el('receipts').innerHTML = receipts.length ? receipts.map(r =>
      `<tr><td class="mono">${short(r.modelId)}</td><td class="mono">${short(r.promptHash)}</td>
       <td class="mono">${short(r.outputHash)}</td><td class="mono">${short(r.payer)}</td>
       <td class="mono">${short(r.operator)}</td><td>${formatEther(r.cost)} </td></tr>`
    ).join('') : '<tr><td colspan="6" class="empty">no receipts yet</td></tr>';

    el('err').textContent = '';
    el('foot').textContent = `read on-chain ${new Date().toLocaleTimeString()} · refreshes every 3s`;
  } catch (e) {
    el('conn').innerHTML = '<span class="dot" style="background:var(--no)"></span>offline';
    el('err').textContent = `cannot read ${OBS} at ${RPC} — is the Beluga L3 chain up (BELUGA_KEEP=1 ./beluga-l3-live.sh)? ${e.shortMessage || e.message || e}`;
  }
}
tick(); setInterval(tick, 3000);
