/* House-pool engine: one SOL pool takes the other side of every leveraged memecoin bet.
   Fixed rules follow useinverse.xyz/how as read on 2026-10-29; editable rules come in `rules`. */
(function (root) {
  'use strict';

  const STEP_MIN = 10;
  const STEPS_PER_HOUR = 60 / STEP_MIN;
  const STEPS_PER_DAY = 24 * STEPS_PER_HOUR;
  const DT = 1 / STEPS_PER_DAY;
  const SAMPLES_PER_DAY = 4;
  const SAMPLE_EVERY = STEPS_PER_DAY / SAMPLES_PER_DAY;
  const ACTIVE_COINS = 30;
  const DELIST_PRICE = 0.2;           // coin falls 80% from listing: no new trades
  const DELIST_GRACE = STEPS_PER_DAY; // leftover positions settle a day later
  const HEDGE_COST = 0.005;           // DEX fee + slippage per rebalance, both ways
  const INSIDER_MAX_STAKE = 2;

  const FEE = { stakePct: 0.01, sizePct: 0.0025, profit: 0.10, liqEquity: 0.15, freeHours: 1 };

  const levAllowed = (liq) => (liq >= 500 ? 10 : liq >= 150 ? 5 : 2);
  const maxWinTier = (pool) => (pool >= 500 ? 10 : pool >= 250 ? 6 : 4);
  const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));

  function mulberry32(seed) {
    let a = seed >>> 0;
    return function () {
      a = (a + 0x6d2b79f5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function mix(a, b) {
    let h = Math.imul((a ^ 0x9e3779b9) >>> 0, 0x85ebca6b) ^ Math.imul((b + 0x7f4a7c15) >>> 0, 0xc2b2ae35);
    h ^= h >>> 16; h = Math.imul(h, 0x7feb352d); h ^= h >>> 15; h = Math.imul(h, 0x846ca68b); h ^= h >>> 16;
    return h >>> 0;
  }
  function normal(r) {
    const u = 1 - r(), v = r();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  }
  function poisson(r, lam) {
    const L = Math.exp(-lam);
    let k = 0, p = 1;
    do { k++; p *= r(); } while (p > L);
    return k - 1;
  }

  function openFee(stake, size) {
    return Math.max(FEE.stakePct * stake, FEE.sizePct * size);
  }

  // Close one position. P is the trader's gross P&L in SOL (already capped), H the holding fees owed.
  function settle(stake, size, P, H, liquidated, feeShare) {
    const equity = stake + P - H;
    if (liquidated) {
      const liqFee = Math.max(0, equity);
      return { traderBack: 0, closeFee: 0, profitFee: 0, liqFee, fees: liqFee,
        kept: stake - liqFee, pool: stake - liqFee + feeShare * liqFee, platform: (1 - feeShare) * liqFee };
    }
    const closeFee = Math.max(FEE.stakePct * equity, FEE.sizePct * size);
    const profitFee = FEE.profit * Math.max(0, P - H);
    const fees = closeFee + profitFee;
    return { traderBack: equity - fees, closeFee, profitFee, liqFee: 0, fees, kept: 0,
      pool: -P + H + feeShare * fees, platform: (1 - feeShare) * fees };
  }

  function simulate(cfg, rules, seed) {
    const m = cfg.market, tr = cfg.traders;
    const steps = Math.round(m.days * STEPS_PER_DAY);
    const listRng = mulberry32(mix(seed, 1));
    const tradeRng = mulberry32(mix(seed, 2));
    const drift = Math.log(1 + m.move);
    const volStep = m.vol * Math.sqrt(DT);
    const rugP = m.rugRate * DT, pumpP = m.pumpRate * DT;
    const lam = tr.perDay * DT;

    let nextId = 0;
    function newCoin() {
      const id = nextId++;
      const liq0 = clamp(120 * Math.exp(normal(listRng)), 20, 3000);
      const mu = drift + m.spread * normal(listRng);
      const c = { id, rng: mulberry32(mix(seed, 1000 + id)), p: 1, liq0, liq: liq0, mu, weight: Math.sqrt(liq0),
        active: true, delistAt: -1, rugNow: false, forceClose: false, net: 0, expo: 0, hedge: 0, count: 0 };
      drawNext(c);
      return c;
    }
    // Each coin draws its next move one step ahead, so an insider can bet on a pump or rug before it lands.
    function drawNext(c) {
      const r = c.rng;
      c.nz = normal(r); c.nuj = r(); c.num = r(); c.nui = r();
    }

    let coins = [];
    for (let i = 0; i < ACTIVE_COINS; i++) coins.push(newCoin());

    const start = cfg.pool;
    let cash = start;
    let sumMaxWin = 0;
    const positions = [];
    const bd = { kept: 0, liq: 0, hold: 0, fees: 0, paidShorts: 0, paidLongs: 0, rugPaid: 0, hedge: 0 };
    const st = { arrivals: 0, accepted: 0, rejCover: 0, rejCoin: 0, rejPool: 0, closes: 0, wins: 0, liqs: 0,
      maxWins: 0, rugSettles: 0, shorts: 0, platform: 0, traderNet: 0, staked: 0, insiders: 0, insiderNet: 0 };
    const series = [start];

    for (let t = 0; t < steps; t++) {
      // 1. Prices move. Each coin has its own random stream, so every rule set sees the same market.
      for (const c of coins) {
        const z = c.nz, uj = c.nuj, um = c.num;
        drawNext(c);
        const prev = c.p;
        let p = prev * Math.exp(c.mu * DT + volStep * z);
        c.rugNow = false;
        if (uj < rugP) { p *= 0.05 + 0.1 * um; c.rugNow = true; }
        else if (uj > 1 - pumpP) { p *= 1.5 + 1.5 * um; }
        c.p = p;
        c.liq = c.liq0 * Math.sqrt(p);
        c.forceClose = !c.active && t - c.delistAt >= DELIST_GRACE;
        if (c.hedge > 0) {
          const cur = c.hedge * (p / prev);
          cash += cur - c.hedge; bd.hedge += cur - c.hedge; c.hedge = cur;
        }
        c.expo = 0;
      }

      // 2. Open positions: max win, liquidation, rug guard, planned close.
      for (let i = positions.length - 1; i >= 0; i--) {
        const q = positions[i], c = q.coin;
        const pnl = q.dir * q.lev * (c.p / q.p0 - 1);
        if (t - q.t0 >= STEPS_PER_HOUR * FEE.freeHours) {
          const crowded = c.net * q.dir > 0;
          q.H += (rules.holdRate * q.size * (crowded ? rules.crowdMult : 1)) / STEPS_PER_HOUR;
        }
        let reason = 0, P;
        if (c.rugNow) {
          if (q.dir < 0 && rules.rugGuard) { P = Math.min(pnl, rules.rugCap) * q.stake; reason = 4; }
          else { P = Math.min(pnl, q.cap) * q.stake; reason = pnl >= q.cap ? 1 : 3; }
        } else if (pnl >= q.cap) { P = q.cap * q.stake; reason = 1; }
        else {
          P = pnl * q.stake;
          if (t >= q.tEnd || c.forceClose) reason = 3;
        }
        const liquidated = reason !== 1 && reason !== 4 && q.stake + P - q.H <= FEE.liqEquity * q.stake;
        if (!liquidated && reason === 0) { c.expo += q.dir * q.size * (c.p / q.p0); continue; }

        const s = settle(q.stake, q.size, P, q.H, liquidated, rules.feeShare);
        cash += s.pool;
        bd.fees += rules.feeShare * s.fees;
        st.platform += s.platform;
        if (liquidated) { bd.liq += s.kept; st.liqs++; }
        else {
          bd.hold += q.H;
          if (P > 0) {
            if (reason === 4) { bd.rugPaid -= P; st.rugSettles++; }
            else if (q.dir < 0) bd.paidShorts -= P;
            else bd.paidLongs -= P;
          } else bd.kept -= P;
          if (reason === 1) st.maxWins++;
        }
        const net = s.traderBack - q.stake - q.openFee;
        st.traderNet += net;
        if (q.insider) st.insiderNet += net;
        if (net > 0) st.wins++;
        st.closes++;
        c.net -= q.dir * q.size; c.count--;
        sumMaxWin -= q.cap * q.stake;
        positions[i] = positions[positions.length - 1]; positions.pop();
      }

      // 3. Listings: a rugged or bled-out coin is replaced by a fresh one.
      let changed = false;
      for (let i = 0, n = coins.length; i < n; i++) {
        const c = coins[i];
        if (!c.active) continue;
        if (c.rugNow || c.p < DELIST_PRICE) { c.active = false; c.delistAt = t; coins.push(newCoin()); changed = true; }
      }
      if (changed || t % STEPS_PER_HOUR === 0) {
        coins = coins.filter((c) => c.active || c.count > 0 || c.hedge > 0);
      }
      let totalW = 0;
      for (const c of coins) if (c.active) totalW += c.weight;

      // 4a. Insiders bet just before a pump or rug they know about, using all the room the coin allows.
      if (m.insider > 0) {
        for (const c of coins) {
          if (!c.active || c.nui >= m.insider) continue;
          const dir = c.nuj < rugP ? -1 : c.nuj > 1 - pumpP ? 1 : 0;
          if (!dir || cash < 1) continue;
          const lev = levAllowed(c.liq);
          const room = Math.min(rules.coinCapSol, rules.coinCapPct * c.liq) - dir * c.net;
          const stake = Math.min(INSIDER_MAX_STAKE, room / lev);
          if (stake < 0.01) { st.rejCoin++; continue; }
          let cap = maxWinTier(cash);
          if (dir < 0) cap = Math.min(cap, rules.shortWinCap, lev);
          if (sumMaxWin + cap * stake > rules.coverage * cash) { st.rejCover++; continue; }
          const size = stake * lev, fo = openFee(stake, size);
          cash += rules.feeShare * fo; bd.fees += rules.feeShare * fo; st.platform += (1 - rules.feeShare) * fo;
          positions.push({ coin: c, dir, stake, lev, size, p0: c.p, t0: t, tEnd: t + 1, cap, H: 0, openFee: fo, insider: true });
          c.net += dir * size; c.count++; c.expo += dir * size;
          sumMaxWin += cap * stake;
          st.insiders++; st.staked += stake;
        }
      }

      // 4b. New bets arrive. Every arrival draws the same randoms whether or not it is accepted.
      const n = poisson(tradeRng, lam);
      for (let k = 0; k < n; k++) {
        const uc = tradeRng(), us = tradeRng(), ui = tradeRng(), zs = normal(tradeRng), uh = tradeRng(), ul = tradeRng();
        st.arrivals++;
        let pick = uc * totalW, c = null;
        for (const x of coins) { if (!x.active) continue; pick -= x.weight; c = x; if (pick <= 0) break; }
        if (!c) { st.rejPool++; continue; }
        const dir = ui < tr.skill ? (c.mu < 0 ? -1 : 1) : us < tr.shortShare ? -1 : 1;
        const stake = clamp(tr.stake * Math.exp(0.8 * zs - 0.32), 0.01, 10);
        const want = ul < tr.levMix[0] ? 2 : ul < tr.levMix[0] + tr.levMix[1] ? 5 : 10;
        const lev = Math.min(want, levAllowed(c.liq));
        const size = stake * lev;
        const holdSteps = Math.max(1, Math.round(-Math.log(1 - uh) * tr.holdHours * STEPS_PER_HOUR));
        if (cash < 1) { st.rejPool++; continue; }
        const coinCap = Math.min(rules.coinCapSol, rules.coinCapPct * c.liq);
        const newNet = c.net + dir * size;
        if (Math.abs(newNet) > coinCap && Math.abs(newNet) > Math.abs(c.net)) { st.rejCoin++; continue; }
        let cap = maxWinTier(cash);
        if (dir < 0) cap = Math.min(cap, rules.shortWinCap, lev);
        if (sumMaxWin + cap * stake > rules.coverage * cash) { st.rejCover++; continue; }

        const fo = openFee(stake, size);
        cash += rules.feeShare * fo; bd.fees += rules.feeShare * fo; st.platform += (1 - rules.feeShare) * fo;
        positions.push({ coin: c, dir, stake, lev, size, p0: c.p, t0: t, tEnd: t + holdSteps, cap, H: 0, openFee: fo });
        c.net = newNet; c.count++; c.expo += dir * size;
        sumMaxWin += cap * stake;
        st.accepted++; st.staked += stake;
        if (dir < 0) st.shorts++;
      }

      // 5. Optional hedge: hold spot against the traders' net long on each coin.
      for (const c of coins) {
        const target = rules.hedge * Math.max(0, c.expo);
        if (target === 0 && c.hedge === 0) continue;
        const cost = HEDGE_COST * Math.abs(target - c.hedge);
        cash -= cost; bd.hedge -= cost; c.hedge = target;
      }

      if ((t + 1) % SAMPLE_EVERY === 0) {
        let owed = 0;
        for (const q of positions) {
          const pnl = q.dir * q.lev * (q.coin.p / q.p0 - 1);
          owed += Math.max(-q.stake, Math.min(q.cap * q.stake, pnl * q.stake) - q.H);
        }
        series.push(cash - owed);
      }
    }
    return { start, series, final: series[series.length - 1], cash, bd, st };
  }

  function quantile(sorted, q) {
    const i = (sorted.length - 1) * q, lo = Math.floor(i), hi = Math.ceil(i);
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo);
  }

  // Summarise many runs of one rule set: percentile bands over time and averages of the breakdown.
  function summarize(start, results) {
    const len = results[0].series.length;
    const bands = [];
    for (let i = 0; i < len; i++) {
      const v = results.map((r) => r.series[i]).sort((x, y) => x - y);
      bands.push({ p10: quantile(v, 0.1), p50: quantile(v, 0.5), p90: quantile(v, 0.9) });
    }
    const finals = results.map((r) => r.final).sort((x, y) => x - y);
    const avg = (pick) => results.reduce((s, r) => s + pick(r), 0) / results.length;
    const bd = {}, st = {};
    for (const key in results[0].bd) bd[key] = avg((r) => r.bd[key]);
    for (const key in results[0].st) st[key] = avg((r) => r.st[key]);
    return {
      start, bands, finals, runs: results.length,
      median: quantile(finals, 0.5), p10: quantile(finals, 0.1), p90: quantile(finals, 0.9),
      lossChance: finals.filter((f) => f < start).length / finals.length,
      bd, st,
    };
  }

  // Run every rule set on the same `runs` markets.
  function compare(cfg, ruleSets, runs, baseSeed) {
    const all = ruleSets.map(() => []);
    for (let k = 0; k < runs; k++) {
      const seed = mix(baseSeed, k);
      ruleSets.forEach((rules, j) => all[j].push(simulate(cfg, rules, seed)));
    }
    return all.map((results) => summarize(cfg.pool, results));
  }

  const api = { simulate, summarize, compare, mix, settle, openFee, maxWinTier, levAllowed, FEE, SAMPLES_PER_DAY, HEDGE_COST };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.PoolEngine = api;
})(typeof self !== 'undefined' ? self : this);
