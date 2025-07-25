/*
=====================================================================================================
DDL Script: Create Gold Views
=====================================================================================================
Script Purpose:
    This script creates views for the Gold layer in the data warehouse. 
    The Gold layer represents the final views derived from the fact tables and 
	dimensions in the silver layer (Star Schema). 

    Each view performs transformations and combines data from the Silver layer 
    to produce a clean, enriched, and business-ready dataset.

Usage:
    - These views can be queried directly for analytics and reporting.
=====================================================================================================
*/
-- ==================================================================================================
-- Create Fact Table: daily_revenue, daily_social_media_data, customer_order_summary, product_summary
-- ==================================================================================================

-- Create daily revenue summary by revenue_type for daily trend charts
IF OBJECT_ID('gold.vw_revenue_daily', 'V') IS NOT NULL
    DROP VIEW gold.vw_revenue_daily;
GO

CREATE VIEW gold.vw_revenue_daily AS
SELECT
    transaction_date,
	revenue_type,
	SUM(transaction_amount) AS total_revenue
FROM silver.revenue
WHERE transaction_date BETWEEN '2021-01-01' AND '2026-01-01'
GROUP BY transaction_date, revenue_type;
GO

-- Combine facebook and Instagram data from silver layer and create a unique_id for the table
IF OBJECT_ID('gold.fact_sm_data', 'V') IS NOT NULL
    DROP VIEW gold.fact_sm_data;
GO

CREATE VIEW gold.fact_sm_data AS
SELECT
	ROW_NUMBER() OVER (ORDER BY facebook_date) AS unique_id,
	facebook_date as dates,
	facebook_follows,
	facebook_interactions,
	facebook_link_clicks,
	facebook_reach,
	facebook_visits,
	instagram_interactions,
	instagram_follows,
	instagram_link_clicks,
	instagram_reach,
	instagram_visits,
	(facebook_follows + instagram_follows) AS total_follows, 
	(facebook_interactions + instagram_interactions) AS total_interactions,
	(facebook_link_clicks + instagram_link_clicks) AS total_link_clicks,
	(facebook_reach + instagram_reach) AS total_reach,
	(facebook_visits + instagram_visits) AS total_visits
FROM silver.facebook_data f
	 LEFT JOIN silver.instagram_data i
ON f.facebook_date = i.instagram_date;
GO

-- Create product_summary view with revenue, quantity and averages per product
IF OBJECT_ID('gold.vw_prod_summary', 'V') IS NOT NULL
    DROP VIEW gold.vw_prod_summary;
GO

CREATE VIEW gold.vw_prod_summary AS
SELECT
	w.prod_SKU,
	p.prod_retail_price AS retail_price,
	AVG(w.order_subtotal) AS avg_sales_price,
	SUM(w.quantity) AS total_prod_quantity,
	COUNT(DISTINCT w.order_num) AS orders_with_product,
	SUM(w.order_total) AS total_prod_revenue,
	SUM(w.prod_item_discount) AS total_prod_discount,
	AVG(w.prod_item_discount) AS avg_prod_discount,
	MIN(w.order_date) AS first_order_date,
	MAX(w.order_date) AS last_order_date
FROM silver.wd_order_details w
LEFT JOIN silver.dim_products p 
	  ON w.prod_SKU = p.prod_SKU
WHERE p.prod_retail_price IS NOT NULL
GROUP BY 
	w.prod_SKU,
	p.prod_retail_price;
GO

--Create customer_summary view with order totals, quantities, averages and categorization per customer
IF OBJECT_ID('gold.vw_cust_summary', 'V') IS NOT NULL
    DROP VIEW gold.vw_cust_summary;
GO

CREATE VIEW gold.vw_cust_summary AS
WITH customer_orders AS (
    SELECT 
        o.cust_num,
        COUNT(DISTINCT o.order_num) AS cust_total_orders,
        SUM(o.order_total) AS cust_total_spend,
        AVG(o.order_total) AS cust_avg_spend_per_order,
        MIN(o.order_date) AS first_order_date,
        MAX(o.order_date) AS last_order_date,
        COUNT(*) AS order_line_count
    FROM silver.wd_order_details o
    GROUP BY o.cust_num
),
	top_category AS (
    SELECT 
        o.cust_num,
        p.prod_SKU,
        COUNT(*) AS prod_count,
        ROW_NUMBER() OVER (PARTITION BY o.cust_num ORDER BY COUNT(*) DESC) AS rn --ranks most order product per cust_num
    FROM silver.wd_order_details o
    LEFT JOIN silver.dim_products p ON o.prod_sku = p.prod_sku
    GROUP BY o.cust_num, p.prod_SKU
)

SELECT 
    c.cust_num,
    c.cust_status,
    c.cust_full_name,
    c.cust_birth_date,
    c.cust_zip,

    -- Behavioral Metrics
    co.cust_total_orders,
    co.cust_total_spend,
    co.cust_avg_spend_per_order,
    co.first_order_date,
    co.last_order_date,
	c.cust_tenure_days,

    -- LTV Buckets
    CASE 
        WHEN co.cust_total_spend >= 1000 THEN 'High Value'
        WHEN co.cust_total_spend BETWEEN 500 AND 999 THEN 'Mid Value'
        WHEN co.cust_total_spend BETWEEN 1 AND 499 THEN 'Low Value'
        ELSE 'No Spend'
    END AS cust_ltv_bucket,

    -- Engagement Status (based on recency)
    CASE 
        WHEN co.last_order_date >= DATEADD(MONTH, -3, GETDATE()) THEN 'Active'
        WHEN co.last_order_date >= DATEADD(MONTH, -12, GETDATE()) THEN 'At Risk'
        ELSE 'Dormant'
    END AS cust_engagement_status,

    -- Most Purchased Product
    tc.prod_SKU AS cust_top_product

FROM silver.dim_customers c
LEFT JOIN customer_orders co ON c.cust_num = co.cust_num
LEFT JOIN top_category tc ON c.cust_num = tc.cust_num AND tc.rn = 1;
GO
