----------------------------------------------------------------------------------------------------------------------------------------------------
--  File:       load_xtr_tvsquared_exp_ondemand.sql
-- 
--  C:\Git\SRD_AM_SNOWFLAKE\EXTRACTS\TVSQUARED\SNOWSQL\load_xtr_tvsquared_exp_ondemand.sql
--  
--  Purpose:    This sql script is loading on-demand data into TVSquared Exposure extract table
-- 
--  Script Base Version: 1.1 
-- 
--  AUDIT TRAIL
--  =======================
--  Date          Person             Version       Description
--  ----------    ------------       -------       --------------------------------
--  16-Jun-2021   Priscilla T.       1.0           SRDATA-15610: Initial Version sql
--  15-Aug-2021   Priscilla T.       2.0           Add Trim to Customer Number for client list
--  29-Nov-2021   Nanda Kumar B      3.0           SRDATA-16747: Added logic for column IMPRESSION_CONTRIBUTION
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- 

!set variable_substitution=true;
!set echo =TRUE;


--DATES TO DELETE HISTORY
CREATE OR REPLACE TEMPORARY TABLE VT_XTR_PROCESS_DT_DELETE AS (
    SELECT PROCESS_DT 
    FROM (
            SELECT PROCESS_DT
            , RANK() OVER( ORDER BY PROCESS_DT DESC ) AS RNK
            FROM &{SF_DATABASE}.&{TD_DATABASE_AM_XTR}."AM_TV_SQUARED_EXTRACT_SPOT"
            GROUP BY PROCESS_DT
          ) A
    WHERE RNK >= &{V_MAX_NUMBER_HISTORY}
);

--CLIENT LIST
CREATE OR REPLACE TEMPORARY TABLE TMP_CLIENT_LIST AS (
    SELECT 
        E.CUST_KEY AS CUSTOMER_KEY
        , C.CUST_NM AS CLIENT_NAME
        , TRIM(C.CUST_NBR) AS CUST_NBR
        , E.ECLIPSE_REGN_NM
        , (C.RBI_SRC_CD||'-'|| SUBSTR(TRIM(C.CUST_NBR), 1, 10)) AS CLIENT_ID
    FROM (SELECT 
            CUST_KEY
            , CUST_ID
            , CUST_NM
            , TRIM(CUST_NBR) AS CUST_NBR
            , CASE WHEN ECLIPSE_REGN_NM='STLOUIS' THEN 'SAINTLOUIS'
                   ELSE ECLIPSE_REGN_NM
              END AS ECLIPSE_REGN_NM
         FROM &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_EDA_CUSTOMER_DIM"
        ) E
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_EDS}."RDM_CUSTOMER" C
        ON TRIM(E.CUST_NBR)=TRIM(C.CUST_NBR)
        AND E.ECLIPSE_REGN_NM=C.RBI_SRC
        AND C.EFF_END_DT='2099-12-31'
    WHERE TRIM(c.CUST_NBR) IN ('&{v_client_list_file_content}')
);

SELECT COUNT(*) FROM TMP_CLIENT_LIST;

--LINEAR 

CREATE OR REPLACE TEMPORARY TABLE LINEAR AS (
    SELECT DISTINCT
            B.CTRC_NBR AS CAMPAIGN 
            , 'LINEAR' AS PRODUCT
            , 'CLASSIC' AS CHANNEL
            , C_LIST.CLIENT_NAME AS CLIENT_NAME
            , C_LIST.CLIENT_ID AS CLIENT_ID
            , COALESCE(G.DMA_CD, '-1') AS GEOGRAPHY
            , COALESCE(BLOCKGRAPH_ID, '-1') AS BLOCKGRAPH_ID
            , COALESCE(C.STN_NORM_NM, '-1') AS STATION
            , A.AD_EVNT_KEY AS SPOT_ID
            , COALESCE(D.SPOT_TTL, '-1') AS SPOT_NAME
            , COALESCE(A.SPOT_LGTH, '-1') AS SPOT_LENGTH
            , A.AD_EVNT_START_TS AS SPOT_START_TS_UTC
            , F.UTC_OFFST_NUM AS UTC_OFFSET
            , A.AD_EVNT_START_TS AS VIEWERSHIP_START_TS_UTC
            , A.CUST_KEY AS CUST_KEY
            , TIMESTAMPDIFF(second,A.AD_TUNING_EVNT_START_TS,A.AD_TUNING_EVNT_END_TS)/A.SPOT_LGTH as IMPRESSION_CONTRIBUTION
    FROM &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_PROGRAM_AD_TUNING_EVENT_FACT" A
    JOIN TMP_CLIENT_LIST C_LIST
        ON C_LIST.CUSTOMER_KEY = A.CUST_KEY
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_ORDER_EDA_FACT" B 
        ON A.ORD_NBR = B.ORD_NBR 
        AND A.ECLIPSE_REGN_NM=B.ECLIPSE_REGN_NM
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_STATION_NAME_OWNER_DIM" C 
        ON A.STN_KEY = C.STN_KEY 
        AND C.EFF_END_DT ='2099-12-31' 
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_EDA_SPOT_DIM" D 
        ON A.SPOT_KEY = D.SPOT_KEY 
        AND A.CUST_KEY = D.CUST_KEY
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_AD_EVENT_FACT" E  
        ON A.AD_EVNT_KEY = E.AD_EVNT_KEY 
        AND A.STN_KEY = E.STN_KEY 
        AND A.AD_EVNT_START_DT = E.AD_EVNT_START_DT
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_SYSCODE_DIM" F 
        ON E.SYSCODE = F.SYSCODE 
        AND F.EFF_END_DT= '2099-12-31' 
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_DMA_DIM" G  
        ON A.DMA_CD_KEY    = G.DMA_CD_KEY  
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_SUB_SIA_XWALK" H  
        ON A.SBSC_GUID_KEY = H.SBSC_GUID_KEY 
        AND H.SBSC_GUID_KEY <> -1  
    JOIN &{SF_DATABASE}.&{TD_DATABASE_RSTR_EDS}."XREF_AM_SUBSCRIBER" I 
        ON H.SIA_ID = I.SIA_ID
        AND CURR_FLG='Y'
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_EDA_CUSTOMER_DIM" J 
        ON A.CUST_KEY = J.CUST_KEY
    WHERE A.AD_EVNT_START_DT BETWEEN '&{v_start_dt}' and '&{v_end_dt}'
    AND A.SBSC_GUID_KEY <> -1 
);

--STREAMING 

CREATE OR REPLACE TEMPORARY TABLE TVS_NEW_ADSE_STREAM AS(
    SELECT DISTINCT 
    	AD_EVNT_KEY
    	, SITE_KEY
    	, SBSC_GUID_KEY
    	, STN_KEY
    	, DMA_KEY
    	, EVNT_UTC_TS
    	, EVNT_DUR
    	, CRTV_KEY
    	, SITE_SCTN_KEY
    	, ADVTSR_KEY
    	, CMPGN_KEY
    FROM &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AAD_EVENT_FACT" A
    WHERE EVNT_UTC_DT BETWEEN '&{v_start_dt}' and '&{v_end_dt}'
    AND SBSC_GUID_KEY <> -1
    AND EXCLUDE_REC = 0 
    AND A.EVNT_NM = 'defaultImpression'
);

--FIND AD KEY TO JOIN TO CLIENT LIST

CREATE OR REPLACE TEMPORARY TABLE VT_AD_CUST_DIM AS (
    SELECT DISTINCT
        ADVTSR_KEY AS AD_KEY 
        , ADVTSR_ID
        , ADVTSR_XTRN_ID
        , ADVTSR_NM
        , REGEXP_SUBSTR(REGEXP_REPLACE(ADVTSR_XTRN_ID, '^[^0-9a-zA-Z]|[^0-9a-zA-Z]$', ''), '[^ _-]+$') AS CUST_NBR_EID
        , REGEXP_SUBSTR(REGEXP_REPLACE(ADVTSR_NM, '^[^0-9a-zA-Z]|[^0-9a-zA-Z]&&', ''), '[^ _-]+&&') AS CUST_NBR_ANM
    FROM &{SF_DATABASE}.&{TD_DATABASE_AM_BI}.AAD_ADVERTISER_DIM
);

--FIND CUST NBR TO FIND CUST KEY
CREATE OR REPLACE TEMPORARY TABLE VT_CUST AS (
    SELECT
        TRIM(CUST_NBR) AS CUST_NBR
    FROM &{SF_DATABASE}.&{TD_DATABASE_AM_BI}.AM_EDA_CUSTOMER_DIM
);

--SUBSTEP TO FIND CUST KEY
CREATE OR REPLACE TEMPORARY TABLE VT_AD_DIM AS (
    SELECT DISTINCT
        AD_KEY 
        , ADVTSR_ID
        , ADVTSR_NM
        , CUST_NBR_EID
        , CUST_NBR_ANM
        , COALESCE(B1.CUST_NBR, B2.CUST_NBR) AS CUST_NBR
    FROM VT_AD_CUST_DIM A
    LEFT JOIN VT_CUST B1
        ON B1.CUST_NBR = A.CUST_NBR_EID
    LEFT JOIN VT_CUST B2
        ON B2.CUST_NBR = A.CUST_NBR_ANM
);

--JOIN TO CAMPAIGN TO FIND CUST KEY TO JOIN TO CLIENT LIST
CREATE OR REPLACE TEMPORARY TABLE VT_CMPGN AS (
    SELECT
          CUST.CUST_KEY
        , CUST.CUST_ID
        , CUST.CUST_NM
        , ORDR.CTRC_NBR
        , ORDR.ECLIPSE_REGN_NM
        , ORDR.ORD_NBR
        , CBO.CMPGN_START_DT AS STRT_DT
        , CBO.CMPGN_END_DT AS END_DT
        , CBO.CMPGN_KEY
        , CBO.CMPGN_ID
        , CBO.ADVTSR_ID
        , CBO.ADVTSR_NM
    FROM &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_ORDER_EDA_FACT" AS ORDR 
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_EDA_CUSTOMER_DIM" AS CUST
        ON CUST.CUST_ID = ORDR.CUST_ID
        AND CUST.ECLIPSE_REGN_NM = ORDR.ECLIPSE_REGN_NM
    JOIN (
            SELECT DISTINCT
                A.CUST_NBR
                , A.CUST_NBR_EID
                , A.CUST_NBR_ANM
                , A.ADVTSR_ID
                , A.ADVTSR_NM
                , CMPGN_NM
                , CMPGN_NBR
                , CMPGN_ID
                , CMPGN_KEY
                , CAST(CMPGN_START_TS AS DATE) AS CMPGN_START_DT
                , CAST(CMPGN_END_TS AS DATE) AS CMPGN_END_DT
            FROM &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AAD_CAMPAIGN_DIM" C
            JOIN VT_AD_DIM A
                ON C.ADVTSR_KEY = A.AD_KEY
         ) AS CBO
      ON (CBO.CMPGN_NBR LIKE '%'||ORDR.CTRC_NBR||'%' OR CBO.CMPGN_NM LIKE '%'||ORDR.CTRC_NBR||'%')
      AND (CBO.CUST_NBR_EID = CUST.CUST_NBR OR CBO.CUST_NBR_ANM = CUST.CUST_NBR)
    WHERE END_DT >= STRT_DT -- EXCLUDE CANCELLED ORDERS
);


CREATE OR REPLACE TEMPORARY TABLE STREAM_FINAL AS (
    SELECT DISTINCT 
            L.CMPGN_ID AS CAMPAIGN
            , 'STREAMING_TV' AS PRODUCT
            , COALESCE(J.SITE_NM, '-1') AS CHANNEL
            , C_LIST.CLIENT_ID AS CLIENT_ID
            , C_LIST.CLIENT_NAME AS CLIENT_NAME
            , COALESCE(F.DMA_CD, '-1') AS GEOGRAPHY
            , COALESCE(B.BLOCKGRAPH_ID, '-1') AS BLOCKGRAPH_ID
            , COALESCE(G.PARSED_DVIC_NM, '-1') AS STATION
            , H.CRTV_ID AS SPOT_ID
            , COALESCE(H.CRTV_NM, '-1') AS SPOT_NAME
            , COALESCE(A.EVNT_DUR, '-1') AS SPOT_LENGTH 
            , '-1' AS SPOT_START_TS --N/A FOR STREAMING
            , K.UTC_OFFST_NUM AS UTC_OFFSET     
            , A.EVNT_UTC_TS AS VIEWERSHIP_START_TS_UTC
    FROM TVS_NEW_ADSE_STREAM A 
    JOIN VT_CMPGN CAMP
        ON A.CMPGN_KEY = CAMP.CMPGN_KEY
    JOIN TMP_CLIENT_LIST C_LIST
        ON C_LIST.CUSTOMER_KEY = CAMP.CUST_KEY
    INNER JOIN (SELECT SIA_ID, SBSC_GUID_KEY, BLOCKGRAPH_ID
                FROM &{SF_DATABASE}.&{TD_DATABASE_RSTR_EDS}."XREF_AM_SUBSCRIBER"
                WHERE CURR_FLG='Y'
                ) B
        ON A.SBSC_GUID_KEY = B.SBSC_GUID_KEY 
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_SUBSCRIBER_DIM" D 
        ON A.SBSC_GUID_KEY = D.SBSC_GUID_KEY
        AND D.EFF_END_DT ='2099-12-31' 
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_ZIP_TO_DMA_XREF" E 
        ON D.ZIP_KEY       = E.ZIP_KEY
        AND E.EFF_END_DT ='2099-12-31' 
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_DMA_DIM" F 
        ON E.DMA_CD_KEY    = F.DMA_CD_KEY  
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AAD_SITE_SECTION_DIM" G 
        ON A.SITE_SCTN_KEY = G.SITE_SCTN_KEY 
        AND G.ACTIVE_IND = 1
        AND G.SITE_SCTN_KEY <> '-1' 
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AAD_CREATIVE_DIM" H 
        ON A.CRTV_KEY = H.CRTV_KEY  
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_ZIP_TO_SYSCODE_XREF" I 
        ON D.ZIP_KEY = I.ZIP_KEY
        AND I.SYS_EFF_END_DT = '2099-12-31'
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AAD_SITE_DIM" J 
        ON A.SITE_KEY = J.SITE_KEY 
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AM_SYSCODE_DIM" K 
        ON I.SYSCODE_KEY = K.SYSCODE_KEY
        AND K.EFF_END_DT= '2099-12-31' 
    JOIN &{SF_DATABASE}.&{TD_DATABASE_AM_BI}."AAD_CAMPAIGN_DIM" L 
        ON A.CMPGN_KEY = L.CMPGN_KEY
    WHERE K.UTC_OFFST_NUM IS NOT NULL 
    AND K. INACT_IND <> 1 
);


--DELETE FROM EXTRACT WITH SAME LOAD SEQUENCE NBR
DELETE FROM &{SF_DATABASE}.&{TD_DATABASE_AM_XTR}."AM_TV_SQUARED_EXTRACT_SPOT"
WHERE LD_SEQ_NBR = &{V_SEQ_NBR};

--DELETE FROM EXTRACT TABLE WITH SAME PROCESS DATE
DELETE FROM &{SF_DATABASE}.&{TD_DATABASE_AM_XTR}."AM_TV_SQUARED_EXTRACT_SPOT"
WHERE PROCESS_DT IN (SELECT PROCESS_DT FROM VT_XTR_PROCESS_DT_DELETE);

-----INSERT INTO EXTRACT TABLE-----

--LINEAR
INSERT INTO &{SF_DATABASE}.&{TD_DATABASE_AM_XTR}."AM_TV_SQUARED_EXTRACT_SPOT"
    SELECT
         CAST(CAMPAIGN AS VARCHAR(50))
        , PRODUCT
        , CHANNEL
        , CLIENT_NAME
        , CAST(CLIENT_ID AS VARCHAR(50))
        , GEOGRAPHY
        , BLOCKGRAPH_ID 
        , CAST(STATION AS VARCHAR(50))       
        , CAST(SPOT_ID AS NUMBER(38,0))
        , SPOT_NAME
        , SPOT_LENGTH
        , SPOT_START_TS_UTC
        , UTC_OFFSET
        , VIEWERSHIP_START_TS_UTC
        , &{V_SEQ_NBR}
        , CURRENT_DATE()
        , CURRENT_TIMESTAMP()
        , IMPRESSION_CONTRIBUTION
    FROM LINEAR;

--STREAMING
INSERT INTO &{SF_DATABASE}.&{TD_DATABASE_AM_XTR}."AM_TV_SQUARED_EXTRACT_SPOT"
    SELECT
        CAST(CAMPAIGN AS VARCHAR(50))
        , PRODUCT
        , CHANNEL
        , CLIENT_NAME
        , CAST(CLIENT_ID AS VARCHAR(50))
        , GEOGRAPHY
        , BLOCKGRAPH_ID
        , CAST(STATION AS VARCHAR(50))
        , CAST(SPOT_ID AS NUMBER(38,0))
        , SPOT_NAME
        , SPOT_LENGTH
        , SPOT_START_TS
        , UTC_OFFSET
        , VIEWERSHIP_START_TS_UTC
        , &{V_SEQ_NBR}
        , CURRENT_DATE()
        , CURRENT_TIMESTAMP()
        , 1 as IMPRESSION_CONTRIBUTION
    FROM STREAM_FINAL;
