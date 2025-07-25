/*
===============================================================================
Stored Procedure: Load Silver Layer (Bronze -> Silver) for Revenue, Order Details, Customer_Dim, 
Product_Dim, Social Media Metrics, Email Marketing Metrics
===============================================================================
Script Purpose:
    This stored procedure performs the ETL (Extract, Transform, Load) process to 
    populate the 'silver' schema tables from the 'bronze' schema.
	Actions Performed:
		- Truncates Silver tables.
		- Inserts transformed and cleansed data from Bronze into Silver tables.
		
Parameters:
    None. 
	  This stored procedure does not accept any parameters or return any values.

Usage Example:
    EXEC Silver.load_silver_data;
===============================================================================
*/

CREATE OR ALTER PROCEDURE silver.load_silver_data AS
BEGIN
    DECLARE @start_time DATETIME, @end_time DATETIME, @batch_start_time DATETIME, @batch_end_time DATETIME; 
    BEGIN TRY
        SET @batch_start_time = GETDATE();
        PRINT '================================================';
        PRINT 'Loading Silver Layer';
        PRINT '================================================';

		PRINT '------------------------------------------------';
		PRINT 'Loading POS, CRM and Bankfeed Tables';
		PRINT '------------------------------------------------';

-- Loading silver.wd_order_details (This is a POS table stripped of duplicated customer and product records)
        SET @start_time = GETDATE();
		PRINT '>> Truncating Table: silver.wd_order_details';
		TRUNCATE TABLE silver.wd_order_details;
		PRINT '>> Inserting Data Into: silver.wd_order_details';
		INSERT INTO silver.wd_order_details (
			order_num,
			order_date,
			cust_num,
			prod_SKU,
			quantity,
			prod_sales_price,
			prod_item_discount,
			order_subtotal,
			order_taxes,
			order_total
		)
		SELECT --Fields below do not include the duplicative customer and product records but retain cust_num and prod_SKU for reference
		   order_num,
		   order_date,
		   cust_num,
		   prod_SKU,
		   quantity,
		   prod_sales_price,
		   prod_item_discount,
		   order_subtotal,
		   order_taxes,
		   order_total
		FROM bronze.wd_order_details
		SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

-- Loading silver.dim_customers (This table will include unique records of customers by their customer numbers)
        SET @start_time = GETDATE();
		PRINT '>> Truncating Table: silver.dim_customers';
		TRUNCATE TABLE silver.dim_customers;
		PRINT '>> Inserting Data Into: silver.dim_customers';
		
		-- First CTE is meant to establish first order date per customer to establish how long the customer has been active (tenure)
		WITH CTE_first_orders AS (
			SELECT
				cust_num,
				MIN(order_date) as first_order_date
			FROM bronze.wd_order_details
			WHERE cust_num IS NOT NULL
			GROUP BY cust_num
			)

		-- Second CTE is meant to rank the latest order per customer so that we can include in customer record for tenure calculation
			 ,CTE_ranked_customers AS (
			 SELECT
				cust_num,
				cust_status,
				cust_first_name,
				cust_last_name, 
				cust_birth_date,
				CASE                     -- This case statement nullifies junk emails based on domain name e.g. '@xyz'
					WHEN cust_email LIKE '%.com' OR
						 cust_email LIKE '%.net' OR
						 cust_email LIKE '%.org' OR
						 cust_email LIKE '%.edu'
					THEN cust_email
					ELSE NULL
				END AS clean_cust_email,
				cust_city,
				cust_state,
				CASE                      -- This case statement replaces junk zip codes with NULL
					WHEN LEN(cust_zip) = 5
					THEN cust_zip
					ELSE NULL
				END AS clean_cust_zip,
				order_date,
				ROW_NUMBER() OVER (PARTITION BY cust_num ORDER BY order_date DESC) as rank_number --Ranks the orders per cust_num by date
			FROM bronze.wd_order_details
			WHERE cust_num IS NOT NULL
		)

		--Pull final dimensions from the two CTEs above and insert into silver.dim_customers table
		INSERT INTO silver.dim_customers (
			cust_num,
			cust_status,
			cust_full_name,
			cust_birth_date,
			active_since,
			cust_email,
			cust_city,
			cust_state,
			cust_zip,
			last_order_date,
			cust_tenure_days,
			data_quality_flag
		)
		SELECT
			r.cust_num,
			CASE 
				WHEN r.cust_status IS NULL AND r.cust_first_name <> 'Guest' 
				THEN '1stTimeCustomer'
				ELSE r.cust_status
			END AS cust_status,
			r.cust_first_name+ ' ' + r.cust_last_name AS cust_full_name,
			r.cust_birth_date,
			f.first_order_date AS active_since,
			r.clean_cust_email as cust_email,
			r.cust_city,
			r.cust_state,
			r.clean_cust_zip as cust_zip,
			r.order_date as last_order_date,
			DATEDIFF(DAY, f.first_order_date, r.order_date) AS cust_tenure_days,
			CASE		--This new field marks each customer record with either 'Complete' or 'Incomplete' based on name, birth_date and zip.
				WHEN (
						r.cust_first_name IS NOT NULL OR r.cust_last_name IS NOT NULL
					 )
					AND r.cust_birth_date IS NOT NULL
					AND r.clean_cust_zip IS NOT NULL
				THEN 'Complete'
				ELSE 'Incomplete'
			END AS data_quality_flag
		FROM CTE_ranked_customers r
		JOIN CTE_first_orders f 
		ON r.cust_num = f.cust_num
		WHERE r.rank_number = 1
		   
		SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

-- Loading silver.dim_products (This table will include product details for each unique product. Prod_name and prod_type removed for privacy)
        SET @start_time = GETDATE();
		PRINT '>> Truncating Table: silver.dim_products';
		TRUNCATE TABLE silver.dim_products;
		PRINT '>> Inserting Data Into: silver.dim_products';
		
		--Use CTE to rank products by order date so as to identify latest known product info
		WITH CTE_ranked_products AS (
			SELECT 
				prod_SKU,
				prod_retail_price,
				ROW_NUMBER() OVER (PARTITION BY prod_SKU ORDER BY order_date DESC) AS rank_number -- Use latest known product by order date
			FROM bronze.wd_order_details
			WHERE prod_SKU IS NOT NULL
			  AND prod_retail_price IS NOT NULL
			  AND prod_retail_price > 0
		)

		--Pull final dimensions from the CTE above and insert into silver.dim_products table
		INSERT INTO silver.dim_products (
			prod_SKU,
			prod_retail_price
		)
		
		SELECT 
			prod_SKU,
			prod_retail_price
		FROM CTE_ranked_products
		WHERE rank_number = 1

		SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

-- Loading silver.revenue (i.e. enriched bankfeed data from bronze layer)
        SET @start_time = GETDATE();
		PRINT '>> Truncating Table: silver.revenue';
		TRUNCATE TABLE silver.revenue;
		PRINT '>> Inserting Data Into: silver.revenue';
		
		-- Defining transaction_type and revenue type from bank_transactions dataset using CTE
		WITH CTE_base_transactions AS (
			SELECT 
				bank_date,
				bank_transaction,
				bank_transaction_name,
				bank_amount,
				-- Classifying the type of transaction i.e. Revenue vs CashInjection
				CASE	
					WHEN bank_transaction = 'CREDIT' AND (
							UPPER(bank_transaction_name) = 'MOBILE CHECK DEPOSIT' OR
							UPPER(bank_transaction_name) LIKE '%ZELLE INSTANT PMT FROM CUSTOMER%' OR
							UPPER(bank_transaction_name) LIKE '%ZELLE STANDARD PMT FROM%' OR
							UPPER(bank_transaction_name) LIKE '%REAL TIME PAYMENT FROM CUSTOMER%' OR
							UPPER(bank_transaction_name) = 'ELECTRONIC DEPOSIT CASHAPP' OR
							UPPER(bank_transaction_name) = 'ELECTRONIC DEPOSIT CASH APP' OR
							UPPER(bank_transaction_name) = 'ELECTRONIC DEPOSIT JPMORGAN CHASE' OR
							UPPER(bank_transaction_name) = 'ELECTRONIC DEPOSIT POS Provider' OR
							UPPER(bank_transaction_name) = 'ELECTRONIC DEPOSIT VENMO' OR
							UPPER(bank_transaction_name) LIKE '%INTERNET BANKING TRANSFER DEPOSIT%' OR
							UPPER(bank_transaction_name) LIKE '%MOBILE BANKING TRANSFER DEPOSIT%' OR
							UPPER(bank_transaction_name) = 'DEPOSIT' OR
							UPPER(bank_transaction_name) = 'REAL TIME PAYMENT CREDIT' OR
							UPPER(bank_transaction_name) LIKE '%LOAN/LINE DEPOSIT%' OR
							UPPER(bank_transaction_name) LIKE '%CASH REWARDS REDEMPTION%'
						)
					THEN 'CashInjection'
					ELSE 'Revenue'
				END AS transaction_type,
				-- Defining revenue_type field where applicable (Hospitality vs Retail vs Events vs NULL)
				CASE 
					WHEN 
						UPPER(bank_transaction_name) IN ('ELECTRONIC DEPOSIT AIRBNB PAYMENTS', 'ELECTRONIC DEPOSIT VRBO')
					THEN 'Hospitality'
					WHEN	
						UPPER(bank_transaction_name) LIKE '%EVENTBRITE%' OR
						UPPER(bank_transaction_name) = 'ELECTRONIC DEPOSIT WWW.WINERYSITE'
					THEN 'Events'
					WHEN bank_transaction = 'CREDIT' AND (	
								UPPER(bank_transaction_name) LIKE '%ELECTRONIC DEPOSIT BANKCARD%' OR
								UPPER(bank_transaction_name) LIKE '%ELECTRONIC DEPOSIT SQUARE INC%' OR
								(
									UPPER(bank_transaction_name) LIKE '%ZELLE INSTANT PMT%' AND
									UPPER(bank_transaction_name) NOT LIKE '%ZELLE INSTANT PMT FROM CUSTOMER%'
								)
							)
					THEN 'Retail'
					ELSE NULL
				END AS revenue_type
				FROM bronze.bank_transactions
				WHERE bank_amount IS NOT NULL
			)
			--Insert script for silver.revenue
			INSERT INTO silver.revenue (
				transaction_date,
				bank_transaction,
				transaction_name,
				transaction_amount,
				transaction_type,
				revenue_type,
				winery_revenue_source
			)
		-- Pulling final table fields from CTE above and adding winery_revenue_source (e.g. WineDirect, Square etc.) to insert into silver.revenue
			SELECT
				bank_date,
				bank_transaction,
				bank_transaction_name,
			-- Randomly adjusted bank_amount (between +1% and +200%)
				CAST(bank_amount * (1 + (ABS(CHECKSUM(NEWID())) % 201) * 0.01) AS MONEY) AS transaction_amount,
				transaction_type,
				revenue_type,
			-- Derive business unit revenue source
				CASE 
					WHEN transaction_type = 'Revenue'
						AND revenue_type <> 'Hospitality' 
						AND	UPPER(bank_transaction_name) LIKE '%ELECTRONIC DEPOSIT BANKCARD%' THEN 'WD'
					WHEN transaction_type = 'Revenue'
						AND revenue_type <> 'Hospitality' 
						AND UPPER(bank_transaction_name) LIKE '%ELECTRONIC DEPOSIT SQUARE INC%' THEN 'Square'
					WHEN transaction_type = 'Revenue'
						AND revenue_type <> 'Hospitality' 
						AND UPPER(bank_transaction_name) LIKE '%ZELLE INSTANT PMT%' THEN 'Zelle'
					ELSE NULL		
				END AS retail_revenue_source
			FROM CTE_base_transactions
			WHERE transaction_type <> 'CashInjection'  --This ensures we are only capturing revenue records

		SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

	PRINT '------------------------------------------------';
	PRINT 'Loading Marketing (Social Media and Email Mktg) Metrics Tables';
	PRINT '------------------------------------------------';

	-- Loading silver.facebook_data (Daily Metrics for Facebook)
        SET @start_time = GETDATE();
		PRINT '>> Truncating Table: silver.facebook_data';
		TRUNCATE TABLE silver.facebook_data;
		PRINT '>> Inserting Data Into: silver.facebook_data';

			TRUNCATE TABLE silver.facebook_data
			INSERT INTO silver.facebook_data (
				facebook_date,
				facebook_follows,
				facebook_interactions,
				facebook_link_clicks,
				facebook_reach,
				facebook_visits
			)

			SELECT 
				facebook_date,
				facebook_follows,
				facebook_interactions,
				facebook_link_clicks,
				facebook_reach,
				facebook_visits
			FROM bronze.facebook_data

		SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

	-- Loading silver.instagram_data (Daily Metrics for Instagram)
        SET @start_time = GETDATE();
		PRINT '>> Truncating Table: silver.instagram_data';
		TRUNCATE TABLE silver.instagram_data;
		PRINT '>> Inserting Data Into: silver.instagram_data';

			INSERT INTO silver.instagram_data (
				instagram_date,
				instagram_follows,
				instagram_interactions,
				instagram_link_clicks,
				instagram_reach,
				instagram_visits
				)

			SELECT
				instagram_date,
				ISNULL(instagram_follows,0) as instagram_follows,
				instagram_interaction,
				instagram_link_clicks,
				instagram_reach,
				instagram_visits
			FROM bronze.instagram_data

		SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

	-- Loading silver.mailchimp_email_marketing (Daily Metrics for Email Marketing)
	-- Email titles and subjects have been omitted for privacy
        SET @start_time = GETDATE();
		PRINT '>> Truncating Table: silver.mailchimp_email_marketing';
		TRUNCATE TABLE silver.mailchimp_email_marketing;
		PRINT '>> Inserting Data Into: silver.mailchimp_email_marketing';

			INSERT INTO silver.mailchimp_email_marketing (
				unique_id,
				email_audience,
				send_date,
				send_time,
				send_weekday,
				total_recipients,
				successful_deliveries,
				soft_bounces,
				hard_bounces,
				total_bounces,
				times_forwarded,
				forwarded_opens,
				unique_opens,
				open_rate,
				total_opens,
				unique_clicks,
				click_rate,
				total_clicks,
				email_unsubscribes,
				abuse_complaints,
				times_liked_on_facebook
			)

			SELECT
				unique_id,
				email_audience,
				CAST(send_date AS DATE) as send_date,
				CAST(send_date AS TIME(0)) as send_time,
				send_weekday,
				total_recipients,
				successful_deliveries,
				soft_bounces,
				hard_bounces,
				total_bounces,
				times_forwarded,
				forwarded_opens,
				unique_opens,
				open_rate,
				total_opens,
				unique_clicks,
				click_rate,
				total_clicks,
				email_unsubscribes,
				abuse_complaints,
				times_liked_on_facebook
			FROM bronze.mailchimp_email_marketing

		SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

		SET @batch_end_time = GETDATE();
		PRINT '=========================================='
		PRINT 'Loading Silver Layer is Completed';
        PRINT '   - Total Load Duration: ' + CAST(DATEDIFF(SECOND, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds';
		PRINT '=========================================='
		
	END TRY
	BEGIN CATCH
		PRINT '=========================================='
		PRINT 'ERROR OCCURED DURING LOADING BRONZE LAYER'
		PRINT 'Error Message' + ERROR_MESSAGE();
		PRINT 'Error Message' + CAST (ERROR_NUMBER() AS NVARCHAR);
		PRINT 'Error Message' + CAST (ERROR_STATE() AS NVARCHAR);
		PRINT '=========================================='
	END CATCH
END
;
