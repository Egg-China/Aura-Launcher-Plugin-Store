import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import test from 'node:test';

import {
  canonicalizeJsonText,
  createEnvelope,
  keyId,
  parseStrictJson,
  signatureInput,
  verifyEnvelope
} from './registry-envelope.mjs';

const REGISTRY = JSON.stringify({
  schemaVersion: 1,
  name: 'Aura Launcher Plugin Store',
  plugins: []
});

function signingFixture() {
  const pair = generateKeyPairSync('ed25519');
  const publicDer = pair.publicKey.export({ format: 'der', type: 'spki' });
  const privateDer = pair.privateKey.export({ format: 'der', type: 'pkcs8' });
  const id = keyId(pair.publicKey);
  const root = {
    signed: {
      _type: 'root',
      schemaVersion: 1,
      version: 1,
      expires: '2036-08-29T00:00:00Z',
      statusUrl: '',
      keys: {
        [id]: {
          keyType: 'ed25519',
          scheme: 'ed25519',
          publicKey: publicDer.toString('base64')
        }
      },
      roles: {
        'official-repository': {
          keyIds: [id],
          threshold: 1
        }
      }
    },
    signatures: []
  };
  return { pair, privateDer, id, root };
}

test('matches Aura canonical JSON and signature-domain bytes', () => {
  assert.equal(
    canonicalizeJsonText('{"z":[3,{"b":true,"a":null}],"a":-12}').toString('utf8'),
    '{"a":-12,"z":[3,{"a":null,"b":true}]}'
  );
  assert.equal(
    signatureInput('{"id":"dev.example"}').toString('utf8'),
    'HMCLCE-OFFICIAL-REGISTRY-V1\n{"id":"dev.example"}'
  );
});

test('returns a strict JSON value after validation', () => {
  assert.deepEqual(parseStrictJson('{"array":[null,false,42],"text":"Aura Launcher"}'), {
    array: [null, false, 42],
    text: 'Aura Launcher'
  });
});

test('rejects duplicate keys, fractions, unsafe integers, and unpaired surrogates', () => {
  for (const value of [
    '{"a":1,"a":2}',
    '{"value":1.5}',
    '{"value":9007199254740992}',
    '{"value":-9007199254740992}',
    '{"value":"\\ud800"}',
    '{"value":"\\udc00"}'
  ]) {
    assert.throws(() => canonicalizeJsonText(value), value);
  }
});

test('rejects comments, trailing commas, and trailing content', () => {
  for (const value of [
    '{/* comment */"a":1}',
    '{"a":1,}',
    '{"a":1} true'
  ]) {
    assert.throws(() => parseStrictJson(value), value);
  }
});

test('uses Aura minimal escaping and Java UTF-16 key order', () => {
  const supplementary = String.fromCodePoint(0x1f600);
  const privateUse = String.fromCharCode(0xe000);
  assert.equal(
    canonicalizeJsonText('{"\\ue000":1,"\\ud83d\\ude00":2,"escaped":"\\b\\f\\n\\r\\t\\u0000\\\"\\\\"}').toString('utf8'),
    `{"escaped":"\\b\\f\\n\\r\\t\\u0000\\\"\\\\","${supplementary}":2,"${privateUse}":1}`
  );
});

test('creates an Ed25519 envelope that verifies against the official role', () => {
  const { privateDer, id, root } = signingFixture();
  const envelope = createEnvelope(REGISTRY, privateDer.toString('base64'));

  assert.equal(envelope.signatures[0].keyId, id);
  assert.deepEqual(verifyEnvelope(JSON.stringify(envelope), JSON.stringify(root)), JSON.parse(REGISTRY));
});

test('rejects signed payload, signature, key ID, and envelope structure mutations', () => {
  const { privateDer, root } = signingFixture();
  const original = createEnvelope(REGISTRY, privateDer.toString('base64'));
  const mutations = [
    (value) => { value.signed.name = 'Mutated'; },
    (value) => { value.signatures[0].signature = `${value.signatures[0].signature.slice(0, -4)}AAAA`; },
    (value) => { value.signatures[0].keyId = `ed25519:${'0'.repeat(64)}`; },
    (value) => { value.signatures[0].signature = 'not base64'; },
    (value) => { value.signatures[0].scheme = 'ed25519'; },
    (value) => { value.extra = true; },
    (value) => { value.signatures.push(structuredClone(value.signatures[0])); }
  ];

  for (const mutate of mutations) {
    const envelope = structuredClone(original);
    mutate(envelope);
    assert.throws(() => verifyEnvelope(JSON.stringify(envelope), JSON.stringify(root)));
  }
});

test('rejects malformed or unauthorized trust roots', () => {
  const { privateDer, id, root } = signingFixture();
  const envelopeText = JSON.stringify(createEnvelope(REGISTRY, privateDer.toString('base64')));
  const mutations = [
    (value) => { delete value.signed.version; },
    (value) => { value.signed.version = 0; },
    (value) => { value.signed.version = -1; },
    (value) => { value.signed.version = 1.5; },
    (value) => { value.signed.keys[id].keyType = 'rsa'; },
    (value) => { value.signed.keys[id].scheme = 'rsa'; },
    (value) => { value.signed.keys[id].publicKey = 'not base64'; },
    (value) => {
      value.signed.keys[`ed25519:${'0'.repeat(64)}`] = value.signed.keys[id];
      delete value.signed.keys[id];
    },
    (value) => { value.signed.roles['official-repository'].threshold = 2; },
    (value) => { value.signed.roles['official-repository'].keyIds = []; },
    (value) => { delete value.signed.roles['official-repository']; }
  ];

  for (const mutate of mutations) {
    const changedRoot = structuredClone(root);
    mutate(changedRoot);
    assert.throws(() => verifyEnvelope(envelopeText, JSON.stringify(changedRoot)));
  }
});

test('rejects non-Ed25519 private keys and malformed private-key Base64', () => {
  const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const rsaPrivate = rsa.privateKey.export({ format: 'der', type: 'pkcs8' }).toString('base64');
  assert.throws(() => createEnvelope(REGISTRY, rsaPrivate));
  assert.throws(() => createEnvelope(REGISTRY, 'not base64'));
});
