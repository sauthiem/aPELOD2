
/*------------------------------------------------------------------------------------------------------------|
|	a-PELOD2                                                                                                  |
|	Automated calculation of the PELOD-2 score (Leteurtre S, et al. 2013 Crit Care Med 41:1761–1773)          |
|	                                                                                                          |
|	Author: Michael Sauthier, MD                                                                              |
|	Version 1.0, 2019-02-25                                                                                   |
|	License: AGPL v3                                                                                          |
|	Tested and validated on SQL Server 2008 revision 2                                                        |
|	                                                                                                          |
|	This script uses temporary table (#table) rather than CTE for performance reasons. But it can be easily   |
|	adapted.                                                                                                  |
|                                                                                                             |
--------------------------------------------------------------------------------------------------------------*/


/* Gather all the key-values into a temporary table #KV_temp formatted as:
	This step needs to be adapted to each electronic medical record 
	+---------------------------------------------+
	| PatientID | DatetimeUTC | Parameter | Value |
	|-----------+-------------+-----------+-------|
	|           |             |           |       |
	|-----------+-------------+-----------+-------|
	|           |             |           |       |

*/


----------------------------------
-- PaO2/FiO2 ratio calculation
-- Based on the FiO2 available in the 
-- last 60 minutes before the PaO2
----------------------------------

SELECT
	PatientID
	,DatetimeUTC
	,'PF' AS Parameter
	,(CAST(Value AS FLOAT)*100)/(SELECT TOP 1 
		CASE
			-- Depending if FiO2 is recorded as a fraction (0.21) or percentage (21)
			WHEN Value BETWEEN 0 AND 1 THEN 100*Value
			WHEN Value BETWEEN 15 AND 101 THEN Value
		END AS Value
		FROM #KV_temp
		WHERE #KV_temp.PatientID = #Gaz_table.PatientID 
			AND DATEDIFF(MINUTE, #KV_temp.DatetimeUTC, #Gaz_table.DatetimeUTC) <= 60
			AND Par = 'FiO2' AND Value > 0 
		ORDER BY #KV_temp.DatetimeUTC DESC) AS Val

INTO #KV2_temp

FROM #Gaz_table

WHERE Site = 'ARTERIAL' AND Par = 'PO2' AND Val IS NOT NULL


----------------------------------
-- linear PELOD2
-- Require the admission time, since PELOD-2
-- calcualtes per 24 hours ranges
-- Here admission time is in #Adm_temp
----------------------------------

SELECT
	#KV_temp.PatientID
	,#KV_temp.DatetimeUTC
	,FLOOR(DATEDIFF(SECOND, #Adm_temp.AdmissionTime, #KV_temp.DatetimeUTC)/86400) AS ScoreDay
	,#KV_temp.Par
	,#KV_temp.Val
INTO #PELOD2_lin
FROM #KV_temp
	INNER JOIN #Adm_temp ON #KV_temp.PatientID = #Adm_temp.PatientID
WHERE #KV_temp.Par NOT IN ('FiO2') AND #KV_temp.Val IS NOT NULL

UNION ALL

SELECT
	#KV2_temp.PatientID
	,#KV2_temp.DatetimeUTC
	,FLOOR(DATEDIFF(SECOND, #Adm_temp.AdmissionTime, #KV2_temp.DatetimeUTC)/86400) AS ScoreDay
	,#KV2_temp.Par
	,#KV2_temp.Val
FROM #KV2_temp
	INNER JOIN #Adm_temp ON #KV2_temp.PatientID = #Adm_temp.PatientID
WHERE #KV2_temp.Val IS NOT NULL


----------------------------------
-- Clean-up temporary tables
----------------------------------

DELETE FROM #PELOD2_lin WHERE ScoreDay <0

DROP TABLE #Gas_temp
DROP TABLE #KV_temp
DROP TABLE #KV2_temp


----------------------------------
-- Pivoting the table
-- Agglomerate to the most abnormal value
----------------------------------


SELECT PatientID, ScoreDay, 
	MIN(CASE WHEN Par = 'GCS' AND Val >= 3 THEN Val END) AS GCS,
	MIN(CASE WHEN Par = 'Pupil_R' THEN Val END)+MIN(CASE WHEN Par = 'Pupil_L' THEN Val END) AS Pupilles,
	MAX(CASE WHEN Par = 'Lactate' THEN Val END) AS Lactate,
	MIN(CASE WHEN Par = 'MAP' AND Val > 0 THEN Val END) AS MAP,
	MAX(CASE WHEN Par = 'Creatinine' THEN Val END) AS Creatinine,
	MIN(CASE WHEN Par = 'PF' THEN Val END) AS PF,
	MAX(CASE WHEN Par = 'PCO2' THEN Val END) AS PCO2,
	MAX(CASE WHEN Par = 'InvVent' THEN Val END) AS InvVent,
	MIN(CASE WHEN Par = 'Leucocytes' THEN Val END) AS Leucocytes,
	MIN(CASE WHEN Par = 'Platelets' THEN Val END) AS Platelets

INTO #PELOD2_abs

FROM #PELOD2_lin

GROUP BY PatientID, ScoreDay

DROP TABLE #PELOD2_lin


-------------------------
-- PELOD2_pts
-- Converting values to points
-------------------------


SELECT
	 #PELOD2_abs.PatientID
	,DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12) AS Age_m
	,CASE
		WHEN #Adm_temp.Direction = 'Dead' THEN 1
		ELSE 0
		END AS Dead

	,#PELOD2_abs.ScoreDay

	-- Neurological system
	,CASE
		WHEN #PELOD2_abs.GCS >= 11						THEN 0
		WHEN #PELOD2_abs.GCS BETWEEN 5 AND 10			THEN 1
		WHEN #PELOD2_abs.GCS BETWEEN 3 AND 4			THEN 4
		ELSE 0
		END AS Neuro_GCS
	,CASE
		WHEN #PELOD2_abs.Pupilles > 0					THEN 0
		WHEN #PELOD2_abs.Pupilles = 0					THEN 5
		ELSE 0
	END AS Neuro_pupilles

	-- Cardiovasculaire
	,CASE
		WHEN #PELOD2_abs.Lactate < 5					THEN 0
		WHEN #PELOD2_abs.Lactate BETWEEN 5 AND 10.99999	THEN 1
		WHEN #PELOD2_abs.Lactate >= 11					THEN 4
		ELSE 0
	END AS CV_lactate
	,CASE
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) < 1 THEN
			CASE
				WHEN #PELOD2_abs.MAP >= 46				THEN 0
				WHEN #PELOD2_abs.MAP BETWEEN 31 AND 45	THEN 2
				WHEN #PELOD2_abs.MAP BETWEEN 17 AND 30	THEN 3
				WHEN #PELOD2_abs.MAP <= 16				THEN 6
				ELSE 0
			END
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) BETWEEN 1 AND 11 THEN
			CASE
				WHEN #PELOD2_abs.MAP >= 55				THEN 0
				WHEN #PELOD2_abs.MAP BETWEEN 39 AND 54	THEN 2
				WHEN #PELOD2_abs.MAP BETWEEN 25 AND 38	THEN 3
				WHEN #PELOD2_abs.MAP <= 24				THEN 6
				ELSE 0
			END
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) BETWEEN 12 AND 23 THEN
			CASE
				WHEN #PELOD2_abs.MAP >= 60				THEN 0
				WHEN #PELOD2_abs.MAP BETWEEN 44 AND 59	THEN 2
				WHEN #PELOD2_abs.MAP BETWEEN 31 AND 43	THEN 3
				WHEN #PELOD2_abs.MAP <= 30				THEN 6
				ELSE 0
			END
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) BETWEEN 24 AND 59 THEN
			CASE
				WHEN #PELOD2_abs.MAP >= 62				THEN 0
				WHEN #PELOD2_abs.MAP BETWEEN 46 AND 61	THEN 2 
				WHEN #PELOD2_abs.MAP BETWEEN 32 AND 45	THEN 3 -- [MAP 45] Corrected from orginal papers with Dr. Leteurtre recommendation
				WHEN #PELOD2_abs.MAP <= 31				THEN 6
				ELSE 0
			END
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) BETWEEN 60 AND 143 THEN
			CASE
				WHEN #PELOD2_abs.MAP >= 65				THEN 0
				WHEN #PELOD2_abs.MAP BETWEEN 49 AND 64	THEN 2
				WHEN #PELOD2_abs.MAP BETWEEN 36 AND 48	THEN 3
				WHEN #PELOD2_abs.MAP <= 35				THEN 6
				ELSE 0
			END
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) >= 144 THEN
			CASE
				WHEN #PELOD2_abs.MAP >= 67				THEN 0
				WHEN #PELOD2_abs.MAP BETWEEN 52 AND 66	THEN 2
				WHEN #PELOD2_abs.MAP BETWEEN 38 AND 51	THEN 3
				WHEN #PELOD2_abs.MAP <= 37				THEN 6
				ELSE 0
			END
	END AS CV_MAP

	-- Rénal
	,CASE
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) < 1 THEN
			CASE
				WHEN #PELOD2_abs.Creatinine <= 69		THEN 0
				WHEN #PELOD2_abs.Creatinine >= 70		THEN 2
				ELSE 0
			END
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) BETWEEN 1 AND 11 THEN
			CASE
				WHEN #PELOD2_abs.Creatinine <= 22		THEN 0
				WHEN #PELOD2_abs.Creatinine >= 23		THEN 2
				ELSE 0
			END
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) BETWEEN 12 AND 23 THEN
			CASE
				WHEN #PELOD2_abs.Creatinine <= 34		THEN 0
				WHEN #PELOD2_abs.Creatinine >= 35		THEN 2
				ELSE 0
			END
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) BETWEEN 24 AND 59 THEN
			CASE
				WHEN #PELOD2_abs.Creatinine <= 50		THEN 0
				WHEN #PELOD2_abs.Creatinine >= 51		THEN 2
				ELSE 0
			END
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) BETWEEN 60 AND 143 THEN
			CASE
				WHEN #PELOD2_abs.Creatinine <= 58		THEN 0
				WHEN #PELOD2_abs.Creatinine >= 59		THEN 2
				ELSE 0
			END
		WHEN FLOOR(DATEDIFF(DAY, #Adm_temp.DateNaissance, #Adm_temp.DateAdmission)/(365.25/12)) >= 144 THEN
			CASE
				WHEN #PELOD2_abs.Creatinine <= 92		THEN 0
				WHEN #PELOD2_abs.Creatinine >= 93		THEN 2
				ELSE 0
			END
	END AS Renal

	-- Respiratoire
	,CASE
		WHEN #PELOD2_abs.PF >= 61						THEN 0
		WHEN #PELOD2_abs.PF < 61						THEN 2
		ELSE 0
	END AS Resp_PF
	,CASE
		WHEN #PELOD2_abs.PCO2 < 59						THEN 0
		WHEN #PELOD2_abs.PCO2 BETWEEN 59 AND 94.99999			THEN 1
		WHEN #PELOD2_abs.PCO2 >= 95						THEN 3
		ELSE 0
	END AS Resp_PCO2
	,CASE
		WHEN #PELOD2_abs.InvVent = 0					THEN 0
		WHEN #PELOD2_abs.InvVent = 1					THEN 3
		ELSE 0
	END AS Resp_vent_inv

	-- Hematologique
	,CASE
		WHEN #PELOD2_abs.Leucocytes > 2					THEN 0
		WHEN #PELOD2_abs.Leucocytes <= 2				THEN 2
		ELSE 0
	END AS Hemato_leuco
	,CASE
		WHEN #PELOD2_abs.Platelets >= 142				THEN 0
		WHEN #PELOD2_abs.Platelets BETWEEN 77 AND 141	THEN 1
		WHEN #PELOD2_abs.Platelets <= 76				THEN 2
		ELSE 0
	END AS Hemato_plaq

INTO #PELOD2_pts

FROM #PELOD2_abs
INNER JOIN #Adm_temp ON #PELOD2_abs.PatientID = #Adm_temp.PatientID


DROP TABLE #PELOD2_abs



-------------------------
-- Estimation of the mortality risk (logit)
-------------------------


SELECT
	*
	,(Neuro_GCS + Neuro_pupilles + CV_lactate + CV_MAP + Renal + Resp_PF + Resp_PCO2 + Resp_vent_inv + Hemato_leuco + Hemato_plaq) AS aPELOD2
	,(1 / (1 + EXP(-(-6.61 + (0.47*(Neuro_GCS + Neuro_pupilles + CV_lactate + CV_MAP + Renal + Resp_PF + Resp_PCO2 + Resp_vent_inv + Hemato_leuco + Hemato_plaq) )))) ) AS Death_probability

FROM #PELOD2_pts


DROP TABLE #PELOD2_pts
