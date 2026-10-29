// Session keys and signed intents for LevRouter. Isomorphic: only WebCrypto and viem, so the web app can use it too.
//
//   const session = await createSessionKey();            // non-extractable P-256 key
//   wallet: router.authorize(session.qx, session.qy, limits) { value: deposit }
//   const sig = await signIntent(session.privateKey, 'open', intent, chainId, router);
//   fetch(`${relayer}/intents`, { method: 'POST', body: JSON.stringify(bodyFor('open', intent, sig)) });

import { bytesToHex, encodeAbiParameters, hashTypedData, hexToBytes, keccak256, numberToHex, type Address, type Hex } from 'viem';

export const ACT_OPEN = 1;
export const ACT_CLOSE_OWN = 2; // close positions this session opened
export const ACT_CLOSE_ANY = 4; // close any of the owner's positions
export const ACT_WITHDRAW = 8; // withdraw to the owner's own address

export const MAX_DEADLINE_AHEAD = 120n; // the router rejects deadlines further ahead than this
export const DEADLINE_SECONDS = 30n; // what the app signs: the relayer can only pick timing within this window

/** P-256 group order. The router only accepts low-s signatures (s <= n/2). */
export const P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;

export type Limits = {
  expiry: bigint; // uint64, unix seconds, at most 7 days ahead
  actions: number; // ACT_* bits
  maxLeverage: number;
  openSlipTicks: number; // 1 tick ~ 0.01%
  closeSlipTicks: number;
  maxStakePerTrade: bigint;
  maxOpenStake: bigint;
  dailyBudget: bigint;
};

export type OpenIntent = {
  owner: Address;
  key: Hex;
  generation: number;
  marketId: number;
  isLong: boolean;
  leverage: number;
  stake: bigint;
  limitTick: number;
  nonce: bigint;
  deadline: bigint;
};
export type CloseIntent = {
  owner: Address;
  key: Hex;
  generation: number;
  positionId: bigint;
  limitTick: number; // worst acceptable exit: longs revert below it, shorts above it
  nonce: bigint;
  deadline: bigint;
};
export type WithdrawIntent = { owner: Address; key: Hex; generation: number; amount: bigint; nonce: bigint; deadline: bigint };
export type RevokeIntent = { owner: Address; key: Hex; generation: number; nonce: bigint; deadline: bigint };

export type IntentOf = { open: OpenIntent; close: CloseIntent; withdraw: WithdrawIntent; revoke: RevokeIntent };
export type Kind = keyof IntentOf;
export type Signature = { r: Hex; s: Hex };

// EIP-712 types, field for field as in LevRouter.
export const TYPES = {
  Open: [
    { name: 'owner', type: 'address' },
    { name: 'key', type: 'bytes32' },
    { name: 'generation', type: 'uint32' },
    { name: 'marketId', type: 'uint32' },
    { name: 'isLong', type: 'bool' },
    { name: 'leverage', type: 'uint8' },
    { name: 'stake', type: 'uint96' },
    { name: 'limitTick', type: 'int24' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint64' },
  ],
  Close: [
    { name: 'owner', type: 'address' },
    { name: 'key', type: 'bytes32' },
    { name: 'generation', type: 'uint32' },
    { name: 'positionId', type: 'uint256' },
    { name: 'limitTick', type: 'int24' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint64' },
  ],
  Withdraw: [
    { name: 'owner', type: 'address' },
    { name: 'key', type: 'bytes32' },
    { name: 'generation', type: 'uint32' },
    { name: 'amount', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint64' },
  ],
  Revoke: [
    { name: 'owner', type: 'address' },
    { name: 'key', type: 'bytes32' },
    { name: 'generation', type: 'uint32' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint64' },
  ],
} as const;

export const PRIMARY_TYPE = { open: 'Open', close: 'Close', withdraw: 'Withdraw', revoke: 'Revoke' } as const;

/** The router function each kind maps to. These four are the only calls a relayer ever makes. */
export const ROUTER_FUNCTION = { open: 'open', close: 'close', withdraw: 'withdraw', revoke: 'revokeBySig' } as const;

export function domain(chainId: number, router: Address) {
  return { name: 'MemeLev', version: '1', chainId, verifyingContract: router } as const;
}

/** The EIP-712 digest; the router's hashOpen/hashClose/hashWithdraw/hashRevoke views return the same value. */
export function digestOf<K extends Kind>(kind: K, intent: IntentOf[K], chainId: number, router: Address): Hex {
  const primaryType = PRIMARY_TYPE[kind];
  return hashTypedData({
    domain: domain(chainId, router),
    types: { [primaryType]: TYPES[primaryType] },
    primaryType,
    message: intent,
  } as Parameters<typeof hashTypedData>[0]);
}

export type SessionKey = { privateKey: CryptoKey; publicKey: CryptoKey; qx: Hex; qy: Hex; key: Hex };

/** The router's id for a session key: keccak256(abi.encode(qx, qy)). */
export function keyIdOf(qx: Hex, qy: Hex): Hex {
  return keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'bytes32' }], [qx, qy]));
}

/** A new P-256 session key. The private key is non-extractable: it can sign but never be read out. */
export async function createSessionKey(): Promise<SessionKey> {
  const pair = (await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify'])) as CryptoKeyPair;
  return { privateKey: pair.privateKey, publicKey: pair.publicKey, ...(await publicKeyCoords(pair.publicKey)) };
}

/** qx, qy and the key id of a P-256 public key (raw export is 0x04 || x || y). */
export async function publicKeyCoords(publicKey: CryptoKey): Promise<{ qx: Hex; qy: Hex; key: Hex }> {
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', publicKey));
  if (raw.length !== 65 || raw[0] !== 4) throw new Error('expected an uncompressed P-256 public key');
  const qx = bytesToHex(raw.slice(1, 33));
  const qy = bytesToHex(raw.slice(33, 65));
  return { qx, qy, key: keyIdOf(qx, qy) };
}

/**
 * Sign an EIP-712 digest. WebCrypto hashes the 32 digest bytes with SHA-256, which is what the router verifies
 * (P256.verify(sha256(digest), r, s, qx, qy)). It returns r || s; s is flipped to the low half if needed.
 */
export async function signDigest(privateKey: CryptoKey, digest: Hex): Promise<Signature> {
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, hexToBytes(digest)));
  if (sig.length !== 64) throw new Error('expected a 64-byte P-256 signature');
  let s = BigInt(bytesToHex(sig.slice(32, 64)));
  if (s > P256_N / 2n) s = P256_N - s;
  return { r: bytesToHex(sig.slice(0, 32)), s: numberToHex(s, { size: 32 }) };
}

export function signIntent<K extends Kind>(
  privateKey: CryptoKey,
  kind: K,
  intent: IntentOf[K],
  chainId: number,
  router: Address,
): Promise<Signature> {
  return signDigest(privateKey, digestOf(kind, intent, chainId, router));
}

/** A random 256-bit nonce. Nonces only need to be unique per owner, so random ones never need syncing. */
export function randomNonce(): bigint {
  return BigInt(bytesToHex(crypto.getRandomValues(new Uint8Array(32))));
}

/** Deadline for a new intent: the latest block's timestamp plus 30 s. */
export function deadlineFrom(latestBlockTimestamp: bigint, seconds = DEADLINE_SECONDS): bigint {
  return latestBlockTimestamp + seconds;
}

export type WireIntent = Record<string, string | boolean>;

/** JSON form for the relayer: numbers as decimal strings, bools as booleans, addresses and bytes32 as 0x hex. */
export function toWire(intent: object): WireIntent {
  const out: WireIntent = {};
  for (const [k, v] of Object.entries(intent)) out[k] = typeof v === 'boolean' ? v : String(v);
  return out;
}

export function bodyFor<K extends Kind>(kind: K, intent: IntentOf[K], signature: Signature) {
  return { kind, intent: toWire(intent), signature };
}
