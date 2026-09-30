/**
 * セッショントークン（HS256 の JWT）。
 *
 * App Attest の検証は重いので毎回はやらない。1 度通したら 24 時間ぶんの
 * トークンを渡し、以後はその検証だけで通す。
 */

import { fromBase64Url, timingSafeEqual, toBase64Url, utf8 } from "./bytes";

export interface SessionClaims {
  /** RevenueCat の appUserID。 */
  sub: string;
  /** App Attest の keyId。端末を特定する。 */
  kid: string;
  exp: number;
  iat: number;
}

async function key(secret: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    utf8(secret) as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

export async function issue(
  claims: Omit<SessionClaims, "exp" | "iat">,
  secret: string,
  ttlSeconds: number,
  now = Date.now(),
): Promise<{ token: string; expiresAt: number }> {
  const issuedAt = Math.floor(now / 1000);
  const payload: SessionClaims = { ...claims, iat: issuedAt, exp: issuedAt + ttlSeconds };

  const header = toBase64Url(utf8(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = toBase64Url(utf8(JSON.stringify(payload)));
  const signing = `${header}.${body}`;

  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", await key(secret), utf8(signing) as BufferSource),
  );
  return { token: `${signing}.${toBase64Url(signature)}`, expiresAt: payload.exp };
}

/** 検証に失敗したら null。呼び出し側は理由を区別せず 401 にする。 */
export async function verify(
  token: string,
  secret: string,
  now = Date.now(),
): Promise<SessionClaims | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;

  const [header, body, signature] = parts;
  const expected = new Uint8Array(
    await crypto.subtle.sign("HMAC", await key(secret), utf8(`${header}.${body}`) as BufferSource),
  );
  if (!timingSafeEqual(expected, fromBase64Url(signature))) return null;

  try {
    const claims = JSON.parse(new TextDecoder().decode(fromBase64Url(body))) as SessionClaims;
    if (typeof claims.exp !== "number" || claims.exp * 1000 < now) return null;
    if (typeof claims.sub !== "string" || !claims.sub) return null;
    return claims;
  } catch {
    return null;
  }
}
