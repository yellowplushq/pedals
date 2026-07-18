# PedalsKit cross-implementation test vectors

Canonical vectors asserted byte-for-byte by both the Swift test suite
(`shared/PedalsKit/Tests/PedalsKitTests/TestVectorTests.swift`) and the Node reference
implementation (`relay/test/crypto-ref.mjs`). All values are lowercase hex unless noted.

## Inputs

| value  | bytes |
|--------|-------|
| secret | 32 bytes of `0x42` — `4242…42` (×32) |

## HKDF-SHA256 direction keys (PROTOCOL.md §2)

`salt = "pedals-v2"` (UTF-8, 9 bytes), output length 32 bytes.

| key | info | value |
|-----|------|-------|
| key_h2c | `host->client` | `6972bc6da52c7ca19a55c1304c25846b032531a6142175312d54fdf09592ff40` |
| key_c2h | `client->host` | `92961f97fbed1c21af672ab1f143c8b13589b10b849b0afed483aaff6cc4b3b7` |

Node reproduction:

```js
const crypto = require('node:crypto');
const secret = Buffer.alloc(32, 0x42);
const key = Buffer.from(
  crypto.hkdfSync('sha256', secret, Buffer.from('pedals-v2'), Buffer.from('host->client'), 32));
```

## Sealed message (PROTOCOL.md §3, direction host→client, key_h2c)

Nonces are random on the wire. This vector's nonce was **fixed once at generation time**
(the ASCII string `pedals-nonce`, exactly 12 bytes) so both implementations can assert the
exact same blob; tests must *decrypt* this embedded message, never re-seal and compare.

| field | value |
|-------|-------|
| plaintext frame | ctl frame: type `0x00` \|\| sessionId 0 (u32 LE) \|\| `"hello"` = `000000000068656c6c6f` |
| seq | 1 |
| AAD (seq u64 LE) | `0100000000000000` |
| nonce | `706564616c732d6e6f6e6365` (`pedals-nonce`) |
| ciphertext (10 bytes) | `94d3740a19c7dc465ace` |
| Poly1305 tag (16 bytes) | `5279fe452d7a661383a99da076062944` |
| combined (nonce ‖ ct ‖ tag) | `706564616c732d6e6f6e636594d3740a19c7dc465ace5279fe452d7a661383a99da076062944` |
| **full WebSocket message** (seq ‖ combined) | `0100000000000000706564616c732d6e6f6e636594d3740a19c7dc465ace5279fe452d7a661383a99da076062944` |

Expected assertions in both suites:

1. Opening the full message with `key_h2c` and AAD `0100000000000000` yields the plaintext
   frame `000000000068656c6c6f` (ctl, sessionId 0, payload `hello`).
2. Opening the same message a second time on the same channel fails (seq 1 is not
   strictly greater than the last accepted seq 1 — replay rejection).
3. Opening the message with `key_c2h` fails authentication (direction keys are distinct).
