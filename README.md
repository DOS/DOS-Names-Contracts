# contracts-v2

## Monorepo for ENSv2 contracts + chain

Currently there is only one module, [contracts](/contracts). Read the contracts README to see how to build/test ENSv2 contracts.

## Testnet BENS metadata adapter

`subgraph/dos-names/adapter/server.mjs` is a read-only compatibility proxy for
the official BENS ENS-like API on DOS Testnet (3939). It preserves ENS namehash
identities while taking ERC-1155 token IDs and registry addresses from the
canonical Graph Node domain record. Public explorer links use the Testnet
origin; BENS itself can continue using its internal Blockscout URL for history.

The runtime loads the pinned deployment manifest from `/app/deployment.json`,
forwards public reads to `bens:8050`, and queries `bens-graph-node:8000` for token
metadata. It fails closed on indexing errors or inconsistent token state. It
has bounded requests, does not forward credentials, holds no keys and cannot
sign or submit transactions. Mainnet is not enabled. Run its isolated tests
with `node --test subgraph/dos-names/adapter/server.test.mjs` from the repo root.
