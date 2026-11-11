-- OMOP VISIT_OCCURRENCE: one row per hospital stay (275) and per ED visit (222) = 497.
-- ICU stays are not visits of their own: they go in visit_detail, inside their hospital stay.
-- visit_occurrence_id is MIMIC's own id: hadm_id for hospital stays, stay_id for ED visits.
-- In this data they never clash: hadm_ids are 2xxxxxxx, ED stay_ids are 3xxxxxxx.
-- Every hospital stay is an Inpatient Visit. Don't use Encounter.class for this: it holds MIMIC's
-- admission type, e.g. 'AMB' (ambulatory) stays last 6.6 days on median, so they are not outpatient.
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
  e.encounter_id                    as visit_source_value,          -- FHIR Encounter id, to trace back to silver
  0                                 as visit_source_concept_id,
  0                                 as admitted_from_concept_id,
  e.admit_source                    as admitted_from_source_value,  -- 'EMERGENCY ROOM', 'AMBULANCE', ...
  0                                 as discharged_to_concept_id,
  e.discharge_disposition           as discharged_to_source_value,  -- 'HOME', 'DIED', 'ADMITTED', ...
  -- the person's visit just before this one (NULL for their first visit)
  lag(e.mimic_id) over (
    partition by p.person_id
    order by e.start_datetime, e.mimic_id
  )                                 as preceding_visit_occurrence_id
from {{ ref('stg_encounter') }} as e
join {{ ref('person') }} as p
  on p.person_source_value = e.patient_id
where e.encounter_type in ('hospital', 'ed')
