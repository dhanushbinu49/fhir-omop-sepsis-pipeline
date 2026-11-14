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
  icu.encounter_id                  as visit_detail_source_value,
  0                                 as visit_detail_source_concept_id,
  0                                 as admitted_from_concept_id,
  icu.admit_source                  as admitted_from_source_value,
  icu.discharge_disposition         as discharged_to_source_value,
  0                                 as discharged_to_concept_id,
  lag(icu.mimic_id) over (
    partition by p.person_id
    order by icu.start_datetime, icu.mimic_id
  )                                 as preceding_visit_detail_id,
  cast(null as int64)               as parent_visit_detail_id,
  v.visit_occurrence_id
from {{ ref('stg_encounter') }} as icu
join {{ ref('person') }} as p
  on p.person_source_value = icu.patient_id
left join {{ ref('visit_occurrence') }} as v
  on v.visit_source_value = icu.parent_encounter_id
where icu.encounter_type = 'icu'
