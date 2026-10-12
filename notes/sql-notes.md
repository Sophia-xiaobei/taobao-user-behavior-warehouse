# SQL & Hive 实战踩坑笔记

> 记录淘宝用户行为数仓项目开发过程中遇到的真实问题、排查思路与解决方案。
> 持续更新。

---

## 一、Hive SQL 限制与改写

### 1. SELECT 列内不允许标量子查询

**现象**：
```
FAILED: CalciteSubquerySemanticException [Error 10249]:
Unsupported SubQuery Expression. Currently SubQuery expressions
are only allowed as Where and Having Clause predicates
```

**原因**：Hive 的编译器只允许标量子查询出现在 WHERE / HAVING 子句中，`SELECT a, (SELECT COUNT(*) FROM t) FROM ...` 这种写法直接拒绝编译。

**改写方案**：

```sql
-- ❌ 报错写法：求每组占比
SELECT behavior_type,
       COUNT(*) / (SELECT COUNT(*) FROM t) AS pct
FROM t GROUP BY behavior_type;

-- ✅ 方案一：窗口函数求总量
SELECT behavior_type,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
FROM t GROUP BY behavior_type;

-- ✅ 方案二：UNION ALL + 条件聚合
SELECT SUM(CASE WHEN src = 'a' THEN cnt ELSE 0 END) -
       SUM(CASE WHEN src = 'b' THEN cnt ELSE 0 END) AS diff
FROM (
    SELECT 'a' AS src, COUNT(*) AS cnt FROM table_a
    UNION ALL
    SELECT 'b' AS src, COUNT(*) AS cnt FROM table_b
) tmp;
```

---

### 2. 严格模式禁止笛卡尔积（CROSS JOIN）

**现象**：
```
FAILED: SemanticException Cartesian products are disabled for safety reasons.
Please set hive.strict.checks.cartesian.product to false ...
```

**原因**：Hive 严格模式（strict checks）默认拦截没有关联条件的 JOIN，防止误写导致数据量爆炸。哪怕是两个单行子查询的 CROSS JOIN 也会被拦。

**解决方案**：
- 临时放行（会话级）：
  ```sql
  SET hive.strict.checks.cartesian.product = false;
  SET hive.mapred.mode = nonstrict;
  ```
- 更推荐：改写 SQL 避免笛卡尔积（见第 1 条的 UNION ALL 方案），生产环境通常不允许随意关闭严格检查。

**经验**：能用改写解决的，就不要动安全开关。严格模式拦的是"手滑"，不是"你"。

---

### 3. SET 参数是会话级的

**现象**：
```
FAILED: SemanticException [Error 10096]:
Dynamic partition strict mode requires at least one static partition column.
```

**排查过程**：明明执行过 `SET hive.exec.dynamic.partition.mode = nonstrict;`，INSERT 还是报错。

**根因**：Hive 的 SET 只对**当前会话**生效。DBeaver 等客户端分条执行（Ctrl+Enter）时，不同语句可能跑在不同会话/连接里——SET 在会话 A 生效，INSERT 却跑在会话 B。

**解决**：把 SET 和 INSERT **作为一个脚本整体执行**（DBeaver 中全选后 Alt+X），保证同一会话按顺序执行。

**经验**：生产环境的 SQL 脚本惯例——所有 SET 写在脚本头部，与主体一起提交，永不依赖"上一条执行过"。

---

## 二、建表与数据解析

### 4. 全角字符做分隔符：不报错，但查询结果全 NULL

**现象**：表能查出行数（COUNT 正常），但 `SELECT *` 所有字段都是 NULL。

**排查思路**：
1. COUNT 正常 → 文件存在、行能读到，问题出在"列解析"；
2. `hdfs dfs -cat 文件 | head -5` 查看原始文件 → 数据本身逗号分隔、完全正常；
3. `SHOW CREATE TABLE 表名;` → 发现 `field.delim` 是全角逗号"，"！

**根因**：建表语句 `ROW FORMAT DELIMITED FIELDS TERMINATED BY '，'` 用了中文输入法的全角逗号。Hive 语法检查不拦截（它就是个普通字符），但按全角逗号切分列时一个都切不出来 → 整行落入第一个字段 → 强转 BIGINT 失败 → NULL，后续字段全部为空。

**解决**：DROP 后重建（外部表删表不删 HDFS 数据，安全），注意输入法状态。

**经验**：
- 复制 SQL 时留意输入法，标点符号必须是半角；
- 排查"能数行但查不出数据"类问题的三板斧：看原始文件（hdfs cat）→ 看表结构（SHOW CREATE TABLE）→ 看分隔符与编码。

---

### 5. CSV 表头行的处理

**现象**：数据解析正常后，第一行出现一行全 NULL 记录（表头 `user_id,item_id,...` 被当成数据）。

**解决**：建表时声明跳过表头：
```sql
TBLPROPERTIES ("skip.header.line.count"="1");
```

**经验**：这个属性只在查询时生效（读时跳过），不修改底层文件。导入含表头的 CSV 时必加。

---

### 6. 动态分区必须显式开启

向分区表 INSERT 前需要：

```sql
SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;
```

**经验**：strict 模式要求至少一个静态分区，是为了防止手滑把全表覆盖写入错误的动态分区。学习阶段带上 SET 即可，不要为省事永久关闭这个保护。

---

## 三、工具与习惯

### 7. 数据文件不要用 Excel 打开后保存

Excel 会悄悄修改数据文件：改编码（GBK/UTF-16）、改分隔符（Tab）、长数字转科学计数法、自动"纠错"。查看 CSV 用 VS Code 或记事本。

### 8. 排查类命令速查

| 场景 | 命令 |
|---|---|
| 查看 HDFS 上原始文件前几行 | `hdfs dfs -cat <path> \| head -5` |
| 查看表的真实结构（含分隔符） | `SHOW CREATE TABLE <table>;` |
| 查看分区列表 | `SHOW PARTITIONS <table>;` |
| 核对 HDFS 目录 | `hdfs dfs -ls -h <path>` |
| 查看集群状态 | 浏览器访问 9870（HDFS）/ 8080（Spark） |

### 9. 数仓开发好习惯

- ODS 层用**外部表**：删表不删数据，重建零成本（本项目的全角逗号事故因此 10 分钟修复）；
- 任何 INSERT 之后必做**对账**：上下游同一指标必须相等；
- 环境/项目路径**不含中文和空格**；
- 每踩一个坑，当场记录——这份笔记就是这么来的。

---

*最后更新：项目一（离线数仓）完成时*
