/**
 * App Attest の検証。**このサーバの唯一の入口の鍵**。
 *
 * これが無いと、エンドポイントを知った誰でもが他人の appUserID を名乗って
 * 呼べてしまう（appUserID はただの文字列で、認証ではない）。
 * App Attest は「本物のアプリのコピーから来た呼び出しか」を Apple の鍵で保証する。
 *
 * 手順は 2 段階:
 *   1. 初回だけ attestation を検証し、端末の公開鍵を保存する
 *   2. 以後は assertion（その鍵での署名）だけを検証する
 *
 * 参照: Apple「Validating Apps That Connect to Your Server」
 */

import { X509Certificate } from "@peculiar/x509";
import { concat, sha256, timingSafeEqual, utf8 } from "./bytes";
import { decodeCbor } from "./cbor";

/** 証明書に入っている nonce の場所（Apple の OID）。 */
const NONCE_OID = "1.2.840.113635.100.8.2";

const AAGUID_PRODUCTION = "appattest\0\0\0\0\0\0\0";
const AAGUID_DEVELOPMENT = "appattestdevelop";

export interface AuthenticatorData {
  rpIdHash: Uint8Array;
  counter: number;
  aaguid: string;
  credentialId: Uint8Array;
}

/** authData は固定長のヘッダ。attestation のときだけ後ろに鍵の情報が続く。 */
export function parseAuthenticatorData(data: Uint8Array): AuthenticatorData {
  if (data.length < 37) throw new Error("attest: authData が短すぎます");

  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const base: AuthenticatorData = {
    rpIdHash: data.slice(0, 32),
    counter: view.getUint32(33),
    aaguid: "",
    credentialId: new Uint8Array(0),
  };

  if (data.length >= 55) {
    base.aaguid = new TextDecoder().decode(data.slice(37, 53));
    const idLength = view.getUint16(53);
    base.credentialId = data.slice(55, 55 + idLength);
  }
  return base;
}

/**
 * ECDSA の署名を DER から raw（r||s）に直す。
 * App Attest は DER で返すが、WebCrypto は raw しか受け取らない。
 */
export function derToRawSignature(der: Uint8Array): Uint8Array {
  if (der[0] !== 0x30) throw new Error("attest: 署名が DER ではありません");

  let offset = 2;
  if (der[1] & 0x80) offset += der[1] & 0x7f; // 長い長さ表現

  const readInteger = (): Uint8Array => {
    if (der[offset] !== 0x02) throw new Error("attest: 署名の形が違います");
    const length = der[offset + 1];
    let value = der.slice(offset + 2, offset + 2 + length);
    offset += 2 + length;
    // 先頭の 0x00（符号用）を落とし、32 バイトに左詰めする。
    while (value.length > 32 && value[0] === 0x00) value = value.slice(1);
    const padded = new Uint8Array(32);
    padded.set(value, 32 - value.length);
    return padded;
  };

  const r = readInteger();
  const s = readInteger();
  return concat(r, s);
}

/** 証明書の拡張領域から 32 バイトの nonce を取り出す。 */
export function extractNonce(extensionValue: Uint8Array): Uint8Array {
  // 中身は SEQUENCE { [1] { OCTET STRING(32) } }。
  // 末尾 32 バイトの直前が必ず 0x04 0x20（OCTET STRING, 長さ 32）になる。
  const start = extensionValue.length - 32;
  if (start < 2 || extensionValue[start - 2] !== 0x04 || extensionValue[start - 1] !== 0x20) {
    throw new Error("attest: nonce を取り出せません");
  }
  return extensionValue.slice(start);
}

export interface AttestationInput {
  /** CBOR の attestation object。 */
  attestation: Uint8Array;
  /** アプリが送ってきた keyId（公開鍵の SHA-256）。 */
  keyId: Uint8Array;
  /** 署名の対象になった平文（assertion と同じ組み立て方にする）。 */
  clientData: Uint8Array;
  /** "<TeamID>.<BundleID>"。 */
  appId: string;
  /** Apple の App Attest ルート CA（PEM）。 */
  rootPem: string;
  now?: Date;
}

/**
 * 初回の検証。通れば、以後の assertion 検証に使う公開鍵（SPKI）を返す。
 */
export async function verifyAttestation(input: AttestationInput): Promise<Uint8Array> {
  const decoded = decodeCbor(input.attestation) as Record<string, unknown>;
  if (decoded.fmt !== "apple-appattest") throw new Error("attest: fmt が違います");

  const statement = decoded.attStmt as Record<string, unknown> | undefined;
  const chain = statement?.x5c as Uint8Array[] | undefined;
  const authData = decoded.authData as Uint8Array | undefined;
  if (!chain || chain.length < 2 || !authData) throw new Error("attest: 形が違います");

  // --- 1. 証明書の鎖を Apple のルートまで辿る ---
  const now = input.now ?? new Date();
  const leaf = new X509Certificate(chain[0] as unknown as BufferSource);
  const intermediate = new X509Certificate(chain[1] as unknown as BufferSource);
  const root = new X509Certificate(input.rootPem);

  for (const certificate of [leaf, intermediate, root]) {
    if (now < certificate.notBefore || now > certificate.notAfter) {
      throw new Error("attest: 証明書の有効期限外です");
    }
  }
  const okLeaf = await leaf.verify({ publicKey: intermediate.publicKey, signatureOnly: true });
  const okIntermediate = await intermediate.verify({
    publicKey: root.publicKey,
    signatureOnly: true,
  });
  if (!okLeaf || !okIntermediate) throw new Error("attest: 証明書の鎖が繋がりません");

  // --- 2. nonce が、こちらの出したチャレンジから作られていること ---
  const clientDataHash = await sha256(input.clientData);
  const expectedNonce = await sha256(concat(authData, clientDataHash));

  const extension = leaf.getExtension(NONCE_OID);
  if (!extension) throw new Error("attest: nonce の拡張がありません");
  if (!timingSafeEqual(expectedNonce, extractNonce(new Uint8Array(extension.value)))) {
    throw new Error("attest: nonce が一致しません");
  }

  // --- 3. keyId が、証明書の公開鍵から導かれていること ---
  const publicKey = await leaf.publicKey.export(
    { name: "ECDSA", namedCurve: "P-256" },
    ["verify"],
  );
  // exportKey("raw") は非圧縮点（0x04‖X‖Y）を返す。keyId はその SHA-256。
  const raw = new Uint8Array(
    (await crypto.subtle.exportKey("raw", publicKey)) as ArrayBuffer,
  );
  if (!timingSafeEqual(await sha256(raw), input.keyId)) {
    throw new Error("attest: keyId が一致しません");
  }

  // --- 4. authData が、このアプリのものであること ---
  const parsed = parseAuthenticatorData(authData);
  if (!timingSafeEqual(parsed.rpIdHash, await sha256(utf8(input.appId)))) {
    throw new Error("attest: アプリ ID が一致しません");
  }
  if (parsed.counter !== 0) throw new Error("attest: 初回のカウンタが 0 ではありません");
  if (parsed.aaguid !== AAGUID_PRODUCTION && parsed.aaguid !== AAGUID_DEVELOPMENT) {
    throw new Error("attest: aaguid が違います");
  }
  if (!timingSafeEqual(parsed.credentialId, input.keyId)) {
    throw new Error("attest: credentialId が keyId と違います");
  }

  return new Uint8Array(leaf.publicKey.rawData);
}

export interface AssertionInput {
  /** CBOR の assertion。 */
  assertion: Uint8Array;
  /** 署名の対象になった平文（アプリと同じ作り方で組み立てたもの）。 */
  clientData: Uint8Array;
  /** 保存してある公開鍵（SPKI）。 */
  publicKeySpki: Uint8Array;
  appId: string;
  /** 前回のカウンタ。必ず増えていなければならない（再生を防ぐ）。 */
  previousCounter: number;
}

/** 2 回目以降の検証。通れば新しいカウンタを返す。 */
export async function verifyAssertion(input: AssertionInput): Promise<number> {
  const decoded = decodeCbor(input.assertion) as Record<string, unknown>;
  const signature = decoded.signature as Uint8Array | undefined;
  const authenticatorData = decoded.authenticatorData as Uint8Array | undefined;
  if (!signature || !authenticatorData) throw new Error("attest: assertion の形が違います");

  const parsed = parseAuthenticatorData(authenticatorData);
  if (!timingSafeEqual(parsed.rpIdHash, await sha256(utf8(input.appId)))) {
    throw new Error("attest: アプリ ID が一致しません");
  }
  if (parsed.counter <= input.previousCounter) {
    throw new Error("attest: カウンタが進んでいません");
  }

  // 署名の対象は authenticatorData ‖ SHA256(clientData)。
  // ECDSA(SHA-256) がこれをハッシュするので、ここで先にハッシュしない
  // （nonce = SHA256(authenticatorData ‖ clientDataHash) を自分で作って渡すと二重になる）。
  const signed = concat(authenticatorData, await sha256(input.clientData));
  const key = await crypto.subtle.importKey(
    "spki",
    input.publicKeySpki as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    derToRawSignature(signature) as BufferSource,
    signed as BufferSource,
  );
  if (!valid) throw new Error("attest: 署名が検証できません");

  return parsed.counter;
}
