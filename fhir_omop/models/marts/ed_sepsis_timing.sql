with ed_visits as (
	select
		visit_occurrence_id,
		person_id,
		visit_start_datetime as arrival_datetime,
		lead(visit_start_datetime) over(partition by person_id order by visit_start_datetime) as next_arrival_datetime
	from {{ ref('visit_occurrence') }}
	where visit_concept_id = 9203
),

-- 21602796 is ATC J01, the antibiotic class
antibiotic_concepts as (
	select
		descendant_concept_id
	from {{ source('vocab', 'concept_ancestor') }}
	where ancestor_concept_id = 21602796
),

antibiotic_doses as (
	select
		d.person_id,
		d.drug_exposure_start_datetime
	from {{ ref('drug_exposure') }} as d
	join antibiotic_concepts as a
		on a.descendant_concept_id = d.drug_concept_id
	-- the concept can't tell eye drops from IV, but the name can
	where lower(d.drug_source_value) not like '%ophth%'
		and lower(d.drug_source_value) not like '%oral liquid%'
		and lower(d.drug_source_value) not like 'neomycin%'
),

blood_cultures as (
	select
		person_id,
		specimen_datetime
	from {{ ref('specimen') }}
	where specimen_source_value = 'BLOOD CULTURE'
),

first_culture as (
	select
		v.visit_occurrence_id,
		min(c.specimen_datetime) as first_culture_datetime
	from ed_visits as v
	-- specimens have no visit and eMAR doses point at the hospital stay
	join blood_cultures as c
		on c.person_id = v.person_id
		and c.specimen_datetime >= v.arrival_datetime
		and c.specimen_datetime <= datetime_add(v.arrival_datetime, interval 24 hour)
		-- stop at the next arrival: one ED stay can be split into two visits
		and (v.next_arrival_datetime is null or c.specimen_datetime < v.next_arrival_datetime)
	group by v.visit_occurrence_id
),

first_antibiotic as (
	select
		v.visit_occurrence_id,
		min(a.drug_exposure_start_datetime) as first_antibiotic_datetime
	from ed_visits as v
	join antibiotic_doses as a
		on a.person_id = v.person_id
		and a.drug_exposure_start_datetime >= v.arrival_datetime
		and a.drug_exposure_start_datetime <= datetime_add(v.arrival_datetime, interval 24 hour)
		and (v.next_arrival_datetime is null or a.drug_exposure_start_datetime < v.next_arrival_datetime)
	group by v.visit_occurrence_id
),

timed as (
	select
		v.visit_occurrence_id,
		v.person_id,
		v.arrival_datetime,
		fc.first_culture_datetime,
		datetime_diff(fc.first_culture_datetime, v.arrival_datetime, minute) as minutes_to_culture,
		fa.first_antibiotic_datetime,
		datetime_diff(fa.first_antibiotic_datetime, v.arrival_datetime, minute) as minutes_to_antibiotic
	from ed_visits as v
	left join first_culture as fc
		on fc.visit_occurrence_id = v.visit_occurrence_id
	left join first_antibiotic as fa
		on fa.visit_occurrence_id = v.visit_occurrence_id
)

select
	*,
	first_culture_datetime is not null and first_antibiotic_datetime is not null as suspected_infection,
	first_culture_datetime < first_antibiotic_datetime as culture_before_antibiotic,
	minutes_to_antibiotic <= 60 as antibiotic_within_1h,
	minutes_to_antibiotic <= 180 as antibiotic_within_3h
from timed
