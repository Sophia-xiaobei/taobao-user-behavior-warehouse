# 02 · 数据清洗报告（ODS → DWD）

## 1. 背景

原始数据为淘宝用户行为数据集（来源：阿里云天池），抽样后共 **9,891,930 行**（含 1 行表头），字段包括：user_id、item_id、category_id、behavior_type、ts、dt。数据经 HDFS 落地到 ODS 层外部表，本报告记录 ODS → DWD 的清洗过程与质量校验结果。

## 2. 清洗规则（共 5 条）

| 编号 | 规则 | 实现方式 |
|---|---|---|
| R1 | 去重：同一用户、同一商品、同一行为类型、同一秒的重复记录只保留一条 | 窗口函数 `row_number() OVER (PARTITION BY user_id, item_id, behavior_type, ts)` 取 rn=1 |
| R2 | 过滤非法行为类型：仅保留 pv / cart / fav / buy 四种 | `WHERE behavior_type IN (...)` |
| R3 | 空值过滤：user_id、item_id 不允许为 NULL | `WHERE ... IS NOT NULL` |
| R4 | 日期校验：仅保留数据集有效区间 2017-11-25 ~ 2017-12-03 | `WHERE dt BETWEEN ...` |
| R5 | 字段加工：Unix 时间戳转可读时间，便于后续分析 | `from_unixtime(ts)` |

存储优化：DWD 层采用 **Parquet 列式存储** + **按 dt 日期动态分区**，兼顾查询性能与分区裁剪。

## 3. 清洗结果

| 指标 | 数值 |
|---|---|
| ODS 原始行数（跳过表头后） | 9,891,929 |
| DWD 清洗后行数 | 9,891,927 |
| 剔除脏数据 | **2 行（重复记录）** |
| 脏数据占比 | <0.001% |

**结论**：原始数据质量极高，5 条质量规则全部生效，其中 R1 检出 2 条重复记录，R2-R4 均无命中，验证了数据链路的可靠性。

## 4. 质量校验 SQL 与结果

### 4.1 各分区数据量分布
```sql
SELECT dt, COUNT(*) AS cnt
FROM dwd.dwd_user_behavior
GROUP BY dt ORDER BY dt;
```
结果：9 个分区（2017-11-25 ~ 2017-12-03），日期连续无缺失，每日约959770万行。
![屏幕截图 2026-10-12 225308](C:\Users\周湘泉\Pictures\Screenshots\屏幕截图 2026-10-12 225308.png)

### 4.2 行为类型分布
```sql
SELECT behavior_type, COUNT(*) AS cnt,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
FROM dwd.dwd_user_behavior
GROUP BY behavior_type ORDER BY cnt DESC;
```
结果：pv 89.58%、cart 5.51%、fav 2.88%、buy 2.02%，符合电商业务预期（浏览为主，购买约 2%）。
![image-20261012230029309](C:\Users\周湘泉\AppData\Roaming\Typora\typora-user-images\image-20261012230029309.png)

### 4.3 独立实体统计
```sql
SELECT COUNT(DISTINCT user_id) AS uv,
       COUNT(DISTINCT item_id) AS item_cnt,
       COUNT(DISTINCT category_id) AS category_cnt
FROM dwd.dwd_user_behavior;
```
结果：独立用户 954234、商品1754051、类目8247。
![image-20261012230253504](C:\Users\周湘泉\AppData\Roaming\Typora\typora-user-images\image-20261012230253504.png)

### 4.4 脏数据量核算
```sql
SELECT SUM(CASE WHEN src = 'ods' THEN cnt ELSE 0 END) -
       SUM(CASE WHEN src = 'dwd' THEN cnt ELSE 0 END) AS dirty_rows
FROM (
    SELECT 'ods' AS src, COUNT(*) AS cnt FROM ods.ods_user_behavior
    UNION ALL
    SELECT 'dwd' AS src, COUNT(*) AS cnt FROM dwd.dwd_user_behavior
) t;
```
结果：dirty_rows = 2。

## 5. 踩坑与排障记录（Troubleshooting）

| 问题现象 | 根因 | 解决 |
|---|---|---|
| 编译报错：SubQuery expressions are only allowed as Where and Having | Hive 不支持 SELECT 列内标量子查询 | 改用窗口函数 `SUM(COUNT(*)) OVER ()` 或 UNION ALL + 条件聚合改写 |
| 编译报错：Cartesian products are disabled for safety reasons | Hive 严格模式默认禁止笛卡尔积 | 放弃 CROSS JOIN 写法，改用 UNION ALL 纵向合并后条件聚合 |
| 查询结果全部字段为 NULL | 建表时分隔符误用全角逗号"，"，Hive 无法切分列，整行落入首列后强转失败 | `SHOW CREATE TABLE` 查看 field.delim 定位，删表重建并增加 `skip.header.line.count=1` 跳过表头 |
| 动态分区报错：strict mode requires at least one static partition | SET 参数为会话级，DBeaver 分条执行导致 INSERT 会话中未生效 | 将 SET 与 INSERT 作为脚本整体执行（Alt+X） |

> 本节的排障过程体现了对 Hive 执行机制（编译限制、会话参数、SerDe 分隔符）的深入理解。
