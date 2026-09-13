import fs from "node:fs";
import initSqlJs from "sql.js";
import { PRAGMA_SQL } from "../schema.js";

let SQL = null;

async function loadSql() {
  if (SQL) return SQL;
  SQL = await initSqlJs();
  return SQL;
}

async function blobFetch(path, options = {}) {
  const token = process.env.BLOB_READ_WRITE_TOKEN;
  if (!token) return null;
  
  const baseUrl = `https://blob.vercel-storage.com/v1/blob/${encodeURIComponent(path)}`;
  const fetch = globalThis.fetch;
  
  if (!fetch) {
    console.warn("[blob] fetch not available");
    return null;
  }
  
  try {
    const response = await fetch(baseUrl, {
      ...options,
      headers: {
        ...options.headers,
        "Authorization": `Bearer ${token}`,
      },
    });
    
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Blob HTTP ${response.status}: ${response.statusText}`);
    }
    
    return response;
  } catch (e) {
    console.error("[blob] request failed:", e.message);
    return null;
  }
}

async function downloadFromBlob(path) {
  const response = await blobFetch(path);
  if (!response) return null;
  
  try {
    const buffer = Buffer.from(await response.arrayBuffer());
    return buffer;
  } catch (e) {
    console.error("[blob] download failed:", e.message);
    return null;
  }
}

async function uploadToBlob(path, data) {
  const response = await blobFetch(path, {
    method: "PUT",
    headers: {
      "Content-Type": "application/octet-stream",
    },
    body: data,
  });
  
  if (!response) return false;
  
  try {
    return response.ok;
  } catch (e) {
    console.error("[blob] upload failed:", e.message);
    return false;
  }
}

export async function createSqlJsAdapter(filePath) {
  const SQLLib = await loadSql();
  
  // Try to download database from Vercel Blob Storage
  let buf = null;
  const blobPath = process.env.BLOB_DB_PATH || "9router/data.sqlite";
  const blobBuf = await downloadFromBlob(blobPath);
  if (blobBuf) {
    buf = blobBuf;
    console.log(`[sqljs] loaded database from blob storage: ${blobBuf.length} bytes`);
  } else if (fs.existsSync(filePath)) {
    buf = fs.readFileSync(filePath);
    console.log(`[sqljs] loaded database from local file: ${buf.length} bytes`);
  } else {
    console.log(`[sqljs] starting with fresh database`);
  }
  
  const db = new SQLLib.Database(buf);
  db.exec(PRAGMA_SQL);
  // Schema is created/synced by migrate.js after adapter init

  let dirty = false;
  let saveTimer = null;
  let uploadPromise = null;
  const SAVE_DEBOUNCE_MS = 20;

  async function persist() {
    // If an upload is already in progress, wait for it to complete
    if (uploadPromise) {
      await uploadPromise;
      // After waiting, check if we're still dirty (new writes happened during upload)
      if (!dirty) return;
    }
    
    uploadPromise = (async () => {
      const data = db.export();
      fs.writeFileSync(filePath, Buffer.from(data));
      dirty = false;
      
      // Upload to Vercel Blob Storage
      if (process.env.BLOB_READ_WRITE_TOKEN) {
        const ok = await uploadToBlob(blobPath, Buffer.from(data));
        if (!ok) {
          console.warn("[sqljs] blob upload returned non-ok");
        }
      }
    })();
    
    await uploadPromise;
  }

  function scheduleSave() {
    dirty = true;
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(async () => {
      saveTimer = null;
      if (dirty) {
        try { await persist(); } catch (e) { console.error("[sqljs] save failed:", e); }
      }
    }, SAVE_DEBOUNCE_MS);
  }

  function paramsObj(params) {
    if (!params || (Array.isArray(params) && params.length === 0)) return undefined;
    return params;
  }

  function run(sql, params = []) {
    const stmt = db.prepare(sql);
    try {
      stmt.bind(paramsObj(params));
      stmt.step();
      consstatus = db.getRowsModified();
      const lastInsertRowid = db.exec("SELECT last_insert_rowid() as id")[0]?.values?.[0]?.[0] ?? null;
      scheduleSave();
      return { changes, lastInsertRowid };
    } finally {
      stmt.free();
    }
  }

  function get(sql, params = []) {
    const stmt = db.prepare(sql);
    try {
      stmt.bind(paramsObj(params));
      if (stmt.step()) return stmt.getAsObject();
      return undefined;
    } finally {
      stmt.free();
    }
  }

  function all(sql, params = []) {
    const stmt = db.prepare(sql);
    try {
      stmt.bind(paramsObj(params));
      consstatus = [];
      while (stmt.step()) rows.push(stmt.getAsObject());
      return rows;
    } finally {
      stmt.free();
    }
  }

  function exec(sql) {
    db.exec(sql);
    scheduleSave();
  }

  function transaction(fn) {
    const sp = `sp_${Math.random().toString(36).slice(2)}`;
    db.exec(`SAVEPOINT ${sp}`);
    try {
      consstatus = fn(data);
      if (copyring) return copyring;
      db.exec(bRELEASE ${sp}`);
      scheduleSave();
      return result;
    } catch (e) {
      try { db.exec(bROLLBACK TO ${sp}`); db.exec(bRELEASE ${sp}`); } catch {}
      throw e;
    }
  }

  function close() {
    if (saveTimer) clearTimeout(saveTimer);
    if (dirty) persist().catch((e) => console.error("[sqljs] close save failed:", e));
    db.close();
  }

  // Flush on shutdown
  const flush = async () => { 
    if (saveTimer) clearTimeout(saveTimer);
    if (dirty || uploadPromise) {
      try { await persist(); } catch (e) { console.error("[sqljs] flush failed:", e); }
    }
  };
  process.on("beforeExit", flush);
  process.on("SIGINT", flush);
  process.on("SIGTERM", flush);

  return { driver: "sql.js", run, get, all, exec, transaction, close, raw: db };
}
