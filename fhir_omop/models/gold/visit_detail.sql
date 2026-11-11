-- OMOP VISIT_DETAIL: one row per ICU stay (140), linked to the hospital stay it was part of.
-- visit_detail_id is MIMIC's ICU stay_id.
select
  icu.mimic_id                      as visit_detail_id,
  p.person_id,
  32037                             as visit_detail_concept_id,       -- Intensive Care
  date(icu.start_datetime)          as visit_detail_start_date,
  icu.start_datetime                as visit_detail_start_datetime,
  date(icu.end_datetime)            as visit_detail_end_date,
  icu.end_datetime                  as visit_detail_end_datetime,
  32817                             as visit_detail_type_concept_id,  -- EHR
  cast(null as int64)               as provider_id,
  cast(null as int64)               as care_site_id,
  icu.encounter_id                  as visit_detail_source_value,     -- FHIR Encounter id, to trace back to silver
  0                                 as visit_detail_source_concept_id,
  0                                 as admitted_from_concept_id,
  icu.admit_source                  as admitted_from_source_value,    -- empty for ICU stays
  icu.discharge_disposition         as discharged_to_source_value,    -- empty for ICU stays
  0                                 as discharged_to_concept_id,
  -- the person's ICU stay just before this one (NULL for their first)
  lag(icu.mimic_id) over (
    partition by p.person_id
    order by icu.start_datetime, icu.mimic_id
  )                                 as preceding_visit_detail_id,
  cast(null as int64)               as parent_visit_detail_id,
  v.visit_occurrence_id                                               -- the hospital stay (from Encounter.partOf)
from {{ ref('stg_encounter') }} as icu
join {{ ref('person') }} as p
  on p.person_source_value = icu.patient_id
-- left join, so an ICU stay with no hospital stay fails the not_null test instead of silently disappearing
left join {{ ref('visit_occurrence') }} as v
  on v.visit_source_value = icu.parent_encounter_id
where icu.encounter_type = 'icu'
