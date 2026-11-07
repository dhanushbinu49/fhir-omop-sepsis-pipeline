"""
Load the OMOP vocabulary files from Athena into BigQuery (dataset: vocab).

What this script does, in order:
  1. Compress each Athena CSV in data/vocab/ to .csv.gz (1.8 GB of text
     becomes about 300 MB, so there's 6x less to upload).
  2. Copy the .csv.gz files, unchanged, into the bucket under
     raw/athena-vocab/<release>/ (the raw layer, like the FHIR files).
  3. Make sure the BigQuery dataset `vocab` exists, in the same location as bronze.
  4. Load each file into its own table with a BigQuery load job that reads
     straight from the bucket. No rows pass through Python: these files
     already have fixed columns, so BigQuery can read them directly.
  5. Check that each table has as many rows as its file.

Run it from the repo folder, after unzipping the Athena download into data/vocab/:
  uv run ingest/load_vocab.py

Start with TABLES set to DRUG_STRENGTH alone. When that run ends with "Done.",
switch TABLES to all 9 tables and run it again.

Safe to rerun: finished .gz files and uploads are skipped, and each load
replaces its whole table. One file = one table, so WRITE_TRUNCATE is right
here (unlike bronze, where 30 files share one table).

If you download the same release again with different vocabularies ticked,
delete data/vocab_gz/<release>/ and the bucket folder first. Otherwise the
old files get reused (the row-count check at the end would catch it).
"""

import gzip
import shutil
from pathlib import Path

from google.cloud import bigquery, storage

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------

PROJECT_ID = "cloudcomputing-411615"
BUCKET = "healthcare_mimic_dataset_raw"
DATASET = "vocab"

REPO_ROOT = Path(__file__).resolve().parent.parent
VOCAB_DIR = REPO_ROOT / "data" / "vocab"  # where you unzipped the Athena download
GZ_DIR = REPO_ROOT / "data" / "vocab_gz"  # compressed copies, one folder per release (git ignores data/)

# Athena writes dates as 20240101; this tells BigQuery how to read them.
# If BigQuery ever rejects it, change the DATE columns below to STRING and
# convert them later with PARSE_DATE('%Y%m%d', column).
DATE_FORMAT = "YYYYMMDD"


def col(name: str, field_type: str, required: bool = False) -> bigquery.SchemaField:
    """One column. required=True means the load fails if any value is missing."""
    return bigquery.SchemaField(name, field_type, mode="REQUIRED" if required else "NULLABLE")


# The 9 OMOP CDM v5.4 vocabulary tables that Athena provides: file name -> columns, in file order.
# (The 10th, SOURCE_TO_CONCEPT_MAP, is for a hospital's own local codes, so Athena doesn't ship it.)
# Codes are STRING on purpose: auto-detect would read codes like 348.8 or
# 00002... as numbers and break them.
# Small tables come first, and DRUG_STRENGTH (small, has dates) early, so a
# date problem shows up fast.
SCHEMAS = {
    "VOCABULARY": [
        col("vocabulary_id", "STRING", True),
        col("vocabulary_name", "STRING", True),
        col("vocabulary_reference", "STRING"),
        col("vocabulary_version", "STRING"),
        col("vocabulary_concept_id", "INT64", True),
    ],
    "DOMAIN": [
        col("domain_id", "STRING", True),
        col("domain_name", "STRING", True),
        col("domain_concept_id", "INT64", True),
    ],
    "CONCEPT_CLASS": [
        col("concept_class_id", "STRING", True),
        col("concept_class_name", "STRING", True),
        col("concept_class_concept_id", "INT64", True),
    ],
    "RELATIONSHIP": [
        col("relationship_id", "STRING", True),
        col("relationship_name", "STRING", True),
        col("is_hierarchical", "STRING", True),
        col("defines_ancestry", "STRING", True),
        col("reverse_relationship_id", "STRING", True),
        col("relationship_concept_id", "INT64", True),
    ],
    "DRUG_STRENGTH": [
        col("drug_concept_id", "INT64", True),
        col("ingredient_concept_id", "INT64", True),
        col("amount_value", "FLOAT64"),
        col("amount_unit_concept_id", "INT64"),
        col("numerator_value", "FLOAT64"),
        col("numerator_unit_concept_id", "INT64"),
        col("denominator_value", "FLOAT64"),
        col("denominator_unit_concept_id", "INT64"),
        col("box_size", "INT64"),
        col("valid_start_date", "DATE", True),
        col("valid_end_date", "DATE", True),
        col("invalid_reason", "STRING"),
    ],
    "CONCEPT_SYNONYM": [
        col("concept_id", "INT64", True),
        col("concept_synonym_name", "STRING", True),
        col("language_concept_id", "INT64", True),
    ],
    "CONCEPT": [
        col("concept_id", "INT64", True),
        col("concept_name", "STRING", True),
        col("domain_id", "STRING", True),
        col("vocabulary_id", "STRING", True),
        col("concept_class_id", "STRING", True),
        col("standard_concept", "STRING"),  # 'S' = standard, 'C' = classification, empty = neither
        col("concept_code", "STRING", True),  # the code in its own system, e.g. '348.8'
        col("valid_start_date", "DATE", True),
        col("valid_end_date", "DATE", True),
        col("invalid_reason", "STRING"),  # empty = still valid
    ],
    "CONCEPT_RELATIONSHIP": [
        col("concept_id_1", "INT64", True),
        col("concept_id_2", "INT64", True),
        col("relationship_id", "STRING", True),  # e.g. 'Maps to'
        col("valid_start_date", "DATE", True),
        col("valid_end_date", "DATE", True),
        col("invalid_reason", "STRING"),
    ],
    "CONCEPT_ANCESTOR": [
        col("ancestor_concept_id", "INT64", True),
        col("descendant_concept_id", "INT64", True),
        col("min_levels_of_separation", "INT64", True),
        col("max_levels_of_separation", "INT64", True),
    ],
}
# Not loaded: CONCEPT_METADATA, CONCEPT_RELATIONSHIP_METADATA and PACK_CONTENT,
# Athena extras that aren't part of OMOP CDM v5.4.

# Which tables to load. Start with DRUG_STRENGTH alone: it's small and has
# dates, so within a minute you'll know whether DATE_FORMAT works.
# When that run ends with "Done.", change this to list(SCHEMAS) to load all 9.
TABLES = list(SCHEMAS)


# ----------------------------------------------------------------------------
# Step 0: which vocabulary release is this?
# ----------------------------------------------------------------------------

def read_release() -> str:
    """Return the vocabulary release, e.g. 'v5.0 29-AUG-26'.

    Athena records it in VOCABULARY.csv, on the row for the vocabulary
    called 'None'. Putting it in folder names keeps each release separate.
    """
    path = VOCAB_DIR / "VOCABULARY.csv"
    if not path.exists():
        raise FileNotFoundError(f"{path} is missing. Unzip the Athena download into {VOCAB_DIR}.")
    with open(path, encoding="utf-8") as f:
        for line in f:
            fields = line.rstrip("\n").split("\t")
            if fields[0] == "None":
                return fields[3]
    raise ValueError(f"No release found in {path}.")


# ----------------------------------------------------------------------------
# Step 1: compress the files
# ----------------------------------------------------------------------------

def compress_files(gz_dir: Path) -> dict[str, int]:
    """Compress each CSV in TABLES into gz_dir/<NAME>.csv.gz.

    Returns {NAME: number of data rows}, for the row-count check at the end.
    """
    gz_dir.mkdir(parents=True, exist_ok=True)
    rows = {}
    for name in TABLES:
        csv_path = VOCAB_DIR / f"{name}.csv"
        gz_path = gz_dir / f"{name}.csv.gz"
        if not csv_path.exists():
            raise FileNotFoundError(f"{csv_path} is missing. Unzip the Athena download into {VOCAB_DIR}.")

        with open(csv_path, "rb") as f:
            rows[name] = sum(1 for _ in f) - 1  # minus the header line

        if gz_path.exists():
            print(f"skip       {gz_path.name} (already compressed)")
            continue
        # Write under a temporary name and rename at the end, so a run that
        # stops halfway never leaves a broken .gz that looks finished.
        part = gz_path.with_name(gz_path.name + ".part")
        # Level 6 is the gzip tool's default. Python's default, 9, is much
        # slower for a file that's barely smaller.
        with open(csv_path, "rb") as src, gzip.open(part, "wb", compresslevel=6) as dst:
            shutil.copyfileobj(src, dst)
        part.replace(gz_path)
        print(f"compressed {gz_path.name} ({rows[name]:,} rows)")
    return rows


# ----------------------------------------------------------------------------
# Step 2: copy the compressed files into Cloud Storage (the raw layer)
# ----------------------------------------------------------------------------

def upload_raw(files: list[Path], prefix: str) -> None:
    """Upload each file, unchanged, to gs://BUCKET/<prefix><file name>. Skip files already there."""
    client = storage.Client(project=PROJECT_ID)
    bucket = client.bucket(BUCKET)
    for path in files:
        blob = bucket.blob(prefix + path.name)
        if blob.exists():
            print(f"skip       gs://{BUCKET}/{blob.name} (already there)")
            continue
        blob.upload_from_filename(path, content_type="application/gzip")
        print(f"uploaded   gs://{BUCKET}/{blob.name}")


# ----------------------------------------------------------------------------
# Step 3: make sure the dataset exists
# ----------------------------------------------------------------------------

def create_dataset(bq: bigquery.Client) -> None:
    """Create the vocab dataset where bronze is. Does nothing if it already exists.

    Why next to bronze? BigQuery can't join tables stored in different
    locations, and dbt will join these tables with data built from bronze.
    """
    location = bq.get_dataset(f"{PROJECT_ID}.bronze").location  # e.g. "us-central1" or "US"
    dataset = bigquery.Dataset(f"{PROJECT_ID}.{DATASET}")
    dataset.location = location
    dataset = bq.create_dataset(dataset, exists_ok=True)  # if it already exists, you get the existing one back
    if dataset.location != location:
        raise RuntimeError(
            f"{DATASET} is in {dataset.location} but bronze is in {location}. "
            f"Delete the {DATASET} dataset and run again."
        )
    print(f"dataset ready: {PROJECT_ID}.{DATASET} ({location})")


# ----------------------------------------------------------------------------
# Step 4: load each file into its own table
# ----------------------------------------------------------------------------

def load_table(bq: bigquery.Client, name: str, prefix: str) -> None:
    """Load gs://BUCKET/<prefix><NAME>.csv.gz into vocab.<name>, replacing the table."""
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        field_delimiter="\t",  # Athena files are tab-separated
        skip_leading_rows=1,  # the header line
        quote_character="",  # names contain " characters; don't treat them as quotes
        date_format=DATE_FORMAT,
        schema=SCHEMAS[name],
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,  # one file = one table: replace it
    )
    uri = f"gs://{BUCKET}/{prefix}{name}.csv.gz"  # BigQuery unzips .gz files itself
    table_id = f"{PROJECT_ID}.{DATASET}.{name.lower()}"
    bq.load_table_from_uri(uri, table_id, job_config=job_config).result()  # .result() waits, raises on error
    print(f"loaded     {table_id}")


# ----------------------------------------------------------------------------
# Step 5: check the counts
# ----------------------------------------------------------------------------

def check_counts(bq: bigquery.Client, expected: dict[str, int]) -> None:
    """Compare each table's row count with its file. Any mismatch raises an error."""
    mismatches = []
    for name, want in expected.items():
        got = bq.get_table(f"{PROJECT_ID}.{DATASET}.{name.lower()}").num_rows
        if got == want:
            print(f"OK         {name.lower()}: {got:,} rows")
        else:
            print(f"MISMATCH   {name.lower()}: file has {want:,}, BigQuery has {got:,}")
            mismatches.append(name)
    if mismatches:
        raise RuntimeError(f"Row counts don't match for: {', '.join(mismatches)}")


# ----------------------------------------------------------------------------
# Run all the steps
# ----------------------------------------------------------------------------

def main() -> None:
    release = read_release()  # e.g. "v5.0 29-AUG-26"
    slug = release.replace(" ", "_")  # "v5.0_29-AUG-26", safe in folder names
    print(f"vocabulary release: {release}")

    gz_dir = GZ_DIR / slug
    expected = compress_files(gz_dir)  # step 1

    prefix = f"raw/athena-vocab/{slug}/"
    upload_raw([gz_dir / f"{name}.csv.gz" for name in TABLES], prefix)  # step 2

    bq = bigquery.Client(project=PROJECT_ID)
    create_dataset(bq)  # step 3
    for name in TABLES:  # step 4
        load_table(bq, name, prefix)

    check_counts(bq, expected)  # step 5
    print("Done.")


# Runs main() only when you run this file directly (not when another file imports it).
if __name__ == "__main__":
    main()
