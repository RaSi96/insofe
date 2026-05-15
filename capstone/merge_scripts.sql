-------------------##### PART 0: COMPUTATIONAL SETUP #####---------------------
/* Postgres has multiprocessing capabilities that we should really be using for
 * a database of this size. Running on a CPU with 12 threads allows to dedicate
 * quite a decent amount of them for querying. In the backend, we also have the
 * modified configuration file for the PostgreSQL process itself stating it's
 * allowed to use 12GB of our system's 48GB of RAM.
 */
set max_parallel_workers_per_gather = 10;

-------------------------##### PART 1: RAW DATA #####--------------------------
/* we begin with some basic selects of our training data so that we have a
 * global view of all of the tables we have to work with. It's recommended to
 * run each of these in their own results tab. We're not designating any of our
 * tables' columns as UNIQUE because we have repeating data everywhere. We can
 * however leverage the utility of table indices. More on this later; also note
 * that PSQL isn't particularly concerned with capitalised querying, so we're
 * not either.
 */
select * from train_data;
select * from farm_data;
select * from weather_data;

/* how many farms do we actually have to deal with? do we have the same number
 * of farms across every table that has `farm_id`?
 */
select count(distinct td.farm_id)
from train_data td
union select count(distinct fd.farm_id)
from farm_data fd;

/* so we have the same unique number of farms across both data sets, but what
 * about their absolute sizes?
 */
select count(*) from farm_data;

/* farm_data has 1449 rows, while `train_data` has only 1434 unique farms; the
 * farm database is effectively a lookup dictionary. Since our train data only
 * has 1434 unique farms, we only need care about those particular ones for
 * calculating our yield. We can merge them together keeping only what we want
 * from `train_data` and disregard the rest. The inner subquery is the join we
 * want.
 */
select count(distinct foo.farm_id)
from (
	select
		td.date, td.farm_id, td.ingredient_type, td.yield,
		fd.operations_commencing_year, fd.farm_area, fd.farming_company,
		fd.deidentified_location
	from
		train_data td
		left join farm_data fd on td.farm_id = fd.farm_id
) as foo
where foo.farm_id = 'fid_88872';

/* an important thing to note is that joining on the basis of `farm_id` the two
 * tables simply duplicates the entries from `farm_data` across all occurrences
 * of a farm in `train_data`; i.e., if in `train_data` we have one farm appear
 * multiple times (like `fid_88872`) but the same farm only appears once in
 * `farm_data`, the join we did above will duplicate the single entry in `farm_
 * data` across all occurrences of `fid_88872` in `test_data`. Testing this
 * expectation was the reason why we had count() in the previous query along
 * with a very specific farm.
 * 
 * There is another important factor here: it appears that some farms appear
 * twice, sometimes with a different area and a different company owner. Can we
 * find all such instances of overlap?
 */
select fd.*
from farm_data fd
join (
	select farm_id
	from farm_data
	group by farm_id
	having count(farm_id) > 1
) as dup on dup.farm_id = fd.farm_id
order by farm_id asc;

/* great, looks like we only have 15 duplicate farms across geographies and
 * and corporate topology. But why are these different? Are they producing
 * different ingredients?
 */
select
	fd.farm_id, fd.farming_company, fd.deidentified_location,
	td.ingredient_type
from
	farm_data fd
	join (
		select farm_id
		from farm_data
		group by farm_id
		having count(farm_id) > 1
	) as dup on dup.farm_id = fd.farm_id
	join train_data td on fd.farm_id = td.farm_id
group by
	fd.farm_id, fd.farming_company, fd.deidentified_location,
	td.ingredient_type
order by fd.farm_id asc;

/* no, some farms produce different ingredients (3 out of 4 ingredients) while
 * some produce only one. Each one is also owned by a different company, i.e.
 * the farms that produce only a single ingredient don't all come under one
 * company. The current situation we have then is as follows:
 * Case 1 - same `farm_id` | different companies | different location
 * Case 2 - same `farm_id` | different companies | same location
 * Case 3 - same `farm_id` | same companies      | different location
 * 
 * We can deal with this in some different ways at a later stage. Now moving on
 * to incorporating our weather data, do we have the same number of locations
 * across both weather and farm tables? we should expect both to have 16.
 */
select count(distinct wd.deidentified_location)
from weather_data wd
union select count(distinct fd.deidentified_location)
from farm_data fd;

/* and we do, they both have 16 unique entries. Before merging them though, it
 * would behoove us to check out the timestamp as well.
 */
select "date"
from train_data
except select "timestamp"
from weather_data;

/* we have a perfect match. We can join on the basis of both location and time,
 * which means we should have a pretty nuclear and coherent set of data to work
 * with! Again, the inner subquery is the join we want to execute.
 */
select count(*)
from (
	select
		td."date", td.farm_id, td.ingredient_type, td.yield,
		fd.operations_commencing_year, fd.num_processing_plants, fd.farm_area,
		fd.farming_company, fd.deidentified_location,
		wd.temp_obs, wd.cloudiness, wd.wind_direction, wd.dew_temp,
		wd.pressure_sea_level, wd.precipitation, wd.wind_speed
	from
		train_data td
		left join farm_data fd on td.farm_id = fd.farm_id
		left join weather_data wd on
			td."date" = wd."timestamp" and
			wd.deidentified_location = fd.deidentified_location
	order by td."date"
) as foo;

/* let's just quickly verify we didn't misunderstand anything and that we have
 * the data we're expecting...
 */
select *
from weather_data
where deidentified_location = 'location 1784';

/* everything seems to be good, let's export this as its own table so that we
 * have an easier time manipulating all our relevant data from one resource. The
 * one change we need to make here is moving `yield` to the end of the table.
 */
create table if not exists grand_merge as
	select
		td."date", td.farm_id, td.ingredient_type,
		fd.operations_commencing_year, fd.num_processing_plants, fd.farm_area,
		fd.farming_company, fd.deidentified_location,
		wd.temp_obs, wd.cloudiness, wd.wind_direction, wd.dew_temp,
		wd.pressure_sea_level, wd.precipitation, wd.wind_speed,
		td.yield
	from
		train_data td
		left join farm_data fd on td.farm_id = fd.farm_id
		left join weather_data wd on
			td."date" = wd."timestamp" and
			wd.deidentified_location = fd.deidentified_location
	order by td.ingredient_type, td.farm_id, td."date";

----------------------##### PART 2: MERGE ANALYSIS #####-----------------------
select * from grand_merge;

/* now that we have a pretty tight yet large amount of data to sift through, we
 * should definitely make an index for easier and quicker querying. We can use
 * a multi-index to help us across all columns we might be querying a lot, which
 * in our case will most likely span a lot of our categorical columns.
 */
create index gm_multi_cat_index on grand_merge (
	farm_id,
	farming_company,
	deidentified_location
);

/* we have a ton of null values across columns for certain times of the day, so
 * let's try to get a read on that. A little theory before getting into it, it's
 * a well known fact that there are four main types of null values:
 * - structurally missing data
 * 		which is data that's missing because it logically should not exist. For
 * 		example, polling a family on the number of children they have followed
 * 		by asking them how many sodas their kids drink. If they do not have any
 * 		children, they won't answer how many sodas their kids drink - the latter
 * 		data is missing, but obviously it should be because it's precluded by
 * 		the former.
 * 
 * - missing completely at random (MCAR)
 * 		which is where data is missing in a way that's completely unrelated to
 * 		whatever data we do have. For example, missing weight data because the
 * 		scales ran out of battery; or missing blood data because the sample was
 * 		damaged in the lab. The missingness has nothing to do with what's being
 * 		studied, and is completely, truly random. Note that this can't be proved
 * 		directly and instead is only concluded once the other 3 types have been
 * 		ruled out.
 * 
 * - missing at random (MAR)
 * 		very stupidly named - before even defining this I will rename it to a
 * 		much more sensible "missing within reason (MWR)". MWR data is the most
 * 		common form of missingness; the missing values can be explained by other
 * 		existing values. For example, a weighing scale placed on a soft surface
 * 		can produce missing values - by itself the values are missing, but when
 * 		observed in conjunction with the material of the surface, they can be
 * 		inferred.
 * 
 * - missing not at random (MNAR)
 * 		again for some reason very stupidly named - I'll refer to this as
 * 		"missing systematically (MS)". This is the most difficult case to deal
 * 		with because it's non-standard; we cannot use any standard methods for
 * 		dealing with this data because any standard calculations would give the
 * 		wrong answer. The reason for the missingness is specifically related to
 * 		what is missing, for example a person does not attend a drug test
 * 		because the person took drugs the night before.
 * 
 * As a example of all 3 types being involved in the same data, foot ulcer data
 * might have missing capillary densities because the skin biopsy was unusable
 * (MCAR). Some readings were missing because the foot was amputated (MAR). But
 * a frequent reason for foot amputation is gangrene from severe foot ulcers
 * (MNAR). Deciding which kind of null values we have to deal with will greatly
 * help in determining our imputation strategy.
 */
select
	(select count(*) from grand_merge) as total_rows,
	(select count(*) from grand_merge where ingredient_type is null) as ing,
	(select count(*) from grand_merge where yield is null) as yield,
	(select count(*) from grand_merge where operations_commencing_year is null) as opsyr,
	(select count(*) from grand_merge where num_processing_plants is null) as nproc,
	(select count(*) from grand_merge where farm_area is null) as farea,
	(select count(*) from grand_merge where farming_company is null) as farmco,
	(select count(*) from grand_merge where deidentified_location is null) as deloc,
	(select count(*) from grand_merge where temp_obs is null) as "temp",
	(select count(*) from grand_merge where cloudiness is null) as cloud,
	(select count(*) from grand_merge where wind_direction is null) as winddir,
	(select count(*) from grand_merge where dew_temp is null) as dewpt,
	(select count(*) from grand_merge where pressure_sea_level is null) as psl,
	(select count(*) from grand_merge where precipitation is null) as precip,
	(select count(*) from grand_merge where wind_speed is null) as windspd;

/* All of our (relevant) nulls only exist across climactic measurements, which
 * somewhat narrows down our decision surface. With regards to the type of
 * missingness we're dealing with, our climactic measurements could be missing
 * due to the sensor malfunctioning in which case we have data that is MCAR.
 * This would also result in very long sequences of missing data, which is what
 * we have for `cloudiness` but not so much the other measurements. Taking a
 * cursory look at how cloudiness is measured, it is the fraction of the sky
 * that's covered by clouds on average when observed from a particular area,
 * usually measured by LIDAR or sometimes Pyranometers. Let's go with LIDAR
 * first: it could so happen that the response beam is never received by the
 * sensor simply because it's lost to atmospheric scattering, or it never
 * actually reflects off a cloud. This would MCAR, because it's out of our
 * control. Pyranometers depend on the cosine similarity of their response beam
 * in relation to their projected beam to determine solar irradiance; though
 * their range of measurements only lie within -1 to 1, they too are prone to
 * malfunctions.
 * 
 * However, notice that we do have cloud measurements for certain times of the
 * day, and associated yields too, along with measurements for all other kinds
 * of weather phenomenon. This lends strong credence to the fact that our
 * weather data is missing within reason (MWR) because we can, in fact, infer
 * what the missing values would be given some linear combination of weather
 * vectors in relation to yield; moreso with a Bayesian angle. This type of
 * regression is one approach.
 * 
 * Another approach we can take is based on a very effective reason, which is
 * expecting the climate across one location to be relatively stable; i.e. all
 * farms reporting from a single location should all report similar weather
 * patterns. One way we can verify this line of reasoning is by looking at the
 * number of distinct weather values reported from each location, especially in
 * relation to the total number of reports we have from that location. For the
 * weather across a particular geography to remain stable, we should see very,
 * very small variability in the amount of reported values.
 * 
 * In other words, temperature across one farm in one location, for one day, can
 * exist only within a certain range (say, 0 to 50 degrees Celsius), giving us
 * 50 unique possible integral reports. Larger farms can be expected to have
 * more of a temperature differential across their surfaces owing to their area,
 * and we can have more than 50 unique reports because (a) modern temperature
 * sensors don't report in only integers, and (b) we also are taking granular
 * measurements per hour. Let's assume we get around 100 unique values during a
 * day for one farm in one location. If we had multiple farms in one location,
 * we could expect some values greater than only 100 owing to the 2 reasons (a,
 * b) we mentioned earlier (maybe 150 or 175 reports, give or take). Obviously,
 * the lower number of unique values for temperature (or any other climactic
 * aspect) we have, the lower is the variability and the better for us.
 * 
 * A couple of extra points to add onto this currently distilled and clean
 * mental model: (1) we have other measurements that also represent temperature
 * in a different form, like the dew point. It's not entirely incorrect to
 * expect the same behaviour from this climactic measurement; (2) we're not
 * measuring only temperature, we're also measuring other arguably more chaotic
 * weather patterns like wind direction and speed, sea level pressure and level
 * of precipitation. Wind and precipitation patterns could arguably be labelled
 * as more macro events than local temperature measurements since wind and
 * precipitation affect areas larger than a single farm, meaning we perhaps
 * could expect a little less variability across geographies with respect to
 * these aspects; pressure however might be the most chaotic and therefore the
 * most variable.
 */
select
	distinct gm.deidentified_location  as "loc",
	count(*) as "c_total",
	count(distinct gm.temp_obs) as "d_temp",
	count(distinct gm.cloudiness) as "d_cloud",
	count(distinct gm.wind_direction) as "d_wdir",
	count(distinct gm.dew_temp) as "d_dew",
	count(distinct gm.pressure_sea_level) as "d_psl",
	count(distinct gm.precipitation) as "d_precip",
	count(distinct gm.wind_speed) as "d_wspd"
from grand_merge gm
group by gm.deidentified_location;

/* we clearly see very low amounts of variability across geographies in terms of
 * climate. The only region with the most variability is `location 868`, with an
 * average of 0.24% (max 0.45%, min 0%) distinct values out of its total number
 * of records (119,459). It would also benefit us greatly if we combined the two
 * approaches: first reasoning that we shouldn't (and don't) have much climactic
 * variation across different locations, then attempting an involved imputation
 * approach for our missing variables per location. To get a better read on how
 * might we divide and conquer this issue, let's also see how many farms we have
 * per ingredient and location (note that this includes duplicated entries since
 * some farms are reportedly shared acrross geographies! More on this in another
 * section later.)
 */
select ingredient_type, deidentified_location, count(distinct farm_id)
from grand_merge
group by deidentified_location, ingredient_type
order by ingredient_type, "count" desc;

/* and just for completeness let's also see how many farms we have per location
 * in total (again, this will include duplicate farms.)
 */
select deidentified_location, count(distinct farm_id) as "n_farms"
from grand_merge
group by deidentified_location
order by "n_farms" desc;

/* That's a pretty decent breakdown; we also caught a glimpse of why `location
 * 868` potentially has the most variability: there are only a few active farms
 * reporting from there (5). What we can do now is first try to impute our nulls
 * by accounting for feature interactions and retrieving values based on some
 * linear combination of features. One appropriate algorithm is expectation-
 * maximisation either through Bayesian regression or SVD. If for any reason
 * these don't work, we can simply choose to linearly interpolate some features
 * while carrying the last/next observed value forward/backward for others (more
 * on this in <insert favourite language here>). We'll be breaking down this
 * problem per location. Now, there is another important check we haven't done
 * yet: do we have missing dates? First we'll do a global check.
 */
select *
from
	generate_series(
		'2016-01-01 00:00:00'::timestamp,
		'2016-12-31 00:00:00',
		INTERVAL '1 hour'
	) as series
except select gm."date"
from grand_merge gm;

/* so it appears as though we don't have any gaps as far as our entire dataset
 * goes because we can't get any dates from the generated series that aren't in
 * the table. But what about at a farm-specific local level? Surely we might
 * have some there...
 */
select
	farm_id,
	min(date) as mindate,
	max(date) as maxdate,
	count(distinct date) obs_dates,
	(extract(epoch from max(date) - min(date)) / 3600)::integer as exp_dates,
	(count(distinct date) - (extract(epoch from max(date) - min(date)) / 3600)::integer) as diff
from (
	select
	gm.farm_id, gm."date",
      row_number() over (partition by farm_id order by date)
      from
      grand_merge gm
) as parted
group by farm_id
order by diff asc;

/* astounding...does one farm really not have ~7000 temporal records?
 */
select count(*) from (
	select *
	from generate_series(
		'2016-01-01 00:00:00'::timestamp,
		'2016-12-31 00:00:00',
		INTERVAL '1 hour'
	) as series except
	select gm."date"
	from grand_merge gm
	where farm_id = 'fid_73322'
) q;

/* that's bizzare. We'll get back to this problem later, for now there's
 * something else we can look at: some of our companies might be cornering the
 * market, in which case we can actually greatly reduce the number of factors
 * in the categorical feature so that only the major players remain, while all
 * the others get mapped to a category like "minor companies" or so.
 */
select
	farming_company,
	count(*) as num_branches,
	100 * count(*) / sum(count(*)) over () as mkt_share_percent
from grand_merge
group by farming_company
order by num_branches desc;

/* yup, 5 companies control 91% of the market - it's an oligopoly! We can club
 * the relatively minor companies into one group named "other" based on this
 * market share distribution. This way, when we're one-hot encoding our factors
 * it will make it much easier on the feature space. We'll also separate the
 * timestamp into separate columns for date and time so that manipulating the
 * formats in <insert favourite language here> is relatively easier, and we'll
 * also move our target `yield` column to the end of the table as per custom
 * (predictors first, target last). Given the kind of transaction we're
 * performing, it would behoove us to do it atomically.
 */
begin;
	savepoint sp1;

	--first get our subquery in order
	select farming_company from (
		select
			farming_company,
			100*count(*) / sum(count(*)) over() as mshare
		from grand_merge group by farming_company
	) as m where m.mshare < 5;

	--all good, now we can apply it
	update grand_merge
	set farming_company = 'Other'
	where farming_company in (
		select farming_company from (
			select
				farming_company,
				100*count(*) / sum(count(*)) over() as "share"
			from grand_merge
			group by farming_company
		) as m where m."share" < 5
	);

	--quick checks to make sure we did everything right...
	select * from grand_merge;

	select distinct farming_company from grand_merge;
commit;

/* before moving on, let's refresh the statistics we have on our merged table
 * since we just performed a decent amount of updation on it.
 */
analyze verbose grand_merge;

-----------------------##### PART 3: DE-DUPLICATION #####----------------------
select * from grand_merge;

/* Let's address the problem we have of duplicated farms. The objective here is
 * to reduce the number of farm IDs we have down to one and only one, such that
 * each farm ID is unique and refers to a specific arrangement of corporate
 * topology, geographic layout, climate, and finally yield. To this end, let's
 * begin by checking how many farms, post-merge, are duplicated by company or
 * location? We already ran a similar query before on `farm_data`, but we need
 * to be sure we don't have any new artefacts after the big merge; we also would
 * be better off with a granular inspection by ingredient.
 */
--global duplicates
select * from grand_merge where farm_id in (
	select farm_id from farm_data
	group by farm_id having count(farm_id) > 1		
) order by farm_id, "date";

--ingredient w
select * from grand_merge where farm_id in (
	select farm_id from farm_data
	group by farm_id having count(farm_id) > 1		
) and ingredient_type = 'ing_w'
order by farm_id, "date";

--ingredient x
select * from grand_merge where farm_id in (
	select farm_id from farm_data
	group by farm_id having count(farm_id) > 1		
) and ingredient_type = 'ing_x'
order by farm_id, "date";

--ingredient y
select * from grand_merge where farm_id in (
	select farm_id from farm_data
	group by farm_id having count(farm_id) > 1		
) and ingredient_type = 'ing_y'
order by farm_id, "date";

--ingredient z
select * from grand_merge where farm_id in (
	select farm_id from farm_data
	group by farm_id having count(farm_id) > 1		
) and ingredient_type = 'ing_z'
order by farm_id, "date";

/* We still have the same 15 farms as duplicates. Inspecting these results
 * further shows us something interesting and nuanced, in relation to the three
 * cases we identified earlier: first of all in addition to each farm reporting
 * twice when viewed with respect to its owners and locations, some duplicated
 * farms also report twice per company implying that one farm (from the pool of
 * duplicates) is reporting 4 times, twice for each company for whatever reason
 * (i.e. there are 4 timestamps for that one farm). But that's not all:
 * 
 * A) for farms with the same `farm_id` but different companies and locations,
 * when reporting 4 times, the 2 reports from the same company will have the
 * exact same weather readings but different yields. When reporting only twice,
 * both companies will report different weather measurements but exactly the
 * same yield. For example, `fid_53126` reports 4 timestamps even though its
 * owned by 2 companies across 2 different locations; a pair of timestamps from
 * one company (and therefore location) will report exactly the same weather,
 * but different yield per timestamp. Now consider `fid_54932` which reports 2
 * timestamps (one for each company); here both timestamps will have exactly the
 * same yield from both companies, but with different weather readings. This is
 * interesting because when these farms report 4 timestamps, the sum of yields
 * for the same company actually shows us that both companies (and therefore
 * locations) are reporting the exact same amount of yield, even though their
 * climates are different. This is a modified version of Case 1 that we defined
 * earlier.
 * 
 * B) for farms with the same `farm_id` and location but different companies,
 * just like the first group also report 4 times sometimes. However in all cases
 * the weather across both companies is reported to be exactly the same - this
 * is reasonable because both companies are operating from the same geography,
 * and weather within that geography is independent of corporate ownership; the
 * weather remains the same. When these farms report 4 timestamps, while weather
 * is exactly the same for all 4 records, the 2 records from the same company
 * have different yields (just like the earlier group). When they report only 2
 * timestamps, all of the details are the same. This is a modified version of
 * Case 2 that we defined earlier.
 * 
 * C) for farms with the same `farm_id` and companies but different locations,
 * they report only 4 timestamps with the same weather across the 2 reports per
 * location but with different yields at that timestamp. This is a modified
 * version of Case 3 that we defined earlier.
 * 
 * Now the question is how do we deal with this? The first most obvious thing we
 * can notice is that at a minimum, we can expect all duplicated reports - once
 * grouped into at maximum 2 timestamps per farm - will all have precisely the
 * same yield, though in some cases the weather might be different. We can begin
 * by grouping all the farms together on the basis of location, since weather
 * per location is the same in all cases [A, B and C]. The aggregation we use
 * will average climactic readings and farm areas but will sum the yield. Once
 * this is done, we'll inspect our work and proceed from there. This kind of
 * operation is best done atomically.
 */
--get our column names real quick
select column_name
from information_schema.columns
where table_name = 'grand_merge';

begin;
	savepoint undup_stage1;

	/* we'll begin with our first stage of grouping. Obviously we want our query
	 * to be as concise as possible and therefore, we won't select every row in
	 * `grand_merge` because almost 99% of them are irrelevant to the farms we
	 * want to manipulate. This will also make it easier when committing our
	 * changes back to the database.
	 */
	create temporary table undup_farms on commit drop as
		select
			gm."date",
			gm.farm_id,
			gm.ingredient_type,
			min(gm.operations_commencing_year) as "operations_commencing_year",
			min(gm.num_processing_plants) as "num_processing_plants",
			avg(gm.farm_area) as "farm_area",
			gm.farming_company,
			gm.deidentified_location,
			avg(gm.temp_obs) as "temp_obs",
			avg(gm.cloudiness) as "cloudiness",
			avg(gm.wind_direction) as "wind_direction",
			avg(gm.dew_temp) as "dew_temp",
			avg(gm.pressure_sea_level) as "pressure_sea_level",
			avg(gm.precipitation) as "precipitation",
			avg(gm.wind_speed) as "wind_speed",
			sum(gm.yield) as "yield"
		from
			grand_merge gm
		where
			farm_id in (
				select farm_id
				from farm_data
				group by farm_id
				having count(farm_id) > 1
			)
		group by
			gm.deidentified_location, gm.farming_company,
			gm.ingredient_type, gm.farm_id, gm."date"
		order by
			gm.ingredient_type, gm.farm_id, gm."date";

	/* since we're doing this as a transaction we can take some creative liberty
	 * when it comes to inspecting our stuff. Let's begin with the first farm
	 * we mentioned earlier and work our way through from there.
	 */
	select *
	from undup_farms
	where
		farm_id = 'fid_53126' and
		ingredient_type = 'ing_w';

	/* we can already see our assumption of the sum of yields being the same for
	 * all involved companies is true. Let's check out farms from case B.
	 */
	select *
	from undup_farms
	where
		farm_id = 'fid_68761' and
		ingredient_type = 'ing_w';
	
	/* we can see a solution building here for case B, but let's press on a bit
	 * more before conclusively concluding anything conclusive. Case C is up.
	 */
	select *
	from undup_farms
	where
		farm_id = 'fid_81333' and
		ingredient_type = 'ing_w';
	
	/* we might also have a solution for case C, though it's arguable whether it
	 * is appropriate practically or not. The idea here is for case B, since the
	 * only differentiating factor is the company owning the farm (given weather
	 * and yield are exactly the same), we can relabel those companies into a
	 * different category like "partnership", but only for the farms that a part
	 * of case B.
	 * 
	 * Note: we're only updating values here rather than aggregating anything,
	 * the total aggregation will come towards the end of the transaction.
	 */
	savepoint undup_stage2;

	update undup_farms
	set farming_company = 'Partnership'
	where
		farm_id = 'fid_122174' or
		farm_id = 'fid_68761' or
		farm_id = 'fid_71910'
	returning farming_company;

	--quick inspection
	select distinct farming_company from undup_farms;

	/* good to proceed. Now what about farms in the other two cases? Keeping in
	 * mind our overall goal for this project is to predict yield for the year
	 * ahead, and trying to line that up with the fact that yield across all
	 * duplicated reports are now exactly the same irrespective of whether the
	 * climate or company is different for that farm, the idea for case C is as
	 * follows:
	 * 
	 * farms with the same companies across different location can be assumed
	 * as units of the same corporation and therefore, can have their measures
	 * aggregated. The thought here is along the lines of "this farm is owned by
	 * this company, and this company reports this much yield from all of its
	 * operating locations." The argument is that there isn't any reason to get
	 * into the effects of the different locations' climates because not only is
	 * the yield the same, business-wise the same company is operating the farm.
	 * 
	 * Case A will require a little more involvement, so we'll get this out of
	 * the way first.
	 */
	savepoint undup_stage3;
	rollback to undup_stage3;

	update undup_farms
	set deidentified_location = 'shared'
	where
		farm_id = 'fid_18990' or
		farm_id = 'fid_81333'
	returning deidentified_location;

	--quick inspection
	select distinct deidentified_location from undup_farms;
	select count(distinct deidentified_location) from undup_farms;

	/* good to go. Finally, let's think a little about case A. After grouping
	 * our locations and farms together, we can clearly see that case A is only
	 * a simple amalgamation of cases B and C - the yields are exactly the same
	 * across companies and locations. Again keeping in mind our overall goal
	 * here of year-forward yield, since the differentiating factors of farms
	 * now are all of the features except for yield, we can just apply the same
	 * operations to the farms of case A that we did for cases B and C: relabel
	 * companies to "Partnership", and their locations to "shared". Effectively
	 * we're saying we have farms owned by companies in a global partnership,
	 * which isn't entirely unreasonable.
	 */
	savepoint undup_stage4;

	update undup_farms
	set
		farming_company = 'Partnership',
		deidentified_location = 'shared'
	where farm_id in (
		select distinct farm_id
		from undup_farms
		where
			farming_company != 'Partnership' and
			deidentified_location != 'shared'
	) returning farming_company, deidentified_location;

	--quick inspection	
	select farm_id, farming_company, deidentified_location
	from undup_farms
	group by farm_id, farming_company, deidentified_location;
	
	/* and that's a wrap. Let's do a final aggregation, one last check, then
	 * commit our changes and proceed. Because of the way we constructed our
	 * temporary tables, it's very easy for us to simply delete the rows in
	 * `grand_merge` where the farm ID matches the ones we just modified and
	 * reinsert them using our temporary table.
	 */
	savepoint undup_stage5;

	create temporary table undup_final on commit drop as
		select
			uf."date",
			uf.farm_id,
			uf.ingredient_type,
			min(uf.operations_commencing_year) as "operations_commencing_year",
			min(uf.num_processing_plants) as "num_processing_plants",
			avg(uf.farm_area) as "farm_area",
			uf.farming_company,
			uf.deidentified_location,
			avg(uf.temp_obs) as "temp_obs",
			avg(uf.cloudiness) as "cloudiness",
			avg(uf.wind_direction) as "wind_direction",
			avg(uf.dew_temp) as "dew_temp",
			avg(uf.pressure_sea_level) as "pressure_sea_level",
			avg(uf.precipitation) as "precipitation",
			avg(uf.wind_speed) as "wind_speed",
			sum(uf.yield) as "yield"
		from
			undup_farms uf
		group by
			uf.deidentified_location, uf.farming_company,
			uf.ingredient_type, uf.farm_id, uf."date"
		order by
			uf.ingredient_type, uf.farm_id, uf."date";

	--push our changes back to the big table
	savepoint undup_stage6;

	delete from grand_merge where farm_id in (
		select distinct farm_id from undup_final
	);

	insert into grand_merge(
		"date", farm_id, ingredient_type, operations_commencing_year,
		num_processing_plants, farm_area, farming_company, deidentified_location,
		temp_obs, cloudiness, wind_direction, dew_temp, pressure_sea_level,
		precipitation, wind_speed, yield
	) select * from undup_final;
commit;

/* let's do a quick check (can't ever have enough of those) and move onto
 * dealing with our null values.
 */
select
	farm_id, ingredient_type, farming_company, deidentified_location, count(*)
from grand_merge
where farm_id in (
	select farm_id
	from farm_data
	group by farm_id
	having count(farm_id) > 1
) group by
	farm_id, ingredient_type, farming_company, deidentified_location
order by farm_id;

/* good to go: we now have completely unique reports for each farm. This will
 * make it much easier when dealing with our null values - what will also make
 * it interesting is our observation on weather behaviour across locations.
 */

----------------------##### PART 4: NULL IMPUTATION #####----------------------
select * from grand_merge;

analyze verbose grand_merge;

/* if it wasn't known by now, we won't be taking care of our intra-series null
 * values within PSQL itself. We'll be doing our imputation in <insert favourite
 * language here> via ETL procedures; i.e. we'll connect to our database, pull
 * out whatever data we need, impute it using whatever algorithm we want to use
 * and then feed it right back into the database. For the last part of that
 * sequence, we have two main options: either we directly update our original
 * database `grand_merge` with the imputed values and risk having to re-run all
 * of the DDL queries and imputation algorithms if we want to change anything
 * later on, or we duplicate `grand_merge` and use the copy going forward. The
 * latter options is safer and more convenient at the cost of space, and since
 * we have a lot of space available, we'll do that.
 */
create table if not exists grand_impute as table grand_merge;

/* After a quick hop, skip and planetary excursion in our favourite language,
 * we're back. let's quickly inspect our work and make sure everything is as we
 * expect it to be. The first thing we need to do is see how much our weather
 * variability has changed after imputation.
 */
select
	distinct gi.deidentified_location  as "loc",
	count(*) as "c_total",
	count(distinct gi.temp_obs) as "d_temp",
	count(distinct gi.cloudiness) as "d_cloud",
	count(distinct gi.wind_direction) as "d_wdir",
	count(distinct gi.dew_temp) as "d_dew",
	count(distinct gi.pressure_sea_level) as "d_psl",
	count(distinct gi.precipitation) as "d_precip",
	count(distinct gi.wind_speed) as "d_wspd"
from grand_impute gi
group by gi.deidentified_location;

/* Spectacular, our variability has barely registered an increase. On a per-farm
 * basis however, a very tiny few amounts of measurements seem to have swelled
 * in size, especially regarding precipitation, but it's really no cause for
 * concern at all. Let's also make sure our min/max values are acceptable.
 */
select
	distinct gi.deidentified_location  as "loc",
	min(distinct gi.temp_obs) as "min_temp",
	max(distinct gi.temp_obs) as "max_temp",
	min(distinct gi.cloudiness) as "min_cloud",
	max(distinct gi.cloudiness) as "max_cloud",
	min(distinct gi.wind_direction) as "min_wdir",
	max(distinct gi.wind_direction) as "max_wdir",
	min(distinct gi.dew_temp) as "min_dew",
	max(distinct gi.dew_temp) as "max_dew",
	min(distinct gi.pressure_sea_level) as "min_psl",
	max(distinct gi.pressure_sea_level) as "max_psl",
	min(distinct gi.precipitation) as "min_precip",
	max(distinct gi.precipitation) as "max_precip",
	min(distinct gi.wind_speed) as "min_wspd",
	max(distinct gi.wind_speed) as "max_wspd"
from grand_impute gi
group by gi.deidentified_location;

/* Absolutely spectacular, and also not surprising at all: we clearly mentioned
 * what our minimum and maximum values should be during the imputation phase. A
 * point we have yet to address is the fact that there are some columns wholly
 * null for some locations. Let's have a look.
 */
select
	(select count(*) from grand_impute where temp_obs is null) as "temp",
	(select count(*) from grand_impute where cloudiness is null) as cloud,
	(select count(*) from grand_impute where wind_direction is null) as wdir,
	(select count(*) from grand_impute where dew_temp is null) as dew,
	(select count(*) from grand_impute where pressure_sea_level is null) as psl,
	(select count(*) from grand_impute where precipitation is null) as precip,
	(select count(*) from grand_impute where wind_speed is null) as wspd;

/* yup, we do have some of them that are completely null. For reference, this is
 * what our imputation approach from <alternate favourite language> also told us:
 * "location 6364" => ["pressure_sea_level", "precipitation"]
 * "location 4525" => ["cloudiness"]
 * "location 7048" => ["precipitation"]
 * "location 868"  => ["cloudiness"]
 * "location 959"  => ["precipitation"]
 * 
 * We have a couple of options here: either we reimpute these using EM again, or
 * we simply take the mean of the column, as measured across all locations. What
 * do we pick? First of all it is important to recognise the context of this
 * situation: we began imputing each location separately, working with the
 * assumption that weather across a geography does not vary as much as within
 * said geography, and we were correct. So we imputed every location's missing
 * values separately from other locations. In this situation however, we are
 * looking at every single row from the imputed dataframe, which is effectively
 * an amalgamation of all locations in one place. To use EM here again would
 * imply that we believe the 3 missing features across their locations are some
 * how equivalent to some linear combination of the rest of features across the
 * other locations, effectively working against our independence assumption.
 * 
 * Imputing with the mean instead implies that we believe the average of that
 * weather feature, as measured across all other locations, is a better choice
 * at explaining the missing weather feature for that location. In other words,
 * if the European climate was suddenly discovered missing, using EM-SVD would
 * mean we're saying something like "a linear combination of the weather as
 * measured across India, Japan, South Africa and KSA explains the weather of
 * Europe", which may or may not be incorrect. Using the mean however implies
 * we're saying something like "the aveage of the weather features as measured
 * across India, Japan, South Africa and KSA explains the weather features of
 * Europe", which is more conservative and probably more general (and therehaps
 * more appropriate).
 * 
 * We can also use coalesce` because we want all null values to be replaced with
 * the average; `coalesce` evaluates arguments from left to right until the
 * first non-null argument, following which all of the remaining arguments are
 * ignored. Our window function ensures we don't also replace existing non-null
 * `cloudiness` values with the mean. Here's a MVCE of this:
 * 
 * select
 * 	   ifd."date",
 *	   ifd."time",
 *	   ifd.farm_id,
 *	   ifd.ingredient_type,
 *	   ifd.farming_company,
 *	   ifd.deidentified_location,
 *	   ifd.temp_obs,
 *	   coalesce(ifd.cloudiness, avg(ifd.cloudiness) over ()) as "cloudiness",
 *	   ifd.wind_direction,
 *	   ifd.dew_temp,
 *	   coalesce(ifd.pressure_sea_level, avg(ifd.pressure_sea_level) over()) as "pressure_sea_level",
 *	   coalesce(ifd.precipitation, avg(ifd.precipitation) over()) as "precipitation",
 *	   ifd.wind_speed
 * from impute ifd;
 */
begin;
	create temporary table means on commit drop as
		select
			round(avg(cloudiness)) as avg_cloud,
			avg(precipitation) as avg_pcp,
			avg(pressure_sea_level) as avg_psl
		from grand_impute;

	--game saved...
	savepoint mean_clouds;

	update grand_impute set cloudiness = means.avg_cloud
	from means
	where cloudiness is null;

	--game saved...
	savepoint mean_psl;

	update grand_impute set pressure_sea_level = means.avg_psl
	from means
	where pressure_sea_level is null;

	--game saved...
	savepoint mean_pcp;

	update grand_impute set precipitation = means.avg_pcp
	from means
	where precipitation is null;

	--quick checks
	select
		(select count(*) from grand_impute where cloudiness is null) as cloud,
		(select count(*) from grand_impute where pressure_sea_level is null) as psl,
		(select count(*) from grand_impute where precipitation is null) as precip;

	select * from grand_impute;

	--looks good, the only thing left now to do now is sort the table
	savepoint imp_sort_1;

	create table sorted as
		select * from grand_impute order by ingredient_type, farm_id, "date";
	
	drop table grand_impute;

	alter table sorted rename to grand_impute;

	--quick check to make sure everything is okay
	select * from grand_impute;
commit;

/* and let's finish off by creating an index for our imputed dataset. Notice we
 * refrained from doing this until we completed all of our activities because
 * it's common knowledge that multiple inserts, updates and deletes can
 * seriosuly degrade performance of a table if an index is already attached to
 * it. Given the sheer amount of data we manipulated across the table during
 * imputation, if we created an index beforehand we would have had trash-tier
 * performance, guaranteed. It also doesn't help to create an index on a table,
 * update it a bunch of times, and then finally drop it because we want to have
 * it sorted...
 */
create index gi_multi_cat_index on grand_impute (
	farm_id,
	farming_company,
	deidentified_location
);

analyze verbose grand_impute;

------------------------##### PART 5: TESTING DATA #####-----------------------

/* we also need to ensure we perform the same operations on our testing data to
 * prepare that for predictions. What follows will be precisely the same order
 * of steps we took for our training data, so expect a little less commentary.
 */
select * from test_data;
select * from test_weather;

--any extra categorical factors we might have?
select count(distinct deidentified_location) from grand_impute
union select count(distinct deidentified_location) from test_weather
union select count(distinct deidentified_location) from farm_data;

--just the one we expected. any extraneous timestamps precluding our join?
select count(*) from (
	select td."date" as "test_data_date"
	from test_data td
	except select tw."timestamp"
	from test_weather tw
) q;

--nope, let's join then (including `company` from `farm_data`)
begin;
	savepoint clean;

	--big vanilla merge first
	create temporary table test_merge on commit drop as
		select
			td.*,
			fd.operations_commencing_year, fd.num_processing_plants,
			fd.farm_area, fd.farming_company,
			tw.deidentified_location, tw.temp_obs, tw.cloudiness,
			tw.wind_direction, tw.dew_temp, tw.pressure_sea_level,
			tw.precipitation, tw.wind_speed
		from
			test_data td
			left join (
				select
					farm_id, operations_commencing_year, num_processing_plants,
					farm_area, farming_company, deidentified_location
				from
					farm_data
			) as fd on td.farm_id = fd.farm_id
			left join test_weather tw on
				td."date" = tw."timestamp" and
				tw.deidentified_location = fd.deidentified_location
		order by td.ingredient_type, td.farm_id, td."date";
	
	savepoint t_merge;

	--relabel minority companies and check
	update test_merge set farming_company = 'Other' where farming_company in (
		select farming_company
		from test_merge
		except
		select farming_company
		from grand_impute
	);

	select distinct farming_company from test_merge;

	--all good
	savepoint t_company;

	--now we want to deal with `company = "Partnership"` and `loc = "shared"`
	update test_merge set
		farming_company = 'Partnership',
		deidentified_location = 'shared'
	where farm_id in (
		select distinct farm_id
		from grand_impute
		where
			farming_company = 'Partnership' and
			deidentified_location = 'shared'
	);

	--next, partnerships only
	savepoint t_dist;

	update test_merge set
		farming_company = 'Partnership'
	where farm_id in (
		select distinct farm_id
		from grand_impute
		where
			farming_company = 'Partnership' and
			deidentified_location != 'shared'
	);

	--and finally shared locations
	savepoint t_partner;

	update test_merge set
		deidentified_location = 'shared'
	where farm_id in (
		select distinct farm_id
		from grand_impute
		where
			farming_company != 'Partnership' and
			deidentified_location = 'shared'
	);

	--final checks
	savepoint t_final;

	select
		farm_id, ingredient_type, farming_company, deidentified_location,
		count(*) as "count"
	from test_merge
	where farm_id in (
		select farm_id
		from farm_data
		group by farm_id
		having count(farm_id) > 1
	) group by
		farm_id, ingredient_type, farming_company, deidentified_location
	order by farm_id;

	--few null values somehow, not sure what happened but a quick fix is in order
	update test_merge set deidentified_location = 'location 2532'
	where farm_id = 'fid_122174';

	update test_merge set deidentified_location = 'location 6364'
	where farm_id = 'fid_71910';

	--should be good to go, only null values are left
	savepoint t_final_final;

	select * from test_merge;

	select
		(select count(*) from test_merge where temp_obs is null) as "temp",
		(select count(*) from test_merge where cloudiness is null) as cloud,
		(select count(*) from test_merge where wind_direction is null) as wdir,
		(select count(*) from test_merge where dew_temp is null) as dew,
		(select count(*) from test_merge where pressure_sea_level is null) as psl,
		(select count(*) from test_merge where precipitation is null) as precip,
		(select count(*) from test_merge where wind_speed is null) as wspd;

	--looks good. let's persist our temporary table and commit
	create table test_together as select * from test_merge;
commit;

--need to rename the test table to conform to our naming conventions
alter table test_together rename to test_merge;

--now we check for duplicates, which there shouldn't be any of
select farm_id, farming_company, deidentified_location
from test_merge
where
	farm_id = farm_id and
	farming_company <> farming_company or
	deidentified_location <> deidentified_location;

--for null values we'll be using the same EM approach we did for `grand_merge`
create table if not exists test_impute as table test_merge;

/* this section of test data preparation picks up from after we've imputed the
 * majority null values we have in test. Basically if this SQL script file is
 * being run query after query, please stop here and jump back to the Jupyter
 * Notebook associated with this project. For safety:
 * 
 * COME BACK HERE AFTER IMPUTING TEST_IMPUTE NULLS!!!
 * 
 * We're checking for residual nulls.
 */
select
	(select count(*) from test_impute where temp_obs is null) as "temp",
	(select count(*) from test_impute where cloudiness is null) as cloud,
	(select count(*) from test_impute where wind_direction is null) as wdir,
	(select count(*) from test_impute where dew_temp is null) as dew,
	(select count(*) from test_impute where pressure_sea_level is null) as psl,
	(select count(*) from test_impute where precipitation is null) as precip,
	(select count(*) from test_impute where wind_speed is null) as wspd;

--let's not forget our mean imputation; we have more here than we did for train.
begin;
	create temporary table means on commit drop as
		select
			avg(temp_obs) as avg_temp,
			round(avg(cloudiness)) as avg_cloud,
			avg(wind_direction) as avg_wdir,
			avg(dew_temp) as avg_dew,
			avg(pressure_sea_level) as avg_psl,
			avg(precipitation) as avg_pcp,
			avg(wind_speed) as avg_wspd
		from test_impute;

	--game saved...
	savepoint test_means;

	--let's update our values
	update test_impute set temp_obs = means.avg_temp
	from means
	where temp_obs is null;

	update test_impute set cloudiness = means.avg_cloud
	from means
	where cloudiness is null;

	update test_impute set wind_direction = means.avg_wdir
	from means
	where wind_direction is null;

	update test_impute set dew_temp = means.avg_dew
	from means
	where dew_temp is null;

	update test_impute set pressure_sea_level = means.avg_psl
	from means
	where pressure_sea_level is null;

	update test_impute set precipitation = means.avg_pcp
	from means
	where precipitation is null;

	update test_impute set wind_speed = means.avg_wspd
	from means
	where wind_speed is null;

	--quick check
	select
		(select count(*) from test_impute where temp_obs is null) as "temp",
		(select count(*) from test_impute where cloudiness is null) as cloud,
		(select count(*) from test_impute where wind_direction is null) as wdir,
		(select count(*) from test_impute where dew_temp is null) as dew,
		(select count(*) from test_impute where pressure_sea_level is null) as psl,
		(select count(*) from test_impute where precipitation is null) as precip,
		(select count(*) from test_impute where wind_speed is null) as wspd;
	
	--now we should sort too
	savepoint imp_sort_1;

	create table sorted as
		select * from test_impute order by ingredient_type, farm_id, "date";
	
	drop table test_impute;

	alter table sorted rename to test_impute;

	--quick check to make sure everything is okay
	select * from test_impute;
commit;

--last but definitely not least: our indices
create index tm_multi_cat_index on test_merge (
	farm_id,
	farming_company,
	deidentified_location
);

analyze verbose test_merge;

create index ti_multi_cat_index on test_impute (
	farm_id,
	farming_company,
	deidentified_location
);

analyze verbose test_impute;

/* and that's pretty much it for now: we have our train and testing data fully
 * merged together, sorted, imputed and cleaned as much as we should be doing
 * for this stage of the project.
 */

----------------------##### PART 6: INGREDIENT VIEWS #####---------------------
select * from grand_impute;

/* When splitting by ingredient, we'll be creating views for them because there
 * is really no reason to have an entire table dedicated for them taking up
 * space when we have no inserts or updates planned for them.
 */
create view ing_w as
	select
		"date", farm_id, operations_commencing_year, num_processing_plants,
		farm_area, farming_company, deidentified_location, temp_obs, cloudiness,
		wind_direction, dew_temp, pressure_sea_level, precipitation, wind_speed,
		yield
	from grand_impute
	where ingredient_type = 'ing_w'
	order by farm_id, "date";

select * from ing_w;

create view ing_x as
	select
		"date", farm_id, operations_commencing_year, num_processing_plants,
		farm_area, farming_company, deidentified_location, temp_obs, cloudiness,
		wind_direction, dew_temp, pressure_sea_level, precipitation, wind_speed,
		yield
	from grand_impute
	where ingredient_type = 'ing_x'
	order by farm_id, "date";

select * from ing_x;

create view ing_y as
	select
		"date", farm_id, operations_commencing_year, num_processing_plants,
		farm_area, farming_company, deidentified_location, temp_obs, cloudiness,
		wind_direction, dew_temp, pressure_sea_level, precipitation, wind_speed,
		yield
	from grand_impute
	where ingredient_type = 'ing_y'
	order by farm_id, "date";

select * from ing_y;

create view ing_z as
	select
		"date", farm_id, operations_commencing_year, num_processing_plants,
		farm_area, farming_company, deidentified_location, temp_obs, cloudiness,
		wind_direction, dew_temp, pressure_sea_level, precipitation, wind_speed,
		yield
	from grand_impute
	where ingredient_type = 'ing_z'
	order by farm_id, "date";

select * from ing_z;

/* with these splits done we can proceed with inspecting our time series quality
 * on a more granular level.
 */

---------------------##### PART 7: TEMPORAL CLEANING #####---------------------
select * from grand_impute;

/* what we're looking to do here is ensure that all reports from one farm, for
 * one ingredient, from one location, under one company have a total of 8784
 * rows (366 days * 24 hours). Recall that we've already taken care of the one-
 * location-one-company part of the problem, and by segregating our data based
 * on ingredient into 4 different views, implicitly we've also addressed the
 * ingredient concern. As of now, we know that there are multiple farms that are
 * missing quite a few dates within their series, so let's do a global check to
 * begin with. For something really interesting, check out the query plan for
 * by prepending `explain` to `select`.
 */
select
	parted.farm_id,
	min(parted."date") as mindate,
	max(parted."date") as maxdate,
	count(distinct parted."date") as obs_dates,
	(
		(extract(epoch from max(parted."date")) - 
		extract(epoch from min(parted."date"))) / 3600
	)::integer as exp_dates,
	(
		count(distinct parted."date") -
		(extract(epoch from max(parted."date")) -
		extract(epoch from min(parted."date"))) / 3600
	)::integer as diff
from (
	select
		gi.farm_id, gi."date",
	    row_number() over (partition by farm_id order by "date")
    from grand_impute gi
) as parted
group by farm_id
order by diff asc;

/* we can see that our top two farms (`73322` and `20058`) are missing more than
 * 75% of whatever dates they should have. The farms following them only have a
 * missingness of ~35%, which drops. Assuming we insert the missing dates for
 * these two farms, how do we interpolate with such little data? There are some
 * sophisticated methods we can use, though it's be quite difficult to ascertain
 * the degree of "correctness" since majority of the ground truth is missing.
 * Before taking a call here, let's get some more perspectives on deck, starting
 * with ingredient W.
 */
select
	parted.farm_id,
	min(parted."date") as mindate,
	max(parted."date") as maxdate,
	count(distinct parted."date") as obs_dates,
	(
		(extract(epoch from max(parted."date")) - 
		extract(epoch from min(parted."date"))) / 3600
	)::integer as exp_dates,
	(
		count(distinct parted."date") -
		(extract(epoch from max(parted."date")) -
		extract(epoch from min(parted."date"))) / 3600
	)::integer as diff
from (
	select
		w.farm_id, w."date",
		row_number() over (partition by farm_id order by date)
    from ing_w w
) as parted
group by farm_id
order by diff asc;

/* no surprise that ingredient w has the maximum amount of temporal incoherence,
 * also no surprise that the two most missing farms are present here amongst the
 * top 4 farms who, in addition to these 2, are missing more than 50% of their
 * data. Since imputation methods could introduce errors that propogate quite
 * severely (in this case) through the series, might we be able to drop these
 * farms entirely from our analysis? In addition to having most of their data
 * missing, if they also contribute very little to overall yield produce then it
 * might be justifiable (though we also need to keep in mind that their low
 * contribution could very well be an artefact of their missingness). Let's have
 * a look at the yield contributors for ingredient W and see what's up...
 * 
 * ...after inspecting the yield contribution by farm, we can conclude that 3 of
 * our most missing farms producing ingredient W are below average contributors
 * by a sufficient margin, such that they can be dropped entirely from analysis
 * WLOG. Before taking a final call however, let's just have a cursory look at
 * what the actual time series of these farms looks like.
 */
select * from grand_impute where farm_id = 'fid_122962';
select * from grand_impute where farm_id = 'fid_73322';
select * from grand_impute where farm_id = 'fid_20058'; --that's interesting...
select * from grand_impute where farm_id = 'fid_31778';
select * from grand_impute where farm_id = 'fid_114713';
select avg(farm_area) from grand_impute;

/* okay that's wicked. As it turns out, *very* interestingly enough, the missing
 * data is not malevolent as we initially thought: it's actually informative in
 * and of itself. How so? Observe the behaviour of the few farms inspected above
 * and notice how their produce changes over time - for clarity, let's break it
 * down into 3 separate categories of farms:
 * 1) farms that rotate their production across ingredients
 * 2) farms that intermittently produce ingredients
 * 3) recently acquired farms
 * 
 * What these categories mean is that the missing timestamps aren't problematic:
 * they actually indicate normal operation of a farm. Consider farms `122962` &
 * `31778` - both part of the top 4 missing farms for ingredient W. If we look
 * closely at their behaviour over time, we clearly see that they indulge in a
 * kind of cross-cultivation: when not producing ingredient W (i.e., when they
 * do not report anything for ingredient W and therefore, build for themselves a
 * discontinuous time series), they're producing either ingredient X, Y or Z. In
 * other words, their overall time series is continuous (which is corroborated
 * by the fact that they don't appear anywhere near the top in the global list
 * of missingness) but their individual time series for each ingredient appears
 * discontinuous. We're not done yet.
 * 
 * Now consider farms `73322` and `20058`. The former very intermittently will
 * produce ingredient W and then stop, usually for months at a stretch, without
 * appearing to produce any other ingredient. This farm is owned by a single
 * company throughout its reported existence, and also has below average farm
 * area; it might very well be the case that this farm is only used as a sort
 * of supplementary production house to bolster yield for that company and
 * hence, would have intermittent reports. It's also possible that the company
 * simply repurposes this farm for other, more productive uses; and therefore
 * the missing dates are simply because the farm had no relevant activity for
 * producing ingredient W. `20058` on the other hand only started producing
 * from 25-Nov-2016, and since that date has had a very continuous stream of
 * reports.
 * 
 * Finally, look at farm `114713`, which appears to be minimally missing across
 * all 3 ingredient categories, and also only seems to be missing 4 days on a
 * global measure. This behaviour is also indicative of rotational farming.
 * The point here isn't these nitty-gritty assumptions of why a farm might be
 * missing dates, the point is that this data is MCAR because every reason for
 * missing a date is as likely as the next. More pertinently, we *cannot* go
 * around inserting dates and imputing values for these farms because we would
 * effectively be asserting that not only were these farms active on those days,
 * they also reportedly produced real, material product, which is a big no-no.
 * As an analogy, imagine if we had quarterly corporate financial reports that
 * spanned a decade with 6 quarterly reports missing, followed by a resumption.
 * Let's also imagine we got our data straight from the SEC/SEBI. It can thus be
 * argued that interpolating the missing figures is equivalent to fraud, because
 * we're effectively saying that the company officially reported real economic
 * activity, which never really happened.
 * 
 * Let's delve into this further and see if our current theory holds up.
 */
select
	parted.farm_id,
	min(parted."date") as mindate,
	max(parted."date") as maxdate,
	count(distinct parted."date") as obs_dates,
	(
		(extract(epoch from max(parted."date")) - 
		extract(epoch from min(parted."date"))) / 3600
	)::integer as exp_dates,
	(
		count(distinct parted."date") -
		(extract(epoch from max(parted."date")) -
		extract(epoch from min(parted."date"))) / 3600
	)::integer as diff
from (
	select
		x.farm_id, x."date",
		row_number() over (partition by farm_id order by date)
    from ing_x x
) as parted
group by farm_id
order by diff asc;

/* looks like the most "missingness" for a farm's time series with regards to
 * ingredient x is only ~49%, which is borderline workable. Not much inspection
 * is required for this, let's move onto ingredient Y.
 */
select
	parted.farm_id,
	min(parted."date") as mindate,
	max(parted."date") as maxdate,
	count(distinct parted."date") as obs_dates,
	(
		(extract(epoch from max(parted."date")) - 
		extract(epoch from min(parted."date"))) / 3600
	)::integer as exp_dates,
	(
		count(distinct parted."date") -
		(extract(epoch from max(parted."date")) -
		extract(epoch from min(parted."date"))) / 3600
	)::integer as diff
from (
	select
		y.farm_id, y."date",
		row_number() over (partition by farm_id order by date)
    from ing_y y
) as parted
group by farm_id
order by diff asc;

/* the most missing farm here lacks ~62% of its time series and is a serious
 * competitor in the below-average producer category. It could be dropped WLOG,
 * but again it's better we have a closer look. Before we start scrolling
 * through all of the records of the farm, let's compare its behaviour globally
 * as well as individually across ingredients. The most missingness comes from
 * ingredient Y where it's missing ~62% of its time series. However, it also
 * produces ingredients X and W, where it's only missing ~34% and 0.08% of time
 * respectively. Globally, it's not missing any dates at all! We can say with
 * a good degree of confidence that this farm also indulges in cross-cultivation
 * and therefore isn't particularly problematic. Onto the scrolling.
 */
select * from grand_impute where farm_id = 'fid_69851';

/* Indeed, this farm has dates where one ingredient is missing produce yet the
 * others are being produced. Let's move onto ingredient Z's situation.
 */
select
	parted.farm_id,
	min(parted."date") as mindate,
	max(parted."date") as maxdate,
	count(distinct parted."date") as obs_dates,
	(
		(extract(epoch from max(parted."date")) - 
		extract(epoch from min(parted."date"))) / 3600
	)::integer as exp_dates,
	(
		count(distinct parted."date") -
		(extract(epoch from max(parted."date")) -
		extract(epoch from min(parted."date"))) / 3600
	)::integer as diff
from (
	select
		z.farm_id, z."date",
		row_number() over (partition by farm_id order by date)
    from ing_z z
) as parted
group by farm_id
order by diff asc;

/* as expected, ingredient z not only has the least amount of missingness, but
 * its most "missingness" farm is only ~35% missing which is very workable. The
 * next question is obviously then, what's the best move? The simple answer is:
 * nothing. We do not drop any of these farms because as discussed, the missing
 * timestamps of one ingredient do not imply that the entire farm is short of
 * productivity. Even on a global scale, we can retain the top 2 missing farms
 * because this kind of missing data is literally MCAR. We cannot interpolate
 * any of it for the same reason. Therefore, we will roll with what we have. The
 * last thing left for our SQL handling is to prepare our final datasets for
 * easy loading into <insert favourite language here>. There are many, many
 * caveats we need to keep in mind when doing this, which we'll go into below.
 */

---------------------##### PART 8: FINAL STRUCTURING #####---------------------

/* There's no doubt the magnitude of data we have here to handle is large. Due
 * to the different categories of recorded states we have, feature selection and
 * other preliminary modelling techniques will require a large and iterative
 * effort; the kind of effort that's best offloaded onto dedicated circuitry.
 * To facilitate this however, an equally large amount of digital space would
 * be required, especially if we want to be accomodative of as many states as
 * possible such that our model of the system is as general as possible.
 * 
 * In order to provide a general dataset, we will subsample the vast amount of
 * information we have to generate a smaller one that accomodates almost all
 * different situations in some shape or form, but is also consistent in terms
 * of its structure. What we are going to do, in more precise terms, is this:
 * 
 * 1. create a pool of data containing farms that have at minimum one complete
 * year of data (366 * 24 records). This pool will form the basis for all our
 * proceeding steps because a farm with a full year of data can be argued to
 * represent all farms at standard productivity levels. This is where we need
 * to settle a little doubt: if we're only including farms with a set of
 * complete records, why did we have a whole discussion on missing dates?
 * While missing records are indicative of alternative production and hence are
 * not a problem in terms of what the data signifies, we need to think about
 * such phenomena a little carefully when deciding whether to include it in our
 * data or not. When a farm doesn't report production for one ingredient, it's
 * producing another. Okay, but does that knowledge help us predict whether the
 * other ingredient's yield will fluctuate over time? All we know is that the
 * farm switched over to another crop; the yield of that crop still depends on
 * the climate and other factors of agriculture. There isn't a doubt that the
 * switch is informative, there is a doubt that's impactful.
 * 
 * 2. from the pool of candidate farms, we're going to select farms across both
 * company and ingredient, such that we have farms producing all ingredients
 * from all companies. In other words, we will be selecting farms from Obery
 * Farms that produce ingredients W, X, Y and Z (data permitting). We will
 * also be selecting farms from Wayne Farms that produce ingredients W, X, Y
 * and Z. The same for all other companies. But we won't be choosing these
 * farms completely arbitrarily: we will also try to include as much spread
 * of location as we can so that we can train our model on various weather
 * conditions. Another doubt is if we claimed earlier we can impute missing
 * data on the basis of location due to geographical similarity, why don't
 * we incorporate that information here? Dissecting our earlier decision will
 * reveal that it's impact is localised as well. When imputing missing values
 * for climate features, we deduced that climate within a location doesn't
 * vary. We didn't say that locations are similar to one another, we simply
 * said the intra-geographical phenomena are similar and are what define *a*
 * location, not a group of them.
 * 
 * 3. For each location/company/ingredient axis, we'll be selecting at most 2
 * farms to represent the entire population for that cross-section. Why 2?
 * The only answer to this question is: training time. Accomodating various
 * combinations of climate behaviour and corporate produce within a subset
 * this small (2 farms per ingredient per company, each from a potentially
 * different location) might seem obtuse and non-representative, but there
 * is the real constraint of maximising variability while minimising lack of
 * structure along with training time of our computations. The model we're
 * intent on using is capable of sophisticated feature selection and multiple
 * perspective learning, all methods which come at a very, very high cost of
 * computational complexity. Those methods however allow it to discern groups
 * of relationships within relatively "small" feeds of data that can be
 * generalised over larger sets. There's more discussion on this in the
 * accompanying Jupyter Notebook.
 * 
 * Let's start by looking at what kinds of farms we want to create a candidate
 * pool out of. We want ones with a full year of data; we'll export the result
 * and quickly put together a set of farms we want to include. This is included
 * in the accompanying spreadsheet.
 */
select
	farm_id, farming_company, ingredient_type,
	deidentified_location, sum(yield)
from grand_impute where farm_id in (
	select farm_id from (
		select
			parted.farm_id,
			min(parted."date") as mindate,
			max(parted."date") as maxdate,
			count(distinct parted."date") as obs_dates,
			(
				(extract(epoch from max(parted."date")) - 
				extract(epoch from min(parted."date"))) / 3600
			)::integer as exp_dates,
			(
				count(distinct parted."date") -
				(extract(epoch from max(parted."date")) -
				extract(epoch from min(parted."date"))) / 3600
			)::integer as diff
		from (
			select
				gi.farm_id, gi."date",
				row_number() over (partition by farm_id order by date)
		    from grand_impute gi
		) as parted
		group by farm_id
		order by diff asc
	) q where q.diff >= 0 and q.obs_dates >= 8700
) group by
	farm_id, farming_company,
	ingredient_type, deidentified_location
order by
	farm_id, farming_company, ingredient_type,
	deidentified_location, "sum";

/* our model requires our data feed to be in a certain format, which makes it
 * much easier to discern what feature indicates what. Instead of creating this
 * as an actual table or schema, we'll just use the data we currently have to
 * build a view that we can use later. First our training view.
 */
create view final_train as
	select
		extract(quarter from "date") as "quarter",
		extract(month from "date") as "month",
		extract(week from "date") as "week",
		extract(day from "date") as "day",
		extract(dow from "date") as "dow",
		extract(hour from "date") as "hour",
		row_number() over(
			partition by farm_id, ingredient_type
		) as "time_idx",
		dense_rank() over(order by farm_id) as "group",
		farm_id, ingredient_type, farm_area, farming_company,
		deidentified_location, temp_obs, cloudiness, wind_direction,
		dew_temp, pressure_sea_level, precipitation, wind_speed, yield
	from grand_impute;

--now our prediction view
create view final_test as
	select
		extract(quarter from "date") as "quarter",
		extract(month from "date") as "month",
		extract(week from "date") as "week",
		extract(day from "date") as "day",
		extract(dow from "date") as "dow",
		extract(hour from "date") as "hour",
		row_number() over(
			partition by farm_id, ingredient_type
		) as "time_idx",
		dense_rank() over(order by farm_id) as "group",
		farm_id, ingredient_type, farm_area, farming_company, 
		deidentified_location, temp_obs, cloudiness, wind_direction,
		dew_temp, pressure_sea_level, precipitation, wind_speed
	from test_impute;

/* and with this and our sets of farms ready, we can begin to craft our final
 * dataset. The reason behind these particular farm IDs is included in the
 * accompanying spreadsheet to this SQL file and project.
 */
begin;
	savepoint jacuzzi;

	--select farms producing ing_w
	create temporary table final_train on commit drop as
		select * from grand_impute
		where ingredient_type = 'ing_w' and farm_id in (
			'fid_119518', 'fid_120597', 'fid_104740', 'fid_30532', 'fid_118325',
			'fid_101039', 'fid_122174', 'fid_101271', 'fid_120650', 'fid_41680',
			'fid_28178', 'fid_119338', 'fid_105593', 'fid_26064'
		);
	
	savepoint watercloset;

	--select farms producing ing_x
	insert into final_train select *
	from grand_impute where ingredient_type = 'ing_x' and farm_id in (
		'fid_38963', 'fid_103568', 'fid_83104', 'fid_111995', 'fid_62425',
		'fid_101039', 'fid_122174', 'fid_54695', 'fid_106446', 'fid_113277',
		'fid_28178', 'fid_81920', 'fid_107841', 'fid_26064'
	);

	savepoint aquarevo;
	
	--select farms producing ing_y
	insert into final_train select *
	from grand_impute where ingredient_type = 'ing_y' and farm_id in (
		'fid_71961', 'fid_106666', 'fid_50234', 'fid_32599', 'fid_72922',
		'fid_60148', 'fid_122174','fid_36575', 'fid_114090', 'fid_35923',
		'fid_54620', 'fid_77830', 'fid_73600', 'fid_26064'
	);

	savepoint oceanarium;
	
	--select farms producing ing_z
	insert into final_train select *
	from grand_impute where ingredient_type = 'ing_z' and farm_id in (
		'fid_51573', 'fid_92956', 'fid_107259', 'fid_35152', 'fid_27582',
		'fid_116209', 'fid_68761','fid_66062', 'fid_121305', 'fid_110680',
		'fid_48766', 'fid_49675', 'fid_13316', 'fid_73431'
	);

	savepoint water;

	--finally, format our data and push it to a table
	create table last_train as
		select
			extract(quarter from "date") as "quarter",
			extract(month from "date") as "month",
			extract(week from "date") as "week",
			extract(day from "date") as "day",
			extract(dow from "date") as "dow",
			extract(hour from "date") as "hour",
			row_number() over(
				partition by farm_id, ingredient_type
			) as "time_idx",
			dense_rank() over(order by farm_id) as "group",
			farm_id, ingredient_type, farm_area, farming_company,
			deidentified_location, temp_obs, cloudiness, wind_direction,
			dew_temp, pressure_sea_level, precipitation, wind_speed, yield
		from final_train;

	--check, check, check...
	select count(distinct farm_id) from last_train;
commit;

/* let's not forget the absolutely critical part of building an index for the
 * dataset: though we have a very SOTA storage device this database resides on,
 * indices significantly improve fetch performance when there are constraints in
 * a query. We'll be slicing our data and pulling it right from the database on
 * each training iteration, so we definitely require indices for this dataset if
 * no other.
 */
alter table last_train rename to "final_train";
	
create index final_train_index on final_train (
	farm_id,
	ingredient_type
);

/* now astutely, we're missing some locations in final_train that, upon closer
 * inspection, are the ones with "incomplete" farms. This isn't a great problem
 * since other "complete" farms have been chosen from the same geographies, so
 * climate information is preserved.
 */
select deidentified_location from grand_impute
except select deidentified_location from final_train;

/* penultimately, we need to also prepare our testing data to be in the same
 * format so that running inference is as seamless as training was. From what we
 * have decided to do, we're training on 9 months of data and predicting on 3;
 * i.e. we're training our model on 3 quarters and we're predicting for the 4th
 * one. This means that any farm going in for prediction - each farm - needs to
 * be loaded in one quarter at a time. The batching can be handled in <insert
 * favourite language here> through the connector to the database, but the
 * format of the data is best handled here and kept ready so that we don't have
 * too many hiccups along the way. We know from some inspection that in the test
 * set, we have some farms that are duplicated. Let's clean those up first; we
 * might also have some nulls hanging around for whatever reason.
 */
select
	(select count(*) from test_impute) as total_rows,
	(select count(*) from test_impute where ingredient_type is null) as ing,
	(select count(*) from test_impute where operations_commencing_year is null) as opsyr,
	(select count(*) from test_impute where num_processing_plants is null) as nproc,
	(select count(*) from test_impute where farm_area is null) as farea,
	(select count(*) from test_impute where farming_company is null) as farmco,
	(select count(*) from test_impute where deidentified_location is null) as deloc,
	(select count(*) from test_impute where temp_obs is null) as "temp",
	(select count(*) from test_impute where cloudiness is null) as cloud,
	(select count(*) from test_impute where wind_direction is null) as winddir,
	(select count(*) from test_impute where dew_temp is null) as dewpt,
	(select count(*) from test_impute where pressure_sea_level is null) as psl,
	(select count(*) from test_impute where precipitation is null) as precip,
	(select count(*) from test_impute where wind_speed is null) as windspd;

/* and we do have nulls, but only in `deidentified_location`. We can use our
 * standard LOCF for this since we already cleaned it up earlier. Let's also get
 * a read on our duplicates situation.
 */
select farm_id, ingredient_type, farming_company, deidentified_location
from test_impute where farm_id in (
	'fid_54932', 'fid_68792', 'fid_81333', 'fid_18990', 'fid_71910',
	'fid_40459', 'fid_29387', 'fid_97094', 'fid_53126', 'fid_59158',
	'fid_122174', 'fid_26064', 'fid_73431', 'fid_68761', 'fid_63700'
) group by farm_id, ingredient_type, farming_company, deidentified_location;

/* we can perform our usual reduce functions of min(), max() and avg(), but we
 * need to be careful we don't tamper with the `id` column because that's what
 * ties our work to what we're presenting! First, a trial run:
 */
select
	"date", farm_id, ingredient_type, id,
	min(operations_commencing_year) as "operations_commencing_year",
	min(num_processing_plants) as "num_processing_plants",
	avg(farm_area) as "farm_area",
	farming_company,
	deidentified_location,
	avg(temp_obs) as "temp_obs",
	avg(cloudiness) as "cloudiness",
	avg(wind_direction) as "wind_direction",
	avg(dew_temp) as "dew_temp",
	avg(pressure_sea_level) as "pressure_sea_level",
	avg(precipitation) as "precipitation",
	avg(wind_speed) as "wind_speed"
from test_impute
where farm_id in (
	'fid_54932', 'fid_68792', 'fid_81333', 'fid_18990', 'fid_71910',
	'fid_40459', 'fid_29387', 'fid_97094', 'fid_53126', 'fid_59158',
	'fid_122174', 'fid_26064', 'fid_73431', 'fid_68761', 'fid_63700'
)
group by
	"date", farm_id, ingredient_type, id,
	farming_company, deidentified_location;

/* looks good, let's update `test_impute` with the cleaned rows and reindex the
 * table - there really is no reason to make a completely separate table for the
 * testing dataset. We'll also need to recreate our draft_test view.
 */
begin;
	savepoint sp_test;

	--before deleting from test_impute, clean the farms we need
	create temporary table ref_cleaned on commit drop as
		select
			"date", farm_id, ingredient_type, id,
			min(operations_commencing_year) as "operations_commencing_year",
			min(num_processing_plants) as "num_processing_plants",
			avg(farm_area) as "farm_area",
			farming_company,
			deidentified_location,
			avg(temp_obs) as "temp_obs",
			avg(cloudiness) as "cloudiness",
			avg(wind_direction) as "wind_direction",
			avg(dew_temp) as "dew_temp",
			avg(pressure_sea_level) as "pressure_sea_level",
			avg(precipitation) as "precipitation",
			avg(wind_speed) as "wind_speed"
		from test_impute
		where farm_id in (
			'fid_54932', 'fid_68792', 'fid_81333', 'fid_18990', 'fid_71910',
			'fid_40459', 'fid_29387', 'fid_97094', 'fid_53126', 'fid_59158',
			'fid_122174', 'fid_26064', 'fid_73431', 'fid_68761', 'fid_63700'
		)
		group by
			"date", farm_id, ingredient_type, id,
			farming_company, deidentified_location
		order by ingredient_type, farm_id, "date";

	--quick check
	select * from ref_cleaned;

	--looks good, let's delete
	savepoint sp_test2;

	delete from test_impute where farm_id in (
		'fid_54932', 'fid_68792', 'fid_81333', 'fid_18990', 'fid_71910',
		'fid_40459', 'fid_29387', 'fid_97094', 'fid_53126', 'fid_59158',
		'fid_122174', 'fid_26064', 'fid_73431', 'fid_68761', 'fid_63700'
	);

	--we deleted twice the rows we have in our temporary table, that's good
	insert into test_impute select * from ref_cleaned;

	--quick check
	select
		farm_id,
		count(*) as num_rows,
		count(distinct ingredient_type) as n_ings,
		count(distinct deidentified_location) as n_locs
	from test_impute where farm_id in (
		'fid_54932', 'fid_68792', 'fid_81333', 'fid_18990', 'fid_71910',
		'fid_40459', 'fid_29387', 'fid_97094', 'fid_53126', 'fid_59158',
		'fid_122174', 'fid_26064', 'fid_73431', 'fid_68761', 'fid_63700'
	) group by farm_id;
commit;

/* now that we've removed the duplicates, we need to reformat our table similar
 * to `final_train` and full up the null values in `deidentified_location`. We
 * will first fill up the nulls with a join, then create a new `final_test`
 * table that's the formatted version of our old one. The reason we're making a
 * new table entirely is because we might need the old table's formatting at
 * some point, so just in case...
 */
begin;
	savepoint sp_test1;

	--have a quick look at what's null and where
	select farm_id, ingredient_type, deidentified_location
	from test_impute where deidentified_location is null
	group by farm_id, ingredient_type, deidentified_location;

	--can fill them with an inner join; WARNING: INTENSIVE QUERY!
	update test_impute
	set deidentified_location = gi.deidentified_location
	from grand_impute gi
	where gi.farm_id = test_impute.farm_id
	and test_impute.deidentified_location is null;
	/* https://stackoverflow.com/a/23556885 */

	--check our work...
	select farm_id, ingredient_type, deidentified_location
	from test_impute where deidentified_location is null
	group by farm_id, ingredient_type, deidentified_location;

	select
		(select count(*) from test_impute) as total_rows,
		(select count(*) from test_impute where ingredient_type is null) as ing,
		(select count(*) from test_impute where operations_commencing_year is null) as opsyr,
		(select count(*) from test_impute where num_processing_plants is null) as nproc,
		(select count(*) from test_impute where farm_area is null) as farea,
		(select count(*) from test_impute where farming_company is null) as farmco,
		(select count(*) from test_impute where deidentified_location is null) as deloc,
		(select count(*) from test_impute where temp_obs is null) as "temp",
		(select count(*) from test_impute where cloudiness is null) as cloud,
		(select count(*) from test_impute where wind_direction is null) as winddir,
		(select count(*) from test_impute where dew_temp is null) as dewpt,
		(select count(*) from test_impute where pressure_sea_level is null) as psl,
		(select count(*) from test_impute where precipitation is null) as precip,
		(select count(*) from test_impute where wind_speed is null) as windspd;

	savepoint sp_test2;

	--formatted test table incoming
	create table final_test as
		select 
			extract(quarter from "date") as "quarter",
			extract(month from "date") as "month",
			extract(week from "date") as "week",
			extract(day from "date") as "day",
			extract(dow from "date") as "dow",
			extract(hour from "date") as "hour",
			row_number() over(
				partition by farm_id, ingredient_type
			) as "time_idx",
			dense_rank() over(order by farm_id) as "group",
			farm_id, id, ingredient_type, farm_area, farming_company,
			deidentified_location, temp_obs, cloudiness, wind_direction,
			dew_temp, pressure_sea_level, precipitation, wind_speed
		from test_impute;

	savepoint sp_test3;

	--don't forget the index
	create index final_test_index on final_test (
		farm_id,
		ingredient_type
	);

	--quick check
	select * from final_test;

	--let's not forget our duplicates
	select * from final_test where farm_id in (
	    'fid_54932', 'fid_68792', 'fid_81333', 'fid_18990', 'fid_71910',
	    'fid_40459', 'fid_29387', 'fid_97094', 'fid_53126', 'fid_59158',
	    'fid_122174', 'fid_26064', 'fid_73431', 'fid_68761', 'fid_63700'
	);
commit;

/* and with that, we've reached the end of directly wrangling our data in SQL.
 * We now shift into modelling our data using this crafted training dataset with
 * a very interesting piece of deep learning technology, though it's still not
 * the end: like we said, we'll be pulling our data to train on right from the
 * database with each iteration, so our little database still has some chugging
 * to do!
 */

-------------------##### PROLOGUE: DE-DUPLICATING TEST #####-------------------

/* Thus far, we've been able to predict for almost every farm there is in test
 * except for the few duplicated ones. We take care of that here. As discussed
 * in the Jupyter Notebook, these farms can't be grouped together due to their
 * `id` column having unique values for the duplicated rows, even after our
 * initial attempt at cleaning them up. Since we want a kind of `tiled` sort to
 * make predicting for them easier, we're going to rework their data a little
 * and create a separate table for them with its own index. This, hopefully,
 * should be rather straightforward; especially if followed in tandem with the
 * Jupyter Notebook.
 */
begin;
	savepoint prologue_1;

	create temporary table clean_test_dups on commit drop as
		select
			"date", farm_id,
			row_number() over(
				partition by ingredient_type, farm_id, "date"
			) as "group_idx",
			ingredient_type, id, farm_area, farming_company, deidentified_location,
			temp_obs, cloudiness, wind_direction, dew_temp, pressure_sea_level,
			precipitation, wind_speed
		from test_impute
		where farm_id in (
		    'fid_54932', 'fid_68792', 'fid_81333', 'fid_18990', 'fid_71910',
		    'fid_40459', 'fid_29387', 'fid_97094', 'fid_53126', 'fid_59158',
		    'fid_122174', 'fid_26064', 'fid_73431', 'fid_68761', 'fid_63700'
		) order by farm_id, ingredient_type, "group_idx", "date";

	select * from clean_test_dups;
	
	savepoint prologue_2;

	--now let's format our data
	create table dedup_test as
		select
		    extract(quarter from "date") as "quarter",
		    extract(month from "date") as "month",
		    extract(week from "date") as "week",
		    extract(day from "date") as "day",
		    extract(dow from "date") as "dow",
		    extract(hour from "date") as "hour",
		    row_number() over(
		        partition by group_idx, farm_id, ingredient_type
		    ) as "time_idx",
		    dense_rank() over(order by farm_id) as "group",
		    group_idx, farm_id, id, ingredient_type, farm_area,farming_company,
		    deidentified_location, temp_obs, cloudiness, wind_direction,
		    dew_temp, pressure_sea_level, precipitation, wind_speed
		from clean_test_dups;
	
	savepoint prologue_3;

	--and create our last and final index for this project
	create index dedup_test_index on dedup_test (
		group_idx,
		farm_id,
		ingredient_type
	);

	savepoint prologue_4;
	rollback to prologue_4;

	/* final checks, simulating our Python loop: we first iterate over ingreds,
	 * then for that ingredient we grab the number of farms, then for those
	 * farms we'll grab the number of groups, and finally pull one of them out
	 * for predicting keeping aside the `group_idx` and `id` columns. Yes, this
	 * is incredibly roundabout, but it's the best approach we can take given
	 * the hardware we're using. Tough. Everything looks good though, we can
	 * commit and persist our changes.
	 */
	select * from dedup_test
	where ingredient_type = 'ing_w'
	and farm_id = 'fid_122174'
	and group_idx = 2;
commit;

/* done. This SQL file pretty much documents the entire month of February 2023
 * along with supplemental context provided by the Jupyter Notebook. Until next
 * time. :)
 */
--------------------------##### END: GOOD TO GO #####--------------------------