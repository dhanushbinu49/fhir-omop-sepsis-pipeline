-- OMOP OBSERVATION_PERIOD: one row per person, from their first record to their last.
-- Death counts as a record, so every death falls inside the period
-- (16 of the 31 deaths happen after the person's last hospital record).
-- When you build event tables with their own dates (drug_exposure, measurement, ...), add them to the union.
-- condition_occurrence uses visit dates, so the visits already cover it.
with dates as (
  select person_id, visit_start_date as start_date, visit_end_date as end_date
  from {{ ref('visit_occurrence') }}
  union all
  select person_id, visit_detail_start_date, visit_detail_end_date
  from {{ ref('visit_detail') }}
  union all
  select person_id, specimen_date, specimen_date
  from {{ ref('specimen') }}
  union all
  select person_id, death_date, death_date
  from {{ ref('death') }}
)

select
  person_id                   as observation_period_id,   -- one period per person, so reuse person_id
  person_id,
  min(start_date)             as observation_period_start_date,
  max(end_date)               as observation_period_end_date,
  32817                       as period_type_concept_id   -- EHR
from dates
group by person_id
