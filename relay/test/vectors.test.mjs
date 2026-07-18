// Cross-implementation crypto vectors from shared/PedalsKit/TESTVECTORS.md.
// The same bytes are asserted by PedalsKit's Swift suite (TestVectorTests.swift);
// this file proves the Node reference implementation interoperates.

import test from "node:test";
import assert from "node:assert/strict";
import { deriveKeys, open, seal, seqBytes, decodeFrame, FrameType } from "./crypto-ref.mjs";

const SECRET = Buffer.alloc(32, 0x42);

const KEY_H2C_HEX =
  "6972bc6da52c7ca19a55c1304c25846b032531a6142175312d54fdf09592ff40";
const KEY_C2H_HEX =
  "92961f97fbed1c21af672ab1f143c8b13589b10b849b0afed483aaff6cc4b3b7";

// seq(8, LE) || nonce("pedals-nonce") || ciphertext(10) || tag(16)
const FULL_MESSAGE_HEX =
  "0100000000000000706564616c732d6e6f6e636594d3740a19c7dc465ace" +
  "5279fe452d7a661383a99da076062944";
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
