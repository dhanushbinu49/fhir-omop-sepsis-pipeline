"""
Load the MIMIC-IV FHIR demo into the bronze layer.

What this script does, in order:
  1. Download the NDJSON.gz files (one JSON record per line, gzip-compressed)
     from PhysioNet into data/raw/. The physionet library checks each file's
     SHA-256 fingerprint and skips files you already downloaded.
  2. Copy the files, unchanged, into the Cloud Storage bucket (the raw layer).
  3. Make sure the BigQuery table bronze.fhir_resources exists.
  4. Load each file into that table: one line of a file (one FHIR resource)
     becomes one row.
  5. Check that BigQuery has as many rows as the files had lines.

Run it from the repo folder:
  uv run ingest/ingest_fhir.py

Needs:
  - uv add physionet   (google-cloud-storage and google-cloud-bigquery are
    already in pyproject.toml)
  - gcloud auth application-default login   (already done; the Google
    libraries find those credentials on their own)

Start with FILES set to the one small Patient file. When a run ends with
"Done.", switch FILES to all 30 files and run it again.
"""

import gzip
import json
from datetime import datetime, timezone
from pathlib import Path

from google.cloud import bigquery, storage
from physionet.download import download, DownloadError

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------

PROJECT_ID = "cloudcomputing-411615"  # the project where you created the bronze dataset
BUCKET = "healthcare_mimic_dataset_raw"

DATASET_SLUG = "mimic-iv-fhir-demo"  # the dataset's name in its PhysioNet URL
VERSION = "2.1.0"

# Which files to download. Start with one small file (100 patients, 6 KB).
# When the whole script works, change it to ["fhir/*.ndjson.gz"] to get all 30.

FILES =  ["fhir/*.ndjson.gz"] # ["fhir/MimicPatient.ndjson.gz"] Just a small sample for initial load

REPO_ROOT = Path(__file__).resolve().parent.parent  # the repo folder, whichever folder you run from
LOCAL_DIR = REPO_ROOT / "data" / "raw"  # git ignores data/
GCS_PREFIX = f"raw/{DATASET_SLUG}/{VERSION}/"  # the "folder" inside the bucket (GCS = Google Cloud Storage)
TABLE_ID = f"{PROJECT_ID}.bronze.fhir_resources"  # project.dataset.table
BATCH_SIZE = 50_000  # rows per BigQuery load job (see load_file)

# The bronze table. "cluster by" makes BigQuery store rows with the same
# resource_type and source_file next to each other, so queries that filter on
# those columns read less data (faster and cheaper).
CREATE_TABLE_SQL = f"""
create table if not exists `{TABLE_ID}` (
  resource_type string,    -- e.g. 'Patient', 'Observation'
  resource_id   string,    -- the resource's "id" field
  resource      json,      -- the whole FHIR resource, untouched
  source_file   string,    -- e.g. 'MimicPatient.ndjson.gz'
  loaded_at     timestamp  -- when this script loaded the row
)
cluster by resource_type, source_file
"""

# The same 5 columns as the SQL above, with their types, so the load job
# knows what each column holds. Keep the two in sync.
SCHEMA = [
    bigquery.SchemaField("resource_type", "STRING"),
    bigquery.SchemaField("resource_id", "STRING"),
    bigquery.SchemaField("resource", "JSON"),
    bigquery.SchemaField("source_file", "STRING"),
    bigquery.SchemaField("loaded_at", "TIMESTAMP"),
]


# ----------------------------------------------------------------------------
# Step 1: download from PhysioNet
# ----------------------------------------------------------------------------

def download_files() -> list[Path]:
    """Download FILES from PhysioNet into LOCAL_DIR and return their local paths.

    The physionet library checks each file's SHA-256 fingerprint and skips
    files you already have, so running this again only downloads what's missing.
    """
    try:
        folder = download(
            DATASET_SLUG,
            version=VERSION,
            output_dir=LOCAL_DIR,
            include=FILES,
            source="physionet",  
        )
    except DownloadError as error:
        for path, cause in error.failures:
            print(f"{path}: {cause}")
        raise  

    # folder is data/raw/mimic-iv-fhir-demo-2.1.0/. Collect exactly the files
    # FILES asked for, so it matches what was downloaded.
    files = []
    for pattern in FILES:
        files.extend(folder.glob(pattern))
    files = sorted(files)  # a real list, because main() loops over it twice

    if not files:
        raise FileNotFoundError(f"No files matched {FILES} in {folder}. Check FILES for typos.")

    print(f"{len(files)} file(s) ready in {folder}")
    return files


# ----------------------------------------------------------------------------
# Step 2: copy the files into Cloud Storage (the raw layer)
# ----------------------------------------------------------------------------

def upload_raw(files: list[Path]) -> None:
    """Upload each file, unchanged, to gs://BUCKET/GCS_PREFIX<file name>.

    Files already in the bucket are skipped, so running this again is safe.
    Cloud Storage uploads are all-or-nothing: if a file is there, it's complete.

    Why keep a raw copy? If a later step has a bug, you rebuild from the bucket
    instead of downloading again, and every row can be traced back to a file.
    """
    client = storage.Client(project=PROJECT_ID)
    bucket = client.bucket(BUCKET)  # just a handle; nothing is sent to Google yet

    for path in files:
        blob = bucket.blob(GCS_PREFIX + path.name)  # a blob = one file in the bucket
        if blob.exists():
            print(f"skip      gs://{BUCKET}/{blob.name} (already there)")
            continue
        blob.upload_from_filename(path)
        print(f"uploaded  gs://{BUCKET}/{blob.name}")


# ----------------------------------------------------------------------------
# Step 3: make sure the table exists
# ----------------------------------------------------------------------------

def create_table(bq: bigquery.Client) -> None:
    """Run CREATE_TABLE_SQL. Safe on every run because of "if not exists".

    bq.query() only starts a job inside BigQuery; .result() waits for the job
    to finish and raises an error if it failed.
    """
    bq.query(CREATE_TABLE_SQL).result()
    print(f"table ready: {TABLE_ID}")


# ----------------------------------------------------------------------------
# Step 4: load the files into BigQuery
# (load_file is the main one; it calls the two helpers above it)
# ----------------------------------------------------------------------------

def delete_old_rows(bq: bigquery.Client, source_file: str) -> None:
    """Delete the rows an earlier run loaded from this file.

    Deleting before loading is what makes a rerun safe: the same file's rows
    can never end up in the table twice. On the first run there's nothing to
    delete, so it deletes 0 rows.
    """
    # The table name goes in with an f-string (it's your own setting). The file
    # name goes in as a query parameter (@source_file), never pasted into the SQL.
    sql = f"delete from `{TABLE_ID}` where source_file = @source_file"
    job_config = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("source_file", "STRING", source_file)]
    )
    job = bq.query(sql, job_config=job_config)
    job.result()  # wait for BigQuery to finish
    print(f"deleted   {job.num_dml_affected_rows} old row(s) of {source_file}")


def make_row(record: dict, source_file: str, loaded_at: str) -> dict:
    """Turn one FHIR resource (one line of a file) into one bronze row.

    A Patient line comes out like this:
        {"resource_type": "Patient",
         "resource_id": <the resource's id>,
         "resource": <the whole resource dict, as is>,
         "source_file": "MimicPatient.ndjson.gz",
         "loaded_at": "2026-11-05T23:30:00.123456+00:00"}
    """
    return {
        "resource_type": record["resourceType"],  # every FHIR resource has one
        "resource_id": record.get("id"),  # id is optional in FHIR: missing gives NULL, not a crash
        "resource": record,
        "source_file": source_file,
        "loaded_at": loaded_at,
    }


def load_file(bq: bigquery.Client, path: Path, loaded_at: str) -> int:
    """Load one .ndjson.gz file into the bronze table.
    Return how many resources (lines) the file had.

    Why batches? The biggest file has hundreds of thousands of lines. One job
    per line would take forever, and BigQuery allows only 1,500 load jobs per
    table per day. One job for the whole file would hold it all in memory.

    Why load_table_from_json and not insert_rows_json? Load jobs are free.
    insert_rows_json "streams" rows: it costs money, and BigQuery won't let you
    delete freshly streamed rows for a while, which breaks delete_old_rows().

    WRITE_APPEND adds rows. WRITE_TRUNCATE would wipe the whole table, the
    other files' rows included, so don't use it here.
    """
    delete_old_rows(bq, path.name)  # once, before the loop (inside it, each batch would delete the last)

    job_config = bigquery.LoadJobConfig(schema=SCHEMA, write_disposition="WRITE_APPEND")
    batch = []
    count = 0

    with gzip.open(path, "rt", encoding="utf-8") as f:  # "rt" = read as text, unzipping as it goes
        for line in f:
            if not line.strip():
                continue  # skip blank lines
            batch.append(make_row(json.loads(line), path.name, loaded_at))
            count += 1
            if len(batch) == BATCH_SIZE:  # batch is full: send it, start a new one
                bq.load_table_from_json(batch, TABLE_ID, job_config=job_config).result()
                batch = []

    if batch:  # send whatever is left
        bq.load_table_from_json(batch, TABLE_ID, job_config=job_config).result()

    print(f"loaded    {count} row(s) from {path.name}")
    return count


# ----------------------------------------------------------------------------
# Step 5: check the counts
# ----------------------------------------------------------------------------

def check_counts(bq: bigquery.Client, expected: dict[str, int]) -> None:
    """Compare the rows in BigQuery with the lines in each file.

    expected looks like {"MimicPatient.ndjson.gz": 100} (main() builds it).
    Any mismatch raises an error, so a bad load can't pass quietly.
    """
    sql = f"select source_file, count(*) as n from `{TABLE_ID}` group by source_file"
    actual = {row.source_file: row.n for row in bq.query(sql).result()}  # {file name: rows}

    mismatches = []
    for name, want in expected.items():
        got = actual.get(name, 0)  # 0 if BigQuery has no rows for this file
        if got == want:
            print(f"OK        {name}: {got} rows")
        else:
            print(f"MISMATCH  {name}: file has {want}, BigQuery has {got}")
            mismatches.append(name)

    if mismatches:
        raise RuntimeError(f"Row counts don't match for: {', '.join(mismatches)}")


# ----------------------------------------------------------------------------
# Run all the steps
# ----------------------------------------------------------------------------

def main() -> None:
    if PROJECT_ID == "your-project-id" or not SCHEMA:
        raise SystemExit("Step 0: fill in PROJECT_ID and SCHEMA at the top of this file.")

    files = download_files()  # step 1
    upload_raw(files)  # step 2

    bq = bigquery.Client(project=PROJECT_ID)
    create_table(bq)  # step 3

    loaded_at = datetime.now(timezone.utc).isoformat()  # one timestamp for the whole run
    expected = {}
    for path in files:  # step 4
        expected[path.name] = load_file(bq, path, loaded_at)

    check_counts(bq, expected)  # step 5
    print("Done.")


# Runs main() only when you run this file directly (not when another file imports it).
if __name__ == "__main__":
    main()
