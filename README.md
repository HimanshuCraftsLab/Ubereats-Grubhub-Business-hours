# UberEats and Grubhub Business Hours Comparison

This project compares the business hours of virtual kitchens listed on UberEats and Grubhub. It uses Google BigQuery and a User-Defined Function (UDF) in JavaScript to extract and compare opening and closing times for each platform.

## Features
- Extracts regular business hours from UberEats data using a custom UDF.
- Extracts business hours from Grubhub JSON data.
- Compares time windows and identifies mismatches between the platforms.
- Reports time ranges that are in sync or out of range with up to a 5-minute difference.

## Steps to Use
1. Clone the repository.
2. Run the SQL queries in Google BigQuery.
3. View the result showing business hours mismatches for virtual restaurants on UberEats and Grubhub.

## SQL Breakdown
- **Step 1**: Define a UDF to extract regular hours from UberEats.
- **Step 2**: Extract Grubhub hours from the JSON structure.
- **Step 3**: Extract UberEats hours using the UDF.
- **Step 4**: Join Grubhub and UberEats hours to identify mismatches.
- **Step 5**: Display final output with comparison results.

## Prerequisites
- Google BigQuery account.
- UberEats and Grubhub dataset in JSON format.
