-- OMOP DRUG_EXPOSURE: one row per dose a patient got. 53,445 rows in the MIMIC demo.
-- Doses come from three record systems, and each one names the drug differently:
--   eMAR (doses scanned during a hospital stay)  stg_medication_administration, eMAR file   only a code: 'VANC1F'
--   ICU chart                                    stg_medication_administration, ICU file    '225798' + name 'Vancomycin'
--   ED cabinet (Pyxis)                           stg_medication_dispense, ED file           text 'Vancomycin'
-- So: give every dose a name (steps 2-3), then turn the name into a standard
-- RxNorm ingredient (steps 1 and 4). Vancomycin becomes 1707687, whichever system recorded it.

-- Step 1: the list of standard ingredients, by lowercase name ('vancomycin' -> 1707687). 14,642 rows.
with ingredients as (
	select
		concept_id,
		lower(concept_name) as name
	from {{ source('vocab', 'concept')  }}
	where vocabulary_id = 'RxNorm' AND
		concept_class_id = 'Ingredient' AND
		standard_concept = 'S' AND
		invalid_reason is NULL
),

-- Step 2: eMAR rows only carry the pharmacy's code, so look up its name ('VANC1F' -> 'Vancomycin').
-- One row per code (937). 85 codes have 2+ spellings ('TraZODone', 'traZODONE'); min() always picks the same one.
formulary_names as (
	select
		formulary_code,
		min(drug_name) as drug_name
	from
		{{ ref('stg_medication')  }}
	where formulary_code is not NULL
	group by formulary_code
),

-- Step 3: every dose from the three systems in one list, with the same 9 columns.
given as (
	-- 3a. eMAR and ICU doses: 52,363 rows (31,959 eMAR + 20,404 ICU)
	select
		a.medication_administration_id as source_id,
		a.patient_id,
		a.encounter_id,
		a.start_datetime,
		a.end_datetime,
		case
			when a.source_file = 'MimicMedicationAdministrationICU.ndjson.gz'
				then a.medication_display                -- ICU: '225798' -> 'Vancomycin'
			when ends_with(a.medication_code_system, 'formulary-drug-cd')
				then f.drug_name                         -- eMAR: 'VANC1F' -> 'Vancomycin' (557 rows: code not in the catalog, so NULL)
			else a.medication_code                       -- eMAR rows whose code is already the name: 'Insulin'
		end as drug_name,
		32818 as drug_type_concept_id,                   -- EHR administration record: the dose was given
		a.dose_value,
		a.dose_unit
	from {{ ref('stg_medication_administration') }} as a
	left join formulary_names as f
		on f.formulary_code = a.medication_code
	-- keep doses that were given. Drops 'Not Given' (166), 'Stopped' (44), 'Not Flushed' (11)
	-- and 3,951 rows with no method at all (notes and holds; most have no dose either)
	where a.method is not null
		and a.method not in ('Not Given', 'Not Flushed', 'Stopped')

	union all

	-- 3b. ED cabinet: 1,082 rows. MIMIC has no dose records for the ED, so the time the nurse
	-- took the drug out counts as the dose time. union all matches columns by position, so they
	-- come in the same order, and the three the cabinet doesn't record are NULLs with a type.
	select
		medication_dispense_id,
		patient_id,
		encounter_id,
		handed_over_datetime,
		cast(null as datetime),                          -- no end time
		medication_text,
		32825,                                           -- EHR dispensing record: taken from the cabinet
		cast(null as float64),                           -- no dose amount
		cast(null as string)                             -- no dose unit
	from {{ ref('stg_medication_dispense') }}
	where source_file = 'MimicMedicationDispenseED.ndjson.gz'   -- the other file is pharmacy deliveries, not doses
),

-- Step 4: name -> ingredient id. Try the whole name, then the first two words, then the first word.
-- coalesce keeps the first match, else 0 (16,033 rows: 'NaCl 0.9%', 'Dextrose 5%', 'HumaLOG', ...).
--   'Vancomycin'                   whole name         -> 1707687
--   'Sodium Chloride 0.9%  Flush'  'sodium chloride'  -> 967823 (tried before 'sodium' alone, 19136048)
--   'Piperacillin-Tazobactam'      'piperacillin'     -> 1746114 (one ingredient only: a version 1 limit)
-- Each name appears once in the ingredients list, so these joins never add rows.
mapped as (
	select
		g.*,
		coalesce(whole.concept_id, two.concept_id, one.concept_id, 0) as drug_concept_id
	from given as g
	left join ingredients as whole
		on whole.name = lower(trim(g.drug_name))
	left join ingredients as two
		on two.name = regexp_extract(lower(trim(g.drug_name)), r'^[a-z]+ [a-z]+')
	left join ingredients as one
		on one.name = regexp_extract(lower(trim(g.drug_name)), r'[a-z]+')
)

-- Step 5: add the person and the visit, in OMOP's column order.
-- Possible duplicates stay on purpose: a cabinet row (15:31) and an eMAR row (16:16) can be the
-- same dose, but nothing in the data links them. drug_type_concept_id tells the sources apart.
select
	row_number() over (order by m.source_id) as drug_exposure_id,
	p.person_id,
	m.drug_concept_id,
	date(m.start_datetime) as drug_exposure_start_date,
	m.start_datetime as drug_exposure_start_datetime,
	-- only some ICU rows have an end (11,038). OMOP requires one, so a single dose ends when it starts
	date(coalesce(m.end_datetime, m.start_datetime)) as drug_exposure_end_date,
	coalesce(m.end_datetime, m.start_datetime) as drug_exposure_end_datetime,
	cast(null as date) as verbatim_end_date,
	m.drug_type_concept_id,
	cast(null as string) as stop_reason,
	cast(null as int64) as refills,
	m.dose_value as quantity,
	cast(null as int64) as days_supply,
	cast(null as string) as sig,
	0 as route_concept_id,
	cast(null as string) as lot_number,
	cast(null as int64) as provider_id,
	-- the ED visit or hospital stay; an ICU row gets the hospital stay its ICU stay belongs to
	coalesce(vo.visit_occurrence_id, vd.visit_occurrence_id) as visit_occurrence_id,
	vd.visit_detail_id,
	m.drug_name as drug_source_value,
	0 as drug_source_concept_id,
	cast(null as string) as route_source_value,
	m.dose_unit as dose_unit_source_value
from mapped as m
-- the person comes from the patient, not the visit: 939 eMAR rows have no visit
join {{ ref('person') }} as p
	on p.person_source_value = m.patient_id
left join {{ ref('visit_occurrence') }} as vo
	on vo.visit_source_value = m.encounter_id
left join {{ ref('visit_detail') }} as vd
	on vd.visit_detail_source_value = m.encounter_id
