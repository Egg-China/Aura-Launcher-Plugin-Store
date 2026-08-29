import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign as signBytes,
  verify as verifyBytes
} from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { parseTree, printParseErrorCode } from 'jsonc-parser';

export const OFFICIAL_REGISTRY_DOMAIN = 'HMCLCE-OFFICIAL-REGISTRY-V1';
export const MAX_SAFE_INTEGER = 9007199254740991n;
const OFFICIAL_REPOSITORY_ROLE = 'official-repository';

function strictTree(text) {
  if (typeof text !== 'string') {
    throw new TypeError('JSON input must be a string');
  }

  const errors = [];
  const root = parseTree(text, errors, {
    allowEmptyContent: false,
    allowTrailingComma: false,
    disallowComments: true
  });
  if (root === undefined || errors.length !== 0) {
    const detail = errors
      .map((error) => `${printParseErrorCode(error.error)} at offset ${error.offset}`)
      .join(', ');
    throw new Error(`Invalid strict JSON${detail.length === 0 ? '' : `: ${detail}`}`);
  }
  validateNode(root, text);
  return root;
}

function validateNode(node, text) {
  switch (node.type) {
    case 'object': {
      const names = new Set();
      for (const property of node.children ?? []) {
        if (property.type !== 'property' || property.children?.length !== 2) {
          throw new Error('Invalid JSON object property');
        }
        const nameNode = property.children[0];
        validateString(nameNode.value);
        if (names.has(nameNode.value)) {
          throw new Error(`Duplicate JSON object key: ${nameNode.value}`);
        }
        names.add(nameNode.value);
        validateNode(property.children[1], text);
      }
      return;
    }
    case 'array':
      for (const child of node.children ?? []) {
        validateNode(child, text);
      }
      return;
    case 'string':
      validateString(node.value);
      return;
    case 'number':
      exactInteger(text.slice(node.offset, node.offset + node.length));
      return;
    case 'boolean':
    case 'null':
      return;
    default:
      throw new Error(`Unsupported JSON node type: ${node.type}`);
  }
}

function validateString(value) {
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (index + 1 >= value.length) {
        throw new Error('JSON string contains an unpaired high surrogate');
      }
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) {
        throw new Error('JSON string contains an unpaired high surrogate');
      }
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      throw new Error('JSON string contains an unpaired low surrogate');
    }
  }
}

function exactInteger(source) {
  const match = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/.exec(source);
  if (match === null) {
    throw new Error('Invalid JSON number');
  }

  const negative = match[1] === '-';
  const fraction = match[3] ?? '';
  const coefficientDigits = `${match[2]}${fraction}`;
  let coefficient = BigInt(coefficientDigits);
  if (coefficient === 0n) {
    return 0n;
  }

  const exponent = BigInt(match[4] ?? '0');
  const shift = exponent - BigInt(fraction.length);
  if (shift >= 0n) {
    if (BigInt(coefficientDigits.length) + shift > 16n) {
      throw new Error('Trust metadata integer exceeds the shared safe range');
    }
    coefficient *= 10n ** shift;
  } else {
    const removedDigits = -shift;
    if (removedDigits > BigInt(coefficientDigits.length)) {
      throw new Error('Trust metadata only permits integral JSON numbers');
    }
    const divisor = 10n ** removedDigits;
    if (coefficient % divisor !== 0n) {
      throw new Error('Trust metadata only permits integral JSON numbers');
    }
    coefficient /= divisor;
  }

  const value = negative ? -coefficient : coefficient;
  if (value < -MAX_SAFE_INTEGER || value > MAX_SAFE_INTEGER) {
    throw new Error('Trust metadata integer exceeds the shared safe range');
  }
  return value;
}

function escapeString(value) {
  validateString(value);
  let output = '"';
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    switch (codeUnit) {
      case 0x22:
        output += '\\"';
        break;
      case 0x5c:
        output += '\\\\';
        break;
      case 0x08:
        output += '\\b';
        break;
      case 0x0c:
        output += '\\f';
        break;
      case 0x0a:
        output += '\\n';
        break;
      case 0x0d:
        output += '\\r';
        break;
      case 0x09:
        output += '\\t';
        break;
      default:
        if (codeUnit < 0x20) {
          output += `\\u${codeUnit.toString(16).padStart(4, '0')}`;
        } else {
          output += value[index];
          if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
            output += value[++index];
          }
        }
    }
  }
  return `${output}"`;
}

function canonicalizeNode(node, text) {
  switch (node.type) {
    case 'object': {
      const properties = [...(node.children ?? [])]
        .sort((left, right) => {
          const leftName = left.children[0].value;
          const rightName = right.children[0].value;
          return leftName < rightName ? -1 : leftName > rightName ? 1 : 0;
        });
      return `{${properties.map((property) => {
        const [name, value] = property.children;
        return `${escapeString(name.value)}:${canonicalizeNode(value, text)}`;
      }).join(',')}}`;
    }
    case 'array':
      return `[${(node.children ?? []).map((child) => canonicalizeNode(child, text)).join(',')}]`;
    case 'string':
      return escapeString(node.value);
    case 'number':
      return exactInteger(text.slice(node.offset, node.offset + node.length)).toString();
    case 'boolean':
      return node.value ? 'true' : 'false';
    case 'null':
      return 'null';
    default:
      throw new Error(`Unsupported JSON node type: ${node.type}`);
  }
}

export function parseStrictJson(text) {
  strictTree(text);
  return JSON.parse(text);
}

export function canonicalizeJsonText(text) {
  return Buffer.from(canonicalizeNode(strictTree(text), text), 'utf8');
}

export function signatureInput(text) {
  return Buffer.concat([
    Buffer.from(`${OFFICIAL_REGISTRY_DOMAIN}\n`, 'ascii'),
    canonicalizeJsonText(text)
  ]);
}

function requireExactKeys(value, expected, description) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${description} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const required = [...expected].sort();
  if (actual.length !== required.length || actual.some((key, index) => key !== required[index])) {
    throw new Error(`${description} has unsupported or missing fields`);
  }
}

function decodeBase64Strict(value, description) {
  if (typeof value !== 'string' || value.length === 0
      || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    throw new Error(`${description} is not canonical Base64`);
  }
  const decoded = Buffer.from(value, 'base64');
  if (decoded.toString('base64') !== value) {
    throw new Error(`${description} is not canonical Base64`);
  }
  return decoded;
}

function ed25519PublicDer(publicKey) {
  const key = Buffer.isBuffer(publicKey)
    ? createPublicKey({ key: publicKey, format: 'der', type: 'spki' })
    : publicKey;
  if (key?.asymmetricKeyType !== 'ed25519') {
    throw new Error('Public key must use Ed25519');
  }
  return key.export({ format: 'der', type: 'spki' });
}

export function keyId(publicKey) {
  const digest = createHash('sha256').update(ed25519PublicDer(publicKey)).digest('hex');
  return `ed25519:${digest}`;
}

function loadPrivateKey(privateKeyBase64) {
  const privateKey = createPrivateKey({
    key: decodeBase64Strict(privateKeyBase64, 'Private key'),
    format: 'der',
    type: 'pkcs8'
  });
  if (privateKey.asymmetricKeyType !== 'ed25519') {
    throw new Error('Private key must use Ed25519');
  }
  return privateKey;
}

export function createEnvelope(registryText, privateKeyBase64) {
  const signed = parseStrictJson(registryText);
  if (signed === null || typeof signed !== 'object' || Array.isArray(signed)) {
    throw new Error('Registry payload must be a JSON object');
  }
  const privateKey = loadPrivateKey(privateKeyBase64);
  const publicKey = createPublicKey(privateKey);
  const signature = signBytes(null, signatureInput(registryText), privateKey);
  return {
    signed,
    signatures: [{
      keyId: keyId(publicKey),
      signature: signature.toString('base64')
    }]
  };
}

function parseOfficialKeys(root) {
  requireExactKeys(root, ['signed', 'signatures'], 'Trust root envelope');
  if (!Array.isArray(root.signatures)) {
    throw new Error('Trust root signatures must be an array');
  }
  const signed = root.signed;
  if (signed === null || typeof signed !== 'object' || Array.isArray(signed)
      || signed._type !== 'root' || signed.schemaVersion !== 1
      || !Number.isSafeInteger(signed.version) || signed.version <= 0
      || typeof signed.expires !== 'string' || typeof signed.statusUrl !== 'string') {
    throw new Error('Unsupported trust root');
  }
  if (!Number.isFinite(Date.parse(signed.expires)) || Date.parse(signed.expires) <= Date.now()) {
    throw new Error('Trust root is expired or has an invalid expiry');
  }
  if (signed.keys === null || typeof signed.keys !== 'object' || Array.isArray(signed.keys)
      || signed.roles === null || typeof signed.roles !== 'object' || Array.isArray(signed.roles)) {
    throw new Error('Trust root keys and roles must be objects');
  }

  const role = signed.roles[OFFICIAL_REPOSITORY_ROLE];
  requireExactKeys(role, ['keyIds', 'threshold'], 'Official repository role');
  if (role.threshold !== 1 || !Array.isArray(role.keyIds) || role.keyIds.length === 0
      || new Set(role.keyIds).size !== role.keyIds.length
      || role.keyIds.some((id) => typeof id !== 'string')) {
    throw new Error('Official repository role must use unique keys at threshold one');
  }

  const keys = new Map();
  for (const id of role.keyIds) {
    const declaration = signed.keys[id];
    requireExactKeys(declaration, ['keyType', 'publicKey', 'scheme'], `Root key ${id}`);
    if (declaration.keyType !== 'ed25519' || declaration.scheme !== 'ed25519') {
      throw new Error('Official repository keys must use Ed25519');
    }
    const encoded = decodeBase64Strict(declaration.publicKey, `Root key ${id}`);
    const publicKey = createPublicKey({ key: encoded, format: 'der', type: 'spki' });
    if (publicKey.asymmetricKeyType !== 'ed25519' || keyId(publicKey) !== id) {
      throw new Error('Root key ID does not match its Ed25519 public key');
    }
    keys.set(id, publicKey);
  }
  return keys;
}

export function verifyEnvelope(envelopeText, rootText) {
  const envelope = parseStrictJson(envelopeText);
  const root = parseStrictJson(rootText);
  requireExactKeys(envelope, ['signed', 'signatures'], 'Registry envelope');
  if (envelope.signed === null || typeof envelope.signed !== 'object' || Array.isArray(envelope.signed)
      || !Array.isArray(envelope.signatures) || envelope.signatures.length !== 1) {
    throw new Error('Registry envelope must contain one signed object and one signature');
  }

  const keys = parseOfficialKeys(root);
  const declaration = envelope.signatures[0];
  requireExactKeys(declaration, ['keyId', 'signature'], 'Registry signature');
  if (typeof declaration.keyId !== 'string' || !keys.has(declaration.keyId)) {
    throw new Error('Registry signature key is not authorized');
  }
  const signature = decodeBase64Strict(declaration.signature, 'Registry signature');
  if (signature.length !== 64
      || !verifyBytes(
        null,
        signatureInput(JSON.stringify(envelope.signed)),
        keys.get(declaration.keyId),
        signature
      )) {
    throw new Error('Registry signature is invalid');
  }
  return envelope.signed;
}

function parseArguments(values) {
  const options = new Map();
  for (let index = 0; index < values.length; index += 2) {
    const name = values[index];
    const value = values[index + 1];
    if (typeof name !== 'string' || !name.startsWith('--') || value === undefined || options.has(name)) {
      throw new Error('CLI options must be unique --name value pairs');
    }
    options.set(name, value);
  }
  return options;
}

function requireOption(options, name) {
  const value = options.get(name);
  if (value === undefined || value.length === 0) {
    throw new Error(`Missing required option: ${name}`);
  }
  return value;
}

function requireOnlyOptions(options, allowed) {
  for (const option of options.keys()) {
    if (!allowed.has(option)) {
      throw new Error(`Unsupported option: ${option}`);
    }
  }
}

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8' });
}

function signingKeyFromEnvironment() {
  const direct = process.env.AURA_OFFICIAL_REGISTRY_SIGNING_KEY_PKCS8_BASE64?.trim();
  const file = process.env.AURA_OFFICIAL_REGISTRY_SIGNING_KEY_FILE;
  if ((direct === undefined) === (file === undefined)) {
    throw new Error('Set exactly one Store signing-key environment variable');
  }
  return direct ?? readFileSync(file, 'utf8').trim();
}

function runCli(command, rawOptions) {
  const options = parseArguments(rawOptions);
  switch (command) {
    case 'generate-key': {
      requireOnlyOptions(options, new Set(['--private-output', '--public-output']));
      const privateOutput = requireOption(options, '--private-output');
      const publicOutput = requireOption(options, '--public-output');
      const pair = generateKeyPairSync('ed25519');
      const publicDer = pair.publicKey.export({ format: 'der', type: 'spki' });
      writeFileSync(
        privateOutput,
        `${pair.privateKey.export({ format: 'der', type: 'pkcs8' }).toString('base64')}\n`,
        { encoding: 'ascii', flag: 'wx', mode: 0o600 }
      );
      writeJson(publicOutput, {
        keyId: keyId(pair.publicKey),
        keyType: 'ed25519',
        scheme: 'ed25519',
        publicKey: publicDer.toString('base64')
      });
      return;
    }
    case 'sign': {
      requireOnlyOptions(options, new Set(['--registry', '--output']));
      const registry = readFileSync(requireOption(options, '--registry'), 'utf8');
      writeJson(requireOption(options, '--output'), createEnvelope(registry, signingKeyFromEnvironment()));
      return;
    }
    case 'verify': {
      requireOnlyOptions(options, new Set(['--envelope', '--root']));
      verifyEnvelope(
        readFileSync(requireOption(options, '--envelope'), 'utf8'),
        readFileSync(requireOption(options, '--root'), 'utf8')
      );
      return;
    }
    case 'extract': {
      requireOnlyOptions(options, new Set(['--envelope', '--root', '--output']));
      const signed = verifyEnvelope(
        readFileSync(requireOption(options, '--envelope'), 'utf8'),
        readFileSync(requireOption(options, '--root'), 'utf8')
      );
      writeJson(requireOption(options, '--output'), signed);
      return;
    }
    default:
      throw new Error('Expected generate-key, sign, verify, or extract command');
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    runCli(process.argv[2], process.argv.slice(3));
  } catch (error) {
    process.stderr.write(`registry-envelope: ${error.message}\n`);
    process.exitCode = 1;
  }
}
