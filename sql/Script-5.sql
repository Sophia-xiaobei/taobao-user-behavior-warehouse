CREATE DATABASE IF NOT EXISTS ods;
CREATE DATABASE IF NOT EXISTS dwd;

CREATE EXTERNAL TABLE IF NOT EXISTS ods.ods_user_behavior (
    user_id        BIGINT  COMMENT '用户ID',
    item_id        BIGINT  COMMENT '商品ID',
    category_id    BIGINT  COMMENT '商品类目ID',
    behavior_type  STRING  COMMENT '行为类型：pv浏览/cart加购/fav收藏/buy购买',
    ts             BIGINT  COMMENT '行为时间戳（秒）',
    dt             STRING  COMMENT '日期'
)
COMMENT '用户行为原始数据表'
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION '/user/hive/warehouse/ods.db/ods_user_behavior'
TBLPROPERTIES ("skip.header.line.count"="1");

SELECT COUNT(*) FROM ods.ods_user_behavior;
SELECT * FROM ods.ods_user_behavior LIMIT 10;

CREATE TABLE IF NOT EXISTS dwd.dwd_user_behavior (
    user_id        BIGINT     COMMENT '用户ID',
    item_id        BIGINT     COMMENT '商品ID',
    category_id    BIGINT     COMMENT '商品类目ID',
    behavior_type  STRING     COMMENT '行为类型',
    ts             BIGINT     COMMENT '行为时间戳',
    behavior_time  TIMESTAMP  COMMENT '行为发生时间'
)
COMMENT '用户行为明细表（已清洗）'
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

INSERT OVERWRITE TABLE dwd.dwd_user_behavior PARTITION(dt)
SELECT
    user_id,
    item_id,
    category_id,
    behavior_type,
    ts,
    from_unixtime(ts) AS behavior_time,
    dt
FROM (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY user_id, item_id, behavior_type, ts
            ORDER BY ts
        ) AS rn
    FROM ods.ods_user_behavior
    WHERE user_id IS NOT NULL
      AND item_id IS NOT NULL
      AND behavior_type IN ('pv', 'cart', 'fav', 'buy')
      AND dt BETWEEN '2017-11-25' AND '2017-12-03'
) t
WHERE rn = 1;

SELECT dt, COUNT(*) AS cnt
FROM dwd.dwd_user_behavior
GROUP BY dt
ORDER BY dt;

SELECT behavior_type,
       COUNT(*) AS cnt,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
FROM dwd.dwd_user_behavior
GROUP BY behavior_type
ORDER BY cnt DESC;

SELECT COUNT(DISTINCT user_id)     AS uv,
       COUNT(DISTINCT item_id)     AS item_cnt,
       COUNT(DISTINCT category_id) AS category_cnt
FROM dwd.dwd_user_behavior;

SELECT SUM(CASE WHEN src = 'ods' THEN cnt ELSE 0 END) -
       SUM(CASE WHEN src = 'dwd' THEN cnt ELSE 0 END) AS dirty_rows
FROM (
    SELECT 'ods' AS src, COUNT(*) AS cnt FROM ods.ods_user_behavior
    UNION ALL
    SELECT 'dwd' AS src, COUNT(*) AS cnt FROM dwd.dwd_user_behavior
) t;

CREATE DATABASE IF NOT EXISTS dim;
CREATE DATABASE IF NOT EXISTS dws;

CREATE TABLE IF NOT EXISTS dim.dim_user (
    user_id          BIGINT  COMMENT '用户ID',
    first_active_dt  STRING  COMMENT '首次活跃日期',
    last_active_dt   STRING  COMMENT '最后活跃日期',
    active_days      INT     COMMENT '活跃天数',
    total_pv         BIGINT  COMMENT '累计浏览次数',
    total_cart       BIGINT  COMMENT '累计加购次数',
    total_fav        BIGINT  COMMENT '累计收藏次数',
    total_buy        BIGINT  COMMENT '累计购买次数'
)
COMMENT '用户维度表'
STORED AS PARQUET;


CREATE TABLE IF NOT EXISTS dim.dim_item (
    item_id      BIGINT  COMMENT '商品ID',
    category_id  BIGINT  COMMENT '所属类目ID',
    total_pv     BIGINT  COMMENT '累计被浏览次数',
    total_buy    BIGINT  COMMENT '累计被购买次数',
    buyer_cnt    BIGINT  COMMENT '购买人数'
)
COMMENT '商品维度表'
STORED AS PARQUET;

CREATE TABLE IF NOT EXISTS dws.dws_user_action_1d (
    user_id      BIGINT  COMMENT '用户ID',
    pv_cnt       BIGINT  COMMENT '当日浏览次数',
    cart_cnt     BIGINT  COMMENT '当日加购次数',
    fav_cnt      BIGINT  COMMENT '当日收藏次数',
    buy_cnt      BIGINT  COMMENT '当日购买次数',
    active_hours INT     COMMENT '当日活跃小时数',
    first_time   STRING  COMMENT '当日首次行为时间',
    last_time    STRING  COMMENT '当日最后行为时间'
)
COMMENT '用户行为日汇总表'
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

CREATE TABLE IF NOT EXISTS dws.dws_item_action_1d (
    item_id      BIGINT  COMMENT '商品ID',
    category_id  BIGINT  COMMENT '所属类目ID',
    pv_cnt       BIGINT  COMMENT '当日被浏览次数',
    cart_cnt     BIGINT  COMMENT '当日被加购次数',
    buy_cnt      BIGINT  COMMENT '当日被购买次数',
    uv           BIGINT  COMMENT '当日触达用户数'
)
COMMENT '商品行为日汇总表'
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

INSERT OVERWRITE TABLE dim.dim_user
SELECT
    user_id,
    MIN(dt)                                        AS first_active_dt,
    MAX(dt)                                        AS last_active_dt,
    COUNT(DISTINCT dt)                             AS active_days,
    SUM(CASE WHEN behavior_type = 'pv'   THEN 1 ELSE 0 END) AS total_pv,
    SUM(CASE WHEN behavior_type = 'cart' THEN 1 ELSE 0 END) AS total_cart,
    SUM(CASE WHEN behavior_type = 'fav'  THEN 1 ELSE 0 END) AS total_fav,
    SUM(CASE WHEN behavior_type = 'buy'  THEN 1 ELSE 0 END) AS total_buy
FROM dwd.dwd_user_behavior
GROUP BY user_id;

INSERT OVERWRITE TABLE dim.dim_item
SELECT
    item_id,
    MAX(category_id)                               AS category_id,
    SUM(CASE WHEN behavior_type = 'pv'  THEN 1 ELSE 0 END) AS total_pv,
    SUM(CASE WHEN behavior_type = 'buy' THEN 1 ELSE 0 END) AS total_buy,
    COUNT(DISTINCT CASE WHEN behavior_type = 'buy' THEN user_id END) AS buyer_cnt
FROM dwd.dwd_user_behavior
GROUP BY item_id;

SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

INSERT OVERWRITE TABLE dws.dws_user_action_1d PARTITION(dt)
SELECT
    user_id,
    SUM(CASE WHEN behavior_type = 'pv'   THEN 1 ELSE 0 END) AS pv_cnt,
    SUM(CASE WHEN behavior_type = 'cart' THEN 1 ELSE 0 END) AS cart_cnt,
    SUM(CASE WHEN behavior_type = 'fav'  THEN 1 ELSE 0 END) AS fav_cnt,
    SUM(CASE WHEN behavior_type = 'buy'  THEN 1 ELSE 0 END) AS buy_cnt,
    COUNT(DISTINCT HOUR(behavior_time))                     AS active_hours,
    MIN(CAST(behavior_time AS STRING))                      AS first_time,
    MAX(CAST(behavior_time AS STRING))                      AS last_time,
    dt
FROM dwd.dwd_user_behavior
GROUP BY user_id, dt;

SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

INSERT OVERWRITE TABLE dws.dws_item_action_1d PARTITION(dt)
SELECT
    item_id,
    MAX(category_id)                                        AS category_id,
    SUM(CASE WHEN behavior_type = 'pv'   THEN 1 ELSE 0 END) AS pv_cnt,
    SUM(CASE WHEN behavior_type = 'cart' THEN 1 ELSE 0 END) AS cart_cnt,
    SUM(CASE WHEN behavior_type = 'buy'  THEN 1 ELSE 0 END) AS buy_cnt,
    COUNT(DISTINCT user_id)                                 AS uv,
    dt
FROM dwd.dwd_user_behavior
GROUP BY item_id, dt;

SELECT COUNT(*) FROM dim.dim_user;                      -- 应等于阶段二查的 UV
SELECT COUNT(*) FROM dim.dim_item;                      -- 应等于阶段二查的商品数

SELECT SUM(pv_cnt) FROM dws.dws_user_action_1d;
SELECT COUNT(*) FROM dwd.dwd_user_behavior WHERE behavior_type = 'pv';

SELECT * FROM dim.dim_user ORDER BY total_buy DESC LIMIT 5;

SELECT u.user_id, u.buy_cnt, i.category_id
FROM dws.dws_user_action_1d u
JOIN dwd.dwd_user_behavior d ON u.user_id = d.user_id AND d.dt = '2017-12-02'
JOIN dim.dim_item i ON d.item_id = i.item_id
WHERE u.dt = '2017-12-02' AND u.buy_cnt > 0
LIMIT 10;

CREATE DATABASE IF NOT EXISTS ads;

CREATE TABLE IF NOT EXISTS ads.ads_daily_overview (
    pv              BIGINT  COMMENT '当日浏览量',
    uv              BIGINT  COMMENT '当日独立访客数',
    cart_user_cnt   BIGINT  COMMENT '当日加购人数',
    buy_user_cnt    BIGINT  COMMENT '当日下单人数',
    buy_cnt         BIGINT  COMMENT '当日购买件数',
    pv_to_buy_rate  DOUBLE  COMMENT '浏览-购买转化率(%)'
)
COMMENT '每日大盘总览'
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

INSERT OVERWRITE TABLE ads.ads_daily_overview PARTITION(dt)
SELECT
    SUM(pv_cnt)                                                     AS pv,
    COUNT(*)                                                        AS uv,
    SUM(CASE WHEN cart_cnt > 0 THEN 1 ELSE 0 END)                   AS cart_user_cnt,
    SUM(CASE WHEN buy_cnt  > 0 THEN 1 ELSE 0 END)                   AS buy_user_cnt,
    SUM(buy_cnt)                                                    AS buy_cnt,
    ROUND(SUM(CASE WHEN buy_cnt > 0 THEN 1 ELSE 0 END) * 100.0
          / COUNT(*), 2)                                            AS pv_to_buy_rate,
    dt
FROM dws.dws_user_action_1d
GROUP BY dt;

SELECT * FROM ads.ads_daily_overview ORDER BY dt;

CREATE TABLE IF NOT EXISTS ads.ads_conversion_funnel (
    pv_user_cnt    BIGINT  COMMENT '有浏览行为的人数',
    cart_user_cnt  BIGINT  COMMENT '有加购行为的人数',
    fav_user_cnt   BIGINT  COMMENT '有收藏行为的人数',
    buy_user_cnt   BIGINT  COMMENT '有购买行为的人数',
    cart_rate      DOUBLE  COMMENT '浏览-加购转化率(%)',
    buy_rate       DOUBLE  COMMENT '浏览-购买转化率(%)',
    cart_to_buy    DOUBLE  COMMENT '加购-购买转化率(%)'
)
COMMENT '全周期用户转化漏斗'
STORED AS PARQUET;

INSERT OVERWRITE TABLE ads.ads_conversion_funnel
SELECT
    COUNT(*)                                                        AS pv_user_cnt,
    SUM(CASE WHEN total_cart > 0 THEN 1 ELSE 0 END)                 AS cart_user_cnt,
    SUM(CASE WHEN total_fav  > 0 THEN 1 ELSE 0 END)                 AS fav_user_cnt,
    SUM(CASE WHEN total_buy  > 0 THEN 1 ELSE 0 END)                 AS buy_user_cnt,
    ROUND(SUM(CASE WHEN total_cart > 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS cart_rate,
    ROUND(SUM(CASE WHEN total_buy  > 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS buy_rate,
    ROUND(SUM(CASE WHEN total_buy  > 0 THEN 1 ELSE 0 END) * 100.0
          / NULLIF(SUM(CASE WHEN total_cart > 0 THEN 1 ELSE 0 END), 0), 2)       AS cart_to_buy
FROM dim.dim_user;

SELECT * FROM ads.ads_conversion_funnel;

CREATE TABLE IF NOT EXISTS ads.ads_repurchase_summary (
    total_buyers       BIGINT  COMMENT '总购买用户数',
    repurchase_users   BIGINT  COMMENT '复购用户数（不同日期购买≥2次）',
    repurchase_rate    DOUBLE  COMMENT '复购率(%)',
    avg_buy_days       DOUBLE  COMMENT '购买用户平均购买天数'
)
COMMENT '复购率汇总'
STORED AS PARQUET;

INSERT OVERWRITE TABLE ads.ads_repurchase_summary
SELECT
    COUNT(*)                                                AS total_buyers,
    SUM(CASE WHEN buy_days >= 2 THEN 1 ELSE 0 END)          AS repurchase_users,
    ROUND(SUM(CASE WHEN buy_days >= 2 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS repurchase_rate,
    ROUND(AVG(buy_days), 2)                                 AS avg_buy_days
FROM (
    SELECT user_id, COUNT(DISTINCT dt) AS buy_days
    FROM dwd.dwd_user_behavior
    WHERE behavior_type = 'buy'
    GROUP BY user_id
) t;

SELECT * FROM ads.ads_repurchase_summary;

CREATE TABLE IF NOT EXISTS ads.ads_rfm_user (
    user_id     BIGINT  COMMENT '用户ID',
    last_buy_dt STRING  COMMENT '最近购买日期',
    buy_cnt     BIGINT  COMMENT '累计购买件数',
    r_score     INT     COMMENT 'R得分',
    f_score     INT     COMMENT 'F得分',
    segment     STRING  COMMENT '用户分层'
)
COMMENT 'RFM用户分层表'
STORED AS PARQUET;

INSERT OVERWRITE TABLE ads.ads_rfm_user
SELECT
    user_id,
    last_buy_dt,
    buy_cnt,
    CASE
        WHEN datediff('2017-12-03', last_buy_dt) <= 1 THEN 5
        WHEN datediff('2017-12-03', last_buy_dt) <= 3 THEN 4
        WHEN datediff('2017-12-03', last_buy_dt) <= 5 THEN 3
        WHEN datediff('2017-12-03', last_buy_dt) <= 7 THEN 2
        ELSE 1
    END AS r_score,
    CASE
        WHEN buy_cnt >= 10 THEN 5
        WHEN buy_cnt >= 6  THEN 4
        WHEN buy_cnt >= 4  THEN 3
        WHEN buy_cnt >= 2  THEN 2
        ELSE 1
    END AS f_score,
    CASE
        WHEN datediff('2017-12-03', last_buy_dt) <= 3 AND buy_cnt >= 6 THEN '重要价值用户'
        WHEN datediff('2017-12-03', last_buy_dt) <= 3 AND buy_cnt <= 2 THEN '重要发展用户'
        WHEN datediff('2017-12-03', last_buy_dt) >= 6 AND buy_cnt >= 6 THEN '重要保持用户'
        ELSE '一般用户'
    END AS segment
FROM (
    SELECT user_id,
           MAX(dt)    AS last_buy_dt,
           COUNT(*)   AS buy_cnt
    FROM dwd.dwd_user_behavior
    WHERE behavior_type = 'buy'
    GROUP BY user_id
) t;

-- 各分层人数分布
SELECT segment, COUNT(*) AS user_cnt,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
FROM ads.ads_rfm_user
GROUP BY segment
ORDER BY user_cnt DESC;


SELECT * FROM ads.ads_rfm_user WHERE segment = '重要价值用户' LIMIT 5;

--每日大盘
SELECT * FROM ads.ads_daily_overview ORDER BY dt;

--转化漏斗
SELECT * FROM ads.ads_conversion_funnel;

-- 复购率
SELECT * FROM ads.ads_repurchase_summary;

-- RFM 各分层人数
SELECT segment, COUNT(*) AS user_cnt
FROM ads.ads_rfm_user
GROUP BY segment
ORDER BY user_cnt DESC;
































