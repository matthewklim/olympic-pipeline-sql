/* sql 

********************* The SQL below is written with Snowflake Syntax *********************

Write SQL statements to answer these questions:
1. How many accounts are there in each industry?
2. Which account_name has the highest unique users that had SUCCESS app logins in
Aug 2020?
3. Which app_names have not had any login events today?
4. What's the average time it takes from customer acquisition to having their first app login?
5. What are the top 10 app_name with the highest 30 day unique users and how many 30
day unique users do each of those 10 apps have?
6. Which app_name had the most app login events resulting in FAILURE by industry over
the past 30 days?
7. The User table given at the top reflects the current status of a user. We know that user
status can change over time with the user_status field being a slowly changing
dimension. How would you design this table (hint: adding some columns) so that we can
track the current and historical values of user_status at any given time? Please be brief

### Users

| column name   | data type   |
| ------------- | ----------- |
| user_id       | varchar(18) |
| account_id    | varchar(18) |
| user_status\* | varchar(18) |
| created_date  | timestamp   |
* ACTIVE, INACTIVE, and LOCKED_OUT

### App Login Events

| column name    | data type   |
| -------------- | ----------- |
| event_datetime | timestamp   |
| event_id       | varchar(30) |
| user_id        | varchar(18) |
| app_id         | varchar(30) |
| result\*       | varchar(15) |

*SUCCESS, FAILURE

### App

| column name | data type   |
| ----------- | ----------- |
| app_id      | varchar(30) |
| app_name    | varchar(30) |

### Account

| column name               | data type    |
| ------------------------- | ------------ |
| account_id                | varchar(18)  |
| account_name              | varchar(100) |
| customer_acquisition_date | date         |
| industry                  | varchar(50)  |


*/

/* 1. How many accounts are there in each industry? 
* assuming no duplicate account_id 
*/
SELECT 
       industry
,      COUNT(account_id)                                                                   AS account_count
FROM
       account
GROUP BY
       industry
;


/* 2. Which account_name has the highest unique users that had SUCCESS app logins in
Aug 2020? */
SELECT
       account.account_name
,      COUNT(DISTINCT app_login_events.user_id)                                            AS user_count
FROM 
       account
JOIN
       users 
ON
       account.account_id = users.account_id
JOIN 
       app_login_events e
ON
       users.user_id = app_login_events.user_id
WHERE
       app_login_events.result = 'SUCCESS'
AND
       DATE_TRUNC('month',app_login_events.event_datetime) = '2020-08-01'
GROUP BY 
       1
QUALIFY
       DENSE_RANK() OVER (ORDER BY user_count) = 1 -- return the first ranked account_name with the highest successful logins and will return multiple if tied for first
ORDER BY
       1
;


/* 3. Which app_names have not had any login events today? 
*  this query checks for login events regardless of success or failure and returns app_names that have no entries in the app_login_events table on the current day
*/
SELECT 
       app_name
FROM
       app
WHERE
       NOT EXISTS (
              SELECT TRUE
              FROM app_login_events
              WHERE event_datetime::DATE = CURRENT_DATE()
              AND app.app_id = app_login_events.app_id
              )

/* 4. What's the average time it takes from customer acquisition to having their first app login? 
* this calculates average time for only for customers that HAVE activated and excludes customers that have not activated yet
* assumes there are no app login event times before a customer has activated i.e. must be a customer first and purchased the Okta service before having any events
* this finds the first event for any user within a customer's business that is using okta
* time is calculated in terms of days
*/
WITH account_acquisition_time AS (
SELECT 
       users.account_id
,      TIMESTAMPDIFF(
              'day'
       ,      account.customer_acquisition_date
       ,      MIN(app_login_events.event_datetime)
              )                                                                            AS time_since_acquisition
FROM
       app_login_events
JOIN
       users 
ON
       app_login_events.user_id = users.user_id
JOIN
       account
ON
       users.account_id = account.account_id
GROUP BY
       users.account_id
,      account.customer_acquisition_date
       )
SELECT 
       AVG(time_since_acquisition)                                                         AS average_days_since_acquisition
,      SUM(time_since_acquisition)/COUNT(account_id)                                       AS equivalent_average_days_since_acquisition_calculation
FROM
       account_acquisition_time
;       


/* 5. What are the top 10 app_name with the highest 30 day unique users and how many 30
day unique users do each of those 10 apps have? 
* dense rank is used in case there are multiple apps there are apps that tie in the top 10
*/
SELECT 
       app_name
,      COUNT(DISTINCT users.user_id)                                                       AS unique_users
,      DENSE_RANK() OVER (ORDER BY unique_users DESC)                                      AS user_rank
FROM
       app
JOIN
       app_login_events
ON
       app.app_id = app_login_events.app_id
JOIN
       users
ON
       app_login_events.user_id = users.user_id
WHERE
       app_login_events.event_datetime >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY
       app_name
QUALIFY
       user_rank <= 10
ORDER BY
       user_rank DESC
;


/* 6. Which app_name had the most app login events resulting in FAILURE by industry over
the past 30 days? */
SELECT 
       app.app_name
,      app.industry
,      COUNT(app_login_events.event_id)                                                    AS failure_count
FROM
       app
JOIN
       app_login_events
ON
       app.app_id = app_login_events.app_id
WHERE
       app_login_events.event_datetime >= CURRENT_DATE - INTERVAL '30 days' 
AND
       app_login_events.result = 'FAILURE'
GROUP BY
       1,2
QUALIFY
       ROW_NUMBER() OVER (PARTITION BY app.industry ORDER BY failure_count) = 1 --return the highest app_name by industry - this could be dense_rank if ties matter
ORDER BY
       failure_count DESC
;


/* The User table given at the top reflects the current status of a user. We know that user
status can change over time with the user_status field being a slowly changing
dimension. How would you design this table (hint: adding some columns) so that we can
track the current and historical values of user_status at any given time? Please be brief 

* Since the user table is not a typical event log,
this could be achieved in at least a couple of ways through Change Data Capture from a platform like Fivetran or creating snapshots in a tool like dbt 
or writing manual SQL scripts.
* CDC platforms like Fivetran can capture and propagate real-time changes, enabling the tracking and synchronization of user_status changes to another system or table.
* dbt (data build tool), snapshots of the user table can be created at different points in time, capturing the user_status values. These snapshots can be managed and used for historical analysis.
* Manual SQL scripts can be used to periodically extract and store the user_status changes, involving custom SQL queries to identify and track the changes over time and storing the results in a separate table.
For simplicity, the query below modifies the existing users table, but a separate user_status table could be created.
*/


ALTER TABLE users
ADD COLUMN status_start_date timestamp,
ADD COLUMN status_end_date timestamp;


/*
For designing the slowly changing dimension in question 7, this could add a start and end timestamp to track points in time in a SCD2 type table. 
A user could join table containing all possible dates or another dataset of interest between start and end times of user status.
* The query below would return active user counts based on their status at a point in time by day which a business user could use to monitor activity.
* the output of the query is limited to a single status, such as 'ACTIVE', but it could be modified to include other statuses like 'INACTIVE' or 'LOCKED_OUT' separately as well
* User statuses have the potential to overlap where users could switch from various combinations of INACTIVE to ACTIVE or ACTIVE to LOCKED OUT
* Displaying the output in visual like a stacked bar chart may be appropriate for a business use case, but the overlap should be highlighted in the visualization for a business user to avoid confusion
*/
SELECT
       calendar_events.calendar_date
,      users.user_status
,      COUNT(DISTINCT users.user_id)                                                       AS user_count
FROM
       calendar_events
JOIN
       users
AND
       calendar_events.calendar_date BETWEEN users.status_start_time AND users.status_end_time
WHERE
       users.status = 'ACTIVE'
GROUP BY
       1,2
;
