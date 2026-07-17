// Cross-implementation crypto vectors from shared/PedalsKit/TESTVECTORS.md.
// The same bytes are asserted by PedalsKit's Swift suite (TestVectorTests.swift);
// this file proves the Node reference implementation interoperates.

import test from "node:test";
import assert from "node:assert/strict";
import { deriveKeys, open, seal, seqBytes, decodeFrame, FrameType } from "./crypto-ref.mjs";

const SECRET = Buffer.alloc(32, 0x42);

const KEY_H2C_HEX =
  "f5f1ae11b574be72b8afa4068d3509bf2d8f8d469d1ed16651d41406f923e641";
const KEY_C2H_HEX =
  "d4f715a850ee4d287fd5aba0d5dad7145fe93a9a4f22223a49bfa91b285ac333";

// seq(8, LE) || nonce("pedals-nonce") || ciphertext(10) || tag(16)
const FULL_MESSAGE_HEX =
  "0100000000000000706564616c732d6e6f6e63658b58f5073d8b010d6550" +
  "5138d2966bdeed53ba46abe5967cb475";
const PLAINTEXT_FRAME_HEX = "000000000068656c6c6f"; // ctl, sid 0, "hello"

test("HKDF-SHA256 direction keys match TESTVECTORS.md", () => {
  const { h2c, c2h } = deriveKeys(SECRET);
  assert.equal(h2c.toString("hex"), KEY_H2C_HEX);
  assert.equal(c2h.toString("hex"), KEY_C2H_HEX);
});

test("sealed message vector decrypts to the ctl frame", () => {
  const { h2c } = deriveKeys(SECRET);
  const { seq, plaintext } = open(h2c, Buffer.from(FULL_MESSAGE_HEX, "hex"));
  assert.equal(seq, 1n);
  assert.equal(plaintext.toString("hex"), PLAINTEXT_FRAME_HEX);

  const frame = decodeFrame(plaintext);
  assert.equal(frame.type, FrameType.ctl);
  assert.equal(frame.sessionId, 0);
  assert.equal(frame.payload.toString("utf8"), "hello");
});

test("re-sealing with the vector's fixed nonce reproduces the exact blob", () => {
  const { h2c } = deriveKeys(SECRET);
  const message = seal(
    h2c,
    1,
    Buffer.from(PLAINTEXT_FRAME_HEX, "hex"),
    Buffer.from("pedals-nonce", "utf8"),
  );
  assert.equal(message.toString("hex"), FULL_MESSAGE_HEX);
});

test("opening with the wrong direction key fails authentication", () => {
  const { c2h } = deriveKeys(SECRET);
  assert.throws(() => open(c2h, Buffer.from(FULL_MESSAGE_HEX, "hex")));
});

test("tampering with the AAD (seq) fails authentication", () => {
  const { h2c } = deriveKeys(SECRET);
  const tampered = Buffer.from(FULL_MESSAGE_HEX, "hex");
  tampered.set(seqBytes(2), 0);
  assert.throws(() => open(h2c, tampered));
});
