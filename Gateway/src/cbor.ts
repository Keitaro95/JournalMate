/**
 * 最小の CBOR デコーダ。
 *
 * App Attest の attestation / assertion を読むためだけに使う。
 * 出てくるのは整数・バイト列・文字列・配列・マップだけなので、
 * ライブラリを足さずに自前で持つ（依存が 1 つ減り、テストも offline で回る）。
 * 浮動小数・タグ・不定長は使われないので、出てきたら例外にする。
 */

interface Cursor {
  bytes: Uint8Array;
  view: DataView;
  offset: number;
}

export type CborValue =
  | number
  | string
  | Uint8Array
  | boolean
  | null
  | CborValue[]
  | { [key: string]: CborValue };

export function decodeCbor(bytes: Uint8Array): CborValue {
  const cursor: Cursor = {
    bytes,
    view: new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength),
    offset: 0,
  };
  const value = readValue(cursor);
  return value;
}

function readValue(cursor: Cursor): CborValue {
  const initial = readUint8(cursor);
  const major = initial >> 5;
  const minor = initial & 0x1f;

  switch (major) {
    case 0:
      return readLength(cursor, minor);
    case 1:
      return -1 - readLength(cursor, minor);
    case 2:
      return readBytes(cursor, readLength(cursor, minor));
    case 3:
      return new TextDecoder().decode(readBytes(cursor, readLength(cursor, minor)));
    case 4: {
      const count = readLength(cursor, minor);
      const items: CborValue[] = [];
      for (let i = 0; i < count; i++) items.push(readValue(cursor));
      return items;
    }
    case 5: {
      const count = readLength(cursor, minor);
      const map: { [key: string]: CborValue } = {};
      for (let i = 0; i < count; i++) {
        const key = readValue(cursor);
        if (typeof key !== "string" && typeof key !== "number") {
          throw new Error("cbor: 対応していないキーの型");
        }
        map[String(key)] = readValue(cursor);
      }
      return map;
    }
    case 7:
      if (minor === 20) return false;
      if (minor === 21) return true;
      if (minor === 22) return null;
      throw new Error(`cbor: 対応していない単純値 ${minor}`);
    default:
      throw new Error(`cbor: 対応していない major type ${major}`);
  }
}

function readLength(cursor: Cursor, minor: number): number {
  if (minor < 24) return minor;
  if (minor === 24) return readUint8(cursor);
  if (minor === 25) return readUint(cursor, 2);
  if (minor === 26) return readUint(cursor, 4);
  if (minor === 27) {
    const value = cursor.view.getBigUint64(cursor.offset);
    cursor.offset += 8;
    if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("cbor: 大きすぎる長さ");
    return Number(value);
  }
  throw new Error("cbor: 不定長には対応しない");
}

function readUint8(cursor: Cursor): number {
  if (cursor.offset >= cursor.bytes.length) throw new Error("cbor: 入力が途中で終わった");
  return cursor.bytes[cursor.offset++];
}

function readUint(cursor: Cursor, size: number): number {
  let value = 0;
  for (let i = 0; i < size; i++) value = value * 256 + readUint8(cursor);
  return value;
}

function readBytes(cursor: Cursor, length: number): Uint8Array {
  if (cursor.offset + length > cursor.bytes.length) {
    throw new Error("cbor: 入力が途中で終わった");
  }
  const slice = cursor.bytes.slice(cursor.offset, cursor.offset + length);
  cursor.offset += length;
  return slice;
}
