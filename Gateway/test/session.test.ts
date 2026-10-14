import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../src/attest", () => ({
  verifyAttestation: vi.fn(),
  verifyAssertion: vi.fn(),
}));

import { verifyAssertion, verifyAttestation } from "../src/attest";
import { toBase64 } from "../src/bytes";
import type { Env } from "../src/config";
import { makeChallenge, startSession } from "../src/session";

// 本物の attestation / assertion の検証は attest.ts の部品のテストに任せ、
// ここでは「どこで落ちたら何を返すか」と、KV の失敗を端末の確認の失敗と分けることを見る。

const SECRET = "test-secret";

function kv(initial: Record<string, string> = {}, failPut = false) {
  const data = new Map(Object.entries(initial));
  return {
    data,
    get: vi.fn(async (key: string, type?: string) => {
      const value = data.get(key);
      if (value === undefined) return null;
      return type === "json" ? JSON.parse(value) : value;
    }),
    put: vi.fn(async (key: string, value: string) => {
      if (failPut) throw new Error("KV put() limit exceeded for the day.");
      data.set(key, value);
    }),
  };
}

function env(cache: ReturnType<typeof kv>): Env {
  return {
    CACHE: cache as unknown as KVNamespace,
    SESSION_SECRET: SECRET,
    APP_ID: "TEAM.app.test",
    APPLE_ROOT_CA_PEM: "",
    ATTEST_MODE: "on",
  } as unknown as Env;
}

async function request(body: Record<string, string>): Promise<Request> {
  const challenge = await makeChallenge(SECRET);
  return new Request("https://example.test/v1/session", {
    method: "POST",
    body: JSON.stringify({ appUserId: "user-1", keyId: toBase64(new Uint8Array([1, 2, 3])), challenge, ...body }),
  });
}

const storedKey = (counter = 0, appUserId = "user-1") =>
  JSON.stringify({ publicKey: toBase64(new Uint8Array([9])), counter, appUserId });

describe("startSession", () => {
  beforeEach(() => {
    vi.mocked(verifyAttestation).mockReset();
    vi.mocked(verifyAssertion).mockReset();
  });

  it("初回: attestation が通れば鍵を保存してトークンを返す", async () => {
    vi.mocked(verifyAttestation).mockResolvedValue(new Uint8Array([7]));
    const cache = kv();
    const response = await startSession(await request({ attestation: "AA==" }), env(cache));

    expect(response.status).toBe(200);
    expect(((await response.json()) as { token: string }).token).toBeTruthy();
    expect(cache.put).toHaveBeenCalledOnce();
  });

  it("初回: attestation が弾かれたら 401 と stage=attestation。鍵は保存しない", async () => {
    vi.mocked(verifyAttestation).mockRejectedValue(new Error("nonce mismatch"));
    const cache = kv();
    const response = await startSession(await request({ attestation: "AA==" }), env(cache));

    expect(response.status).toBe(401);
    const body = (await response.json()) as { error: { stage: string; message: string } };
    expect(body.error.stage).toBe("attestation");
    expect(body.error.message).not.toContain("nonce");
    expect(cache.put).not.toHaveBeenCalled();
  });

  it("2 回目以降: assertion が弾かれたら 401 と stage=assertion", async () => {
    vi.mocked(verifyAssertion).mockRejectedValue(new Error("counter did not increase"));
    const keyId = toBase64(new Uint8Array([1, 2, 3]));
    const cache = kv({ [`key:${keyId}`]: storedKey(3) });
    const response = await startSession(await request({ assertion: "AA==" }), env(cache));

    expect(response.status).toBe(401);
    expect(((await response.json()) as { error: { stage: string } }).error.stage).toBe("assertion");
  });

  it("2 回目以降: assertion が通ればカウンタを進めて保存する", async () => {
    vi.mocked(verifyAssertion).mockResolvedValue(4);
    const keyId = toBase64(new Uint8Array([1, 2, 3]));
    const cache = kv({ [`key:${keyId}`]: storedKey(3) });
    const response = await startSession(await request({ assertion: "AA==" }), env(cache));

    expect(response.status).toBe(200);
    expect(JSON.parse(cache.data.get(`key:${keyId}`)!).counter).toBe(4);
  });

  it("KV に書けないときは 401 ではなく 503（アプリに鍵を捨てさせない）", async () => {
    vi.mocked(verifyAttestation).mockResolvedValue(new Uint8Array([7]));
    const response = await startSession(await request({ attestation: "AA==" }), env(kv({}, true)));

    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBeTruthy();
  });

  it("鍵が未登録なのに assertion を送ってきたら 400", async () => {
    const response = await startSession(await request({ assertion: "AA==" }), env(kv()));
    expect(response.status).toBe(400);
  });
});
