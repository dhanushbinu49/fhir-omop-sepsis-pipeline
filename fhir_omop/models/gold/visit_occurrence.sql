-- Encounter.class holds MIMIC's admission type, not the visit type
select
  e.mimic_id                        as visit_occurrence_id,
  p.person_id,
  case e.encounter_type
    when 'hospital' then 9201       -- Inpatient Visit
    when 'ed'       then 9203       -- Emergency Room Visit
  end                               as visit_concept_id,
  date(e.start_datetime)            as visit_start_date,
  e.start_datetime                  as visit_start_datetime,
  date(e.end_datetime)              as visit_end_date,
  e.end_datetime                    as visit_end_datetime,
  32817                             as visit_type_concept_id,       -- EHR
  cast(null as int64)               as provider_id,
  cast(null as int64)               as care_site_id,
  e.encounter_id                    as visit_source_value,
  0                                 as visit_source_concept_id,
  0                                 as admitted_from_concept_id,
  e.admit_source                    as admitted_from_source_value,
  0                                 as discharged_to_concept_id,
  e.discharge_disposition           as discharged_to_source_value,
  lag(e.mimic_id) over (
    partition by p.person_id
    order by e.start_datetime, e.mimic_id
  )                                 as preceding_visit_occurrence_id
from {{ ref('stg_encounter') }} as e
join {{ ref('person') }} as p
  on p.person_source_value = e.patient_id
where e.encounter_type in ('hospital', 'ed')
