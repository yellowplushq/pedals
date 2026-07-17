# PedalsKit cross-implementation test vectors

Canonical vectors asserted byte-for-byte by both the Swift test suite
(`shared/PedalsKit/Tests/PedalsKitTests/TestVectorTests.swift`) and the Node reference
implementation (`relay/test/crypto-ref.mjs`). All values are lowercase hex unless noted.

## Inputs

| value  | bytes |
|--------|-------|
| secret | 32 bytes of `0x42` — `4242…42` (×32) |

## HKDF-SHA256 direction keys (PROTOCOL.md §2)

`salt = "pedals-v1"` (UTF-8, 9 bytes), output length 32 bytes.

| key | info | value |
|-----|------|-------|
| key_h2c | `host->client` | `f5f1ae11b574be72b8afa4068d3509bf2d8f8d469d1ed16651d41406f923e641` |
| key_c2h | `client->host` | `d4f715a850ee4d287fd5aba0d5dad7145fe93a9a4f22223a49bfa91b285ac333` |

Node reproduction:

```js
const crypto = require('node:crypto');
const secret = Buffer.alloc(32, 0x42);
const key = Buffer.from(
  crypto.hkdfSync('sha256', secret, Buffer.from('pedals-v1'), Buffer.from('host->client'), 32));
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
| ciphertext (10 bytes) | `8b58f5073d8b010d6550` |
| Poly1305 tag (16 bytes) | `5138d2966bdeed53ba46abe5967cb475` |
| combined (nonce ‖ ct ‖ tag) | `706564616c732d6e6f6e63658b58f5073d8b010d65505138d2966bdeed53ba46abe5967cb475` |
| **full WebSocket message** (seq ‖ combined) | `0100000000000000706564616c732d6e6f6e63658b58f5073d8b010d65505138d2966bdeed53ba46abe5967cb475` |

Expected assertions in both suites:

1. Opening the full message with `key_h2c` and AAD `0100000000000000` yields the plaintext
   frame `000000000068656c6c6f` (ctl, sessionId 0, payload `hello`).
2. Opening the same message a second time on the same channel fails (seq 1 is not
   strictly greater than the last accepted seq 1 — replay rejection).
3. Opening the message with `key_c2h` fails authentication (direction keys are distinct).
