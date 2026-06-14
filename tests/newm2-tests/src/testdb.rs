//! Persistent test-run log backed by SQLite (bundled via rusqlite).
//!
//! Each `cargo test -p newm2-tests` process writes into one logical batch.
//! Queries such as `latest_batch_metrics` and `latest_batch_result` let us
//! inspect the latest run without grepping terminal logs.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use rusqlite::{Connection, OptionalExtension, params};

static DB_LOCK: Mutex<()> = Mutex::new(());
static CURRENT_BATCH_NO: Mutex<Option<i64>> = Mutex::new(None);

const EXPECTED_COLUMNS: &[&str] = &[
    "id",
    "batch_no",
    "run_ts",
    "test_id",
    "pass",
    "elapsed_ns",
    "note",
    "full_results",
];

#[derive(Debug, Clone)]
pub struct TestRun {
    pub test_id: String,
    pub pass: bool,
    pub elapsed_ns: u64,
    pub note: String,
    pub full_results: String,
}

#[derive(Debug, Clone)]
pub struct TestRunRow {
    pub id: i64,
    pub batch_no: i64,
    pub run_ts: String,
    pub test_id: String,
    pub pass: bool,
    pub elapsed_ns: u64,
    pub note: String,
    pub full_results: String,
}

#[derive(Debug, Clone)]
pub struct BatchMetrics {
    pub batch_no: i64,
    pub started_at: String,
    pub finished_at: String,
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    pub total_elapsed_ns: u64,
    pub avg_elapsed_ns: u64,
    pub median_elapsed_ns: u64,
    pub slowest_test_id: String,
    pub slowest_elapsed_ns: u64,
}

#[derive(Debug, Clone)]
pub struct BatchDelta {
    pub test_id: String,
    pub from_pass: Option<bool>,
    pub to_pass: Option<bool>,
    pub elapsed_ns_delta: Option<i128>,
}

#[derive(Debug, Clone)]
pub struct BatchComparison {
    pub from_batch: i64,
    pub to_batch: i64,
    pub only_in_from: Vec<String>,
    pub only_in_to: Vec<String>,
    pub changed: Vec<BatchDelta>,
    pub regressions: Vec<String>,
    pub fixes: Vec<String>,
}

pub struct TestDb {
    conn: Connection,
}

fn is_perf_test_id(test_id: &str) -> bool {
    test_id.starts_with("perf-")
}

impl TestDb {
    pub fn open_default() -> Result<Self, rusqlite::Error> {
        let path = db_path();
        Self::open(&path)
    }

    pub fn open(path: &std::path::Path) -> Result<Self, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        let conn = Connection::open(path)?;
        conn.busy_timeout(Duration::from_secs(5))?;
        ensure_schema(&conn)?;
        Ok(Self { conn })
    }

    pub fn append(&self, run: &TestRun) -> Result<i64, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        let batch_no = current_batch_no_locked(&self.conn)?;
        let ts = utc_now_iso8601();
        self.conn.execute(
            "INSERT INTO runs (batch_no, run_ts, test_id, pass, elapsed_ns, note, full_results)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                batch_no,
                ts,
                run.test_id,
                run.pass as i64,
                run.elapsed_ns as i64,
                run.note,
                run.full_results,
            ],
        )?;
        Ok(batch_no)
    }

    pub fn latest_batch_no(&self) -> Result<Option<i64>, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        latest_batch_no_locked(&self.conn)
    }

    pub fn latest_batch_result(&self, test_id: &str) -> Result<Option<TestRunRow>, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        let Some(batch_no) = latest_batch_no_locked(&self.conn)? else {
            return Ok(None);
        };
        self.result_for_batch_locked(batch_no, test_id)
    }

    pub fn batch_result(&self, batch_no: i64, test_id: &str) -> Result<Option<TestRunRow>, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        self.result_for_batch_locked(batch_no, test_id)
    }

    pub fn latest_batch_metrics(&self) -> Result<Option<BatchMetrics>, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        let Some(batch_no) = latest_batch_no_locked(&self.conn)? else {
            return Ok(None);
        };
        self.batch_metrics_locked(batch_no)
    }

    pub fn latest_batch_metrics_filtered(&self, perf_only: bool) -> Result<Option<BatchMetrics>, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        let Some(batch_no) = latest_batch_no_locked(&self.conn)? else {
            return Ok(None);
        };
        self.batch_metrics_filtered_locked(batch_no, perf_only)
    }

    pub fn batch_metrics(&self, batch_no: i64) -> Result<Option<BatchMetrics>, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        self.batch_metrics_locked(batch_no)
    }

    pub fn latest_batch_failures(&self) -> Result<Vec<String>, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        let Some(batch_no) = latest_batch_no_locked(&self.conn)? else {
            return Ok(Vec::new());
        };
        self.batch_failures_locked(batch_no)
    }

    pub fn latest_batch_failures_filtered(&self, perf_only: bool) -> Result<Vec<String>, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        let Some(batch_no) = latest_batch_no_locked(&self.conn)? else {
            return Ok(Vec::new());
        };
        self.batch_failures_filtered_locked(batch_no, perf_only)
    }

    pub fn batch_failures(&self, batch_no: i64) -> Result<Vec<String>, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        self.batch_failures_locked(batch_no)
    }

    pub fn compare_batches(&self, from_batch: i64, to_batch: i64) -> Result<BatchComparison, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        let from_rows = self.batch_rows_locked(from_batch)?;
        let to_rows = self.batch_rows_locked(to_batch)?;

        compare_batch_rows(from_batch, to_batch, from_rows, to_rows)
    }

    pub fn compare_batches_filtered(&self, from_batch: i64, to_batch: i64, perf_only: bool) -> Result<BatchComparison, rusqlite::Error> {
        let _guard = DB_LOCK.lock().unwrap();
        let from_rows = self.batch_rows_filtered_locked(from_batch, perf_only)?;
        let to_rows = self.batch_rows_filtered_locked(to_batch, perf_only)?;

        compare_batch_rows(from_batch, to_batch, from_rows, to_rows)
    }

    fn result_for_batch_locked(&self, batch_no: i64, test_id: &str) -> Result<Option<TestRunRow>, rusqlite::Error> {
        self.conn.query_row(
            "SELECT id, batch_no, run_ts, test_id, pass, elapsed_ns, note, full_results
             FROM runs
             WHERE batch_no = ?1 AND test_id = ?2
             ORDER BY id DESC
             LIMIT 1",
            params![batch_no, test_id],
            row_to_run,
        ).optional()
    }

    fn batch_metrics_locked(&self, batch_no: i64) -> Result<Option<BatchMetrics>, rusqlite::Error> {
        let rows = self.batch_rows_locked(batch_no)?;
        batch_metrics_from_rows(batch_no, rows)
    }

    fn batch_failures_locked(&self, batch_no: i64) -> Result<Vec<String>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT test_id
             FROM runs
             WHERE batch_no = ?1 AND pass = 0
             ORDER BY test_id ASC",
        )?;
        let rows = stmt.query_map(params![batch_no], |row| row.get::<_, String>(0))?;
        rows.collect()
    }

    fn batch_metrics_filtered_locked(&self, batch_no: i64, perf_only: bool) -> Result<Option<BatchMetrics>, rusqlite::Error> {
        let rows = self.batch_rows_filtered_locked(batch_no, perf_only)?;
        batch_metrics_from_rows(batch_no, rows)
    }

    fn batch_failures_filtered_locked(&self, batch_no: i64, perf_only: bool) -> Result<Vec<String>, rusqlite::Error> {
        let rows = self.batch_rows_filtered_locked(batch_no, perf_only)?;
        Ok(rows.into_iter().filter(|row| !row.pass).map(|row| row.test_id).collect())
    }

    fn batch_rows_locked(&self, batch_no: i64) -> Result<Vec<TestRunRow>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT id, batch_no, run_ts, test_id, pass, elapsed_ns, note, full_results
             FROM runs
             WHERE batch_no = ?1
             ORDER BY id ASC",
        )?;
        let rows = stmt.query_map(params![batch_no], row_to_run)?;
        rows.collect()
    }

    fn batch_rows_filtered_locked(&self, batch_no: i64, perf_only: bool) -> Result<Vec<TestRunRow>, rusqlite::Error> {
        let rows = self.batch_rows_locked(batch_no)?;
        if perf_only {
            Ok(rows.into_iter().filter(|row| is_perf_test_id(&row.test_id)).collect())
        } else {
            Ok(rows)
        }
    }
}

fn batch_metrics_from_rows(batch_no: i64, rows: Vec<TestRunRow>) -> Result<Option<BatchMetrics>, rusqlite::Error> {
    if rows.is_empty() {
        return Ok(None);
    }

    let total = rows.len();
    let passed = rows.iter().filter(|row| row.pass).count();
    let failed = total - passed;
    let total_elapsed_ns: u64 = rows.iter().map(|row| row.elapsed_ns).sum();
    let avg_elapsed_ns = total_elapsed_ns / total as u64;
    let mut times: Vec<u64> = rows.iter().map(|row| row.elapsed_ns).collect();
    times.sort_unstable();
    let median_elapsed_ns = times[times.len() / 2];
    let slowest = rows.iter().max_by_key(|row| row.elapsed_ns).unwrap();
    let started_at = rows.first().unwrap().run_ts.clone();
    let finished_at = rows.last().unwrap().run_ts.clone();

    Ok(Some(BatchMetrics {
        batch_no,
        started_at,
        finished_at,
        total,
        passed,
        failed,
        total_elapsed_ns,
        avg_elapsed_ns,
        median_elapsed_ns,
        slowest_test_id: slowest.test_id.clone(),
        slowest_elapsed_ns: slowest.elapsed_ns,
    }))
}

fn compare_batch_rows(
    from_batch: i64,
    to_batch: i64,
    from_rows: Vec<TestRunRow>,
    to_rows: Vec<TestRunRow>,
) -> Result<BatchComparison, rusqlite::Error> {
    let from_map: BTreeMap<String, TestRunRow> = from_rows
        .into_iter()
        .map(|row| (row.test_id.clone(), row))
        .collect();
    let to_map: BTreeMap<String, TestRunRow> = to_rows
        .into_iter()
        .map(|row| (row.test_id.clone(), row))
        .collect();

    let mut all_ids: BTreeSet<String> = BTreeSet::new();
    all_ids.extend(from_map.keys().cloned());
    all_ids.extend(to_map.keys().cloned());

    let mut only_in_from = Vec::new();
    let mut only_in_to = Vec::new();
    let mut changed = Vec::new();
    let mut regressions = Vec::new();
    let mut fixes = Vec::new();

    for test_id in all_ids {
        match (from_map.get(&test_id), to_map.get(&test_id)) {
            (Some(from), Some(to)) => {
                let elapsed_delta = Some(to.elapsed_ns as i128 - from.elapsed_ns as i128);
                if from.pass != to.pass || from.elapsed_ns != to.elapsed_ns {
                    changed.push(BatchDelta {
                        test_id: test_id.clone(),
                        from_pass: Some(from.pass),
                        to_pass: Some(to.pass),
                        elapsed_ns_delta: elapsed_delta,
                    });
                }
                if from.pass && !to.pass {
                    regressions.push(test_id.clone());
                }
                if !from.pass && to.pass {
                    fixes.push(test_id.clone());
                }
            }
            (Some(_), None) => only_in_from.push(test_id),
            (None, Some(_)) => only_in_to.push(test_id),
            (None, None) => {}
        }
    }

    Ok(BatchComparison {
        from_batch,
        to_batch,
        only_in_from,
        only_in_to,
        changed,
        regressions,
        fixes,
    })
}

fn row_to_run(row: &rusqlite::Row<'_>) -> Result<TestRunRow, rusqlite::Error> {
    Ok(TestRunRow {
        id: row.get(0)?,
        batch_no: row.get(1)?,
        run_ts: row.get(2)?,
        test_id: row.get(3)?,
        pass: row.get::<_, i64>(4)? != 0,
        elapsed_ns: row.get::<_, i64>(5)? as u64,
        note: row.get(6)?,
        full_results: row.get(7)?,
    })
}

fn current_batch_no_locked(conn: &Connection) -> Result<i64, rusqlite::Error> {
    let mut state = CURRENT_BATCH_NO.lock().unwrap();
    if let Some(batch_no) = *state {
        return Ok(batch_no);
    }
    let next_batch = latest_batch_no_locked(conn)?.unwrap_or(0) + 1;
    *state = Some(next_batch);
    Ok(next_batch)
}

fn latest_batch_no_locked(conn: &Connection) -> Result<Option<i64>, rusqlite::Error> {
    conn.query_row("SELECT MAX(batch_no) FROM runs", [], |row| row.get::<_, Option<i64>>(0)).optional().map(|opt| opt.flatten())
}

fn ensure_schema(conn: &Connection) -> Result<(), rusqlite::Error> {
    if table_exists(conn, "runs")? && !has_expected_schema(conn)? {
        conn.execute_batch(
            "DROP INDEX IF EXISTS idx_test_id;
             DROP INDEX IF EXISTS idx_runs_batch_no;
             DROP INDEX IF EXISTS idx_runs_batch_test;
             DROP TABLE IF EXISTS runs;",
        )?;
    }

    conn.execute_batch(
        "PRAGMA journal_mode=WAL;
         CREATE TABLE IF NOT EXISTS runs (
             id           INTEGER PRIMARY KEY AUTOINCREMENT,
             batch_no     INTEGER NOT NULL,
             run_ts       TEXT    NOT NULL,
             test_id      TEXT    NOT NULL,
             pass         INTEGER NOT NULL,
             elapsed_ns   INTEGER NOT NULL,
             note         TEXT    NOT NULL DEFAULT '',
             full_results TEXT    NOT NULL DEFAULT ''
         );
         CREATE INDEX IF NOT EXISTS idx_runs_batch_no ON runs(batch_no);
         CREATE INDEX IF NOT EXISTS idx_runs_batch_test ON runs(batch_no, test_id);
         CREATE INDEX IF NOT EXISTS idx_test_id ON runs(test_id);",
    )?;
    Ok(())
}

fn table_exists(conn: &Connection, table_name: &str) -> Result<bool, rusqlite::Error> {
    conn.query_row(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1",
        params![table_name],
        |_| Ok(true),
    )
    .optional()
    .map(|row| row.unwrap_or(false))
}

fn has_expected_schema(conn: &Connection) -> Result<bool, rusqlite::Error> {
    let mut stmt = conn.prepare("PRAGMA table_info(runs)")?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
    let columns: Vec<String> = rows.collect::<Result<_, _>>()?;
    Ok(columns == EXPECTED_COLUMNS)
}

fn db_path() -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .ancestors()
        .find(|p| p.join("Cargo.toml").is_file() && p.join("src").is_dir())
        .unwrap_or_else(|| manifest.as_path())
        .join("test-results.db")
}

fn utc_now_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let (y, mo, d, h, mi, s) = unix_to_ymd_hms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

fn unix_to_ymd_hms(secs: u64) -> (u64, u64, u64, u64, u64, u64) {
    let s = secs % 60;
    let min = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    let z = days + 719468;
    let era = z / 146097;
    let doe = z % 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mo <= 2 { y + 1 } else { y };
    (y, mo, d, h, min, s)
}
