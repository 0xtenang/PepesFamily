var a=({address:n,nonce:o})=>`${window.location.host} wants you to sign in with your Solana account:
${n}

${`You are proving you own ${n}.`}

URI: ${window.location.origin}
Version: 1
Chain ID: mainnet
Nonce: ${o}
Issued At: ${new Date().toISOString()}
Resources:
- https://privy.io`;var s=Symbol("solana-funding-plugin"),e=Symbol("solana-ledger-plugin");export{a,s as b,e as c};
