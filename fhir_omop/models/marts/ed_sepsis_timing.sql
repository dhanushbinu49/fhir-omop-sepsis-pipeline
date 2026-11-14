-- Sepsis timing per ED visit: how fast the ED took a blood culture and gave an antibiotic.
-- Window: from arrival to 24 h later, ending early at the person's next ED arrival.

-- Step 1: ED visits (concept 9203), with arrival_datetime and next_arrival_datetime (lead). 222 rows.
with ed_visits as (
	select
		visit_occurrence_id,
		person_id,
		visit_start_datetime as arrival_datetime,
		lead(visit_start_datetime) over(partition by person_id order by visit_start_datetime) as next_arrival_datetime
	from {{ ref('visit_occurrence') }}
	where visit_concept_id = 9203
),

-- Step 2: concept_ancestor rows under ATC J01 (21602796), the antibiotic class. 6,301 rows.
antibiotic_concepts as (
	select
		descendant_concept_id
	from {{ source('vocab', 'concept_ancestor') }}
	where ancestor_concept_id = 21602796
),

-- Step 3: antibiotic drug_exposure rows, minus eye drops, oral vancomycin and neomycin. 2,425 rows.
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

-- Step 4: specimens labelled exactly 'BLOOD CULTURE'. 488 rows.
blood_cultures as (
	select
		person_id,
		specimen_datetime
	from {{ ref('specimen') }}
	where specimen_source_value = 'BLOOD CULTURE'
),

-- Step 5: first_culture_datetime per visit, inside the window. 93 rows.
first_culture as (
	select
		v.visit_occurrence_id,
		min(c.specimen_datetime) as first_culture_datetime
	from ed_visits as v
	-- by person and time: specimens have no visit, and eMAR doses point at the hospital stay
	join blood_cultures as c
		on c.person_id = v.person_id
		and c.specimen_datetime >= v.arrival_datetime
		and c.specimen_datetime <= datetime_add(v.arrival_datetime, interval 24 hour)
		-- keep the parentheses, or the "or" overrides the conditions above
		and (v.next_arrival_datetime is null or c.specimen_datetime < v.next_arrival_datetime)
	group by v.visit_occurrence_id
),

-- Step 6: first_antibiotic_datetime per visit, inside the window. 83 rows.
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

-- Step 7: every ED visit left joined to steps 5 and 6, plus minutes_to_culture and minutes_to_antibiotic. 222 rows.
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

-- Step 8: the 4 flags, in their own step because BigQuery can't reuse a column alias in the same select.
select
	*,
	first_culture_datetime is not null and first_antibiotic_datetime is not null as suspected_infection,
	first_culture_datetime < first_antibiotic_datetime as culture_before_antibiotic,
	minutes_to_antibiotic <= 60 as antibiotic_within_1h,
	minutes_to_antibiotic <= 180 as antibiotic_within_3h
from timed
