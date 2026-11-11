-- OMOP DEATH: one row per patient who died (31 in the MIMIC demo).
-- MIMIC only has the date of death, so death_datetime is midnight of that day.
select
  subject_id                as person_id,
  death_date,
  datetime(death_date)      as death_datetime,
  32817                     as death_type_concept_id,     -- EHR
  0                         as cause_concept_id,          -- cause of death isn't in the data
  cast(null as string)      as cause_source_value,
  0                         as cause_source_concept_id
from {{ ref('stg_patient') }}
where death_date is not null
