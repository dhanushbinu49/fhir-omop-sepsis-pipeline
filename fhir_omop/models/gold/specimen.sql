-- OMOP SPECIMEN: one row per sample taken (blood, urine, ...). 12,413 in the MIMIC demo.
-- Comes from both FHIR files: MimicSpecimen (microbiology) and MimicSpecimenLab (lab tests).
-- specimen_id is MIMIC's own specimen id (no repeats across the two files).
-- OMOP needs a date, so the 45 specimens with no collection time are left out.
select
  s.mimic_id                                        as specimen_id,
  p.person_id,
  0                                                 as specimen_concept_id,         -- not mapped to a vocab concept yet
  32817                                             as specimen_type_concept_id,    -- EHR
  date(s.collected_datetime)                        as specimen_date,
  s.collected_datetime                              as specimen_datetime,
  cast(null as float64)                             as quantity,
  0                                                 as unit_concept_id,
  0                                                 as anatomic_site_concept_id,
  0                                                 as disease_status_concept_id,
  s.specimen_id                                     as specimen_source_id,          -- FHIR Specimen id, to trace back to silver
  coalesce(s.specimen_type, s.specimen_type_code)   as specimen_source_value,       -- 'BLOOD CULTURE' (micro) or 'Blood' (lab)
  cast(null as string)                              as unit_source_value,
  cast(null as string)                              as anatomic_site_source_value,
  cast(null as string)                              as disease_status_source_value
from {{ ref('stg_specimen') }} as s
join {{ ref('person') }} as p
  on p.person_source_value = s.patient_id
where s.collected_datetime is not null
