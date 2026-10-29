// Confirms contract errors come back as plain words. Only simulates; nothing is sent.
import { parseEther } from 'viem'
import { exchange } from '../src/lib/chain'
import { explainError } from '../src/lib/errors'
import { connectLocal, send } from '../src/lib/wallet'

const w = connectLocal()
const cases: [string, Parameters<typeof send>[1]][] = [
  ['leverage too high for a short', { ...exchange, functionName: 'open', args: [0n, false, 10, parseEther('0.01'), -8_000_000], value: parseEther('1') }],
  ['withdraw more than balance', { ...exchange, functionName: 'withdraw', args: [parseEther('100000')] }],
  ['close a position that does not exist', { ...exchange, functionName: 'close', args: [999_999n, 0] }],
]
for (const [label, call] of cases) {
  try {
    await send(w, call)
    console.log(`${label}: unexpectedly succeeded`)
  } catch (e) {
    console.log(`${label}: ${explainError(e)}`)
  }
}
