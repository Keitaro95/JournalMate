import Foundation

/// スキーマ定義とマイグレーション。`user_version` を版数に使う。
enum Schema {

    static let latestVersion = 4

    static func migrate(_ db: SQLiteDatabase) throws {
        let current = try db.query("PRAGMA user_version") { Int($0.int(0)) }.first ?? 0
        guard current < latestVersion else { return }

        if current < 1 {
            try db.transaction { try createV1(db) }
        }
        if current < 2 {
            try db.transaction { try createV2(db) }
        }
        if current < 3 {
            try db.transaction { try createV3(db) }
        }
        if current < 4 {
            try db.transaction { try migrateV4(db) }
        }

        try db.execute("PRAGMA user_version = \(latestVersion)")
    }

    private static func createV1(_ db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE nodes (
              id          TEXT PRIMARY KEY,
              parent_id   TEXT REFERENCES nodes(id) ON DELETE CASCADE,
              para        TEXT    NOT NULL,
              seg         INTEGER NOT NULL,
              code        TEXT    NOT NULL,
              path        TEXT    NOT NULL,
              title       TEXT    NOT NULL,
              depth       INTEGER NOT NULL,
              sort_order  INTEGER NOT NULL DEFAULT 0,
              created_at  INTEGER NOT NULL,
              updated_at  INTEGER NOT NULL
            )
            """)
        try db.execute("CREATE INDEX nodes_parent ON nodes(parent_id, sort_order)")
        try db.execute("CREATE INDEX nodes_code ON nodes(code)")

        try db.execute("""
            CREATE TABLE notes (
              id           TEXT PRIMARY KEY,
              node_id      TEXT    NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
              layer        TEXT    NOT NULL,
              filename     TEXT    NOT NULL,
              title        TEXT    NOT NULL,
              body         TEXT    NOT NULL,
              source_url   TEXT,
              occurred_at  INTEGER NOT NULL,
              day_key      TEXT    NOT NULL,
              created_at   INTEGER NOT NULL,
              updated_at   INTEGER NOT NULL,
              deleted_at   INTEGER
            )
            """)
        try db.execute("CREATE INDEX notes_day ON notes(day_key, occurred_at)")
        try db.execute("CREATE INDEX notes_node ON notes(node_id, layer, occurred_at)")

        // 全文検索。external content にして本文の二重保存を避ける。
        // trigram トークナイザは日本語の部分一致に効く（既定の unicode61 は
        // CJK の連続を 1 トークンにまとめてしまい、実質検索できない）。
        try db.execute("""
            CREATE VIRTUAL TABLE notes_fts USING fts5(
              title, body,
              content='notes', content_rowid='rowid',
              tokenize='trigram'
            )
            """)
        try db.execute("""
            CREATE TRIGGER notes_fts_insert AFTER INSERT ON notes BEGIN
              INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
            END
            """)
        try db.execute("""
            CREATE TRIGGER notes_fts_delete AFTER DELETE ON notes BEGIN
              INSERT INTO notes_fts(notes_fts, rowid, title, body)
              VALUES ('delete', old.rowid, old.title, old.body);
            END
            """)
        try db.execute("""
            CREATE TRIGGER notes_fts_update AFTER UPDATE ON notes BEGIN
              INSERT INTO notes_fts(notes_fts, rowid, title, body)
              VALUES ('delete', old.rowid, old.title, old.body);
              INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
            END
            """)

        try db.execute("""
            CREATE TABLE messages (
              id          TEXT PRIMARY KEY,
              session_id  TEXT NOT NULL,
              role        TEXT NOT NULL,
              content     TEXT NOT NULL,
              note_id     TEXT REFERENCES notes(id) ON DELETE SET NULL,
              created_at  INTEGER NOT NULL
            )
            """)
        try db.execute("CREATE INDEX messages_session ON messages(session_id, created_at)")
    }

    /// 無料枠の消費数。暦月ごとに 1 行。
    ///
    /// `UserDefaults` ではなく DB に置く。再インストールで消えるのは構わないが、
    /// アプリの生存期間中に「月をまたいだか」を判断する基準（period）まで
    /// 一緒に持てる場所が要る。課金状態そのものは RevenueCat 側が正なので持たない。
    private static func createV2(_ db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE feature_usage (
              feature  TEXT    NOT NULL,
              period   TEXT    NOT NULL,       -- "2026-09"
              count    INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (feature, period)
            ) WITHOUT ROWID
            """)
    }

    /// 1 日ごとのトークン消費。回数（`feature_usage`）とは別の軸で、
    /// こちらは原価を見る。正はゲートウェイ側にあり、この表はその鏡。
    ///
    /// 数字は推測せず、Anthropic の応答の `usage` をそのまま積む。
    private static func createV3(_ db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE token_usage (
              day         TEXT    PRIMARY KEY,   -- "2026-09-23"（端末のローカル日）
              input       INTEGER NOT NULL DEFAULT 0,
              output      INTEGER NOT NULL DEFAULT 0,
              cache_read  INTEGER NOT NULL DEFAULT 0,
              requests    INTEGER NOT NULL DEFAULT 0,
              updated_at  INTEGER NOT NULL
            ) WITHOUT ROWID
            """)
    }

    /// PARA の前に「ふつうのジャーナル」（先頭桁 1）を置く。
    /// 既存の Projects 0 / Areas 1 / Resources 2 / Archives 3 を 2 / 3 / 4 / 5 にずらす。
    ///
    /// コードの先頭 1 文字が PARA の桁なので、そこだけ +2 する（"1152" → "3152"）。
    /// ノートのファイル名もコードで始まるので同じく振り直す。
    /// Journal のルート自体はここでは作らず、`Store` の起動時に足りないルートとして補う
    /// （新規の DB と同じ経路にするため）。
    private static func migrateV4(_ db: SQLiteDatabase) throws {
        try db.execute("""
            UPDATE nodes SET code = CAST(CAST(substr(code, 1, 1) AS INTEGER) + 2 AS TEXT) || substr(code, 2)
            WHERE para IN ('projects', 'areas', 'resources', 'archives')
            """)
        try db.execute("""
            UPDATE nodes SET seg = seg + 2, sort_order = sort_order + 1
            WHERE parent_id IS NULL AND para IN ('projects', 'areas', 'resources', 'archives')
            """)
        try db.execute("""
            UPDATE notes SET filename = CAST(CAST(substr(filename, 1, 1) AS INTEGER) + 2 AS TEXT) || substr(filename, 2)
            WHERE substr(filename, 1, 1) BETWEEN '0' AND '3'
            """)
    }
}
