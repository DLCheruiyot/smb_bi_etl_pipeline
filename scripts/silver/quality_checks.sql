/*
=============================================================================================================================================
Quality Checks
=============================================================================================================================================
Script Purpose:
    This script performs various quality checks for data consistency, accuracy, 
    and standardization across the 'silver' layer. 
Usage Notes:
    - Run these checks after data loading Silver Layer.
    - Investigate and resolve any discrepancies found during the checks.
=============================================================================================================================================
*/

-- CHECKING SILVER.DIM_CUSTOMERS TABLE FOR COMPLETENESS

/*
Confirming cleanliness of customer records marked as complete i.e. includes full name, birthdate and zip.
silver.dim_customers table includes a field called 'data_quality_flag' that is either 'Complete' or 'Incomplete' based on combination of 
full_name, birth_date and zip.
Script below pulls all the records marked complete for eye-test on the fields mentioned above.
*/

SELECT * FROM silver.dim_customers
WHERE data_quality_flag = 'Complete';

-- CHECKING SILVER.REVENUE TABLE

--Check that all Revenue records also have a 'revenue_type' that is either Retail, Hospitality or Events. The query should result in a blank result 
SELECT TOP 1000 *
FROM silver.revenue
WHERE transaction_type = 'Revenue' AND
revenue_type IS NULL;

--Confirming that Retail Revenue records also include a retail_revenue_source entry such as WD, Square, Zelle etc. This query should be blank 
SELECT * FROM silver.revenue
WHERE revenue_type = 'Retail' AND
	  retail_revenue_source IS NULL;

--Confirming that Hospitality Revenue is ONLY from Airbnb Payments or VRBO
SELECT TOP 1000 *
FROM silver.revenue
WHERE revenue_type = 'Hospitality';

-- CHECKING SILVER.WD_ORDER_DETAILS
--Script below confirms that there are NO NULL order_numbers meaning that each record has relevant values
SELECT * FROM silver.wd_order_details
WHERE order_num IS NULL;

-- CHECKING SILVER.DIM_PRODUCTS
-- No script required as silver.dim_products has only distinct values with full records.

--CHECKING SOCIAL MEDIA AND EMAIL MARKETING TABLES IN SILVER LAYER
--check for duplicate dates in silver.instagram_data (result should be empty)
select instagram_date, count(*)
from silver.instagram_data
group by instagram_date
having count(*) > 1

--Check whether there are null values in silver.instagram_data (result should be empty)
select * FROM silver.instagram_data
WHERE instagram_interactions IS NULL OR
	  instagram_follows IS NULL OR
	  instagram_link_clicks IS NULL OR
	  instagram_reach IS NULL OR
	  instagram_visits IS NULL;

--check for duplicate dates in silver.facebook_data (result should be empty)
select facebook_date, count(*)
from silver.facebook_data
group by facebook_date
having count(*) > 1;

--Check whether there are null values in silver.facebook_data (result should be empty)
select * FROM silver.facebook_data
WHERE facebook_interactions IS NULL OR
	  facebook_follows IS NULL OR
	  facebook_link_clicks IS NULL OR
	  facebook_reach IS NULL OR
	  facebook_visits IS NULL;

--check for duplicate unique IDs in silver.mailchimp_email_marketing (result should be empty if correct)
select unique_id, count (*)
from silver.mailchimp_email_marketing
group by unique_id
having count(*) > 1;

-- Check for blank email audience or send_date in silver.mailchimp_email_marketing (result should be empty if correct)
SELECT * FROM silver.mailchimp_email_marketing
WHERE email_audience = '' OR
	  send_date = '';
