# 03 · 维度建模设计文档（DIM / DWS）

## 1. 建模方法

采用 Kimball 维度建模理论，构建**星型模型**：以清洗后的用户行为明细（DWD 事实表）为中心，挂接用户、商品两张维度表；在明细之上按主题轻度聚合，形成 DWS 汇总宽表，支撑下游 ADS 指标与可视化分析。

```
              dim_user                dim_item
            （用户维度）             （商品维度）
                 \                       /
                  \                     /
        dwd_user_behavior（事实表，中心）
                  /              \
   dws_user_action_1d      dws_item_action_1d
      （用户×天汇总）        （商品×天汇总）
```

## 2. 表设计总览

| 表名 | 层 | 粒度 | 分区策略 | 存储格式 |
|---|---|---|---|---|
| dim.dim_user | DIM | 一行 = 一个用户 | 无（全量） | Parquet |
| dim.dim_item | DIM | 一行 = 一个商品 | 无（全量） | Parquet |
| dws.dws_user_action_1d | DWS | 一行 = 一个用户一天 | 按 dt 动态分区 | Parquet |
| dws.dws_item_action_1d | DWS | 一行 = 一个商品一天 | 按 dt 动态分区 | Parquet |

## 3. 字段设计与理由

### 3.1 dim.dim_user（用户维度表）

| 字段 | 设计理由 |
|---|---|
| user_id | 主键 |
| first_active_dt / last_active_dt | 衡量用户生命周期，支撑留存与流失分析 |
| active_days | 活跃天数是用户黏性的核心指标，预计算避免下游重复 count distinct |
| total_pv / total_cart / total_fav / total_buy | 四类行为累计值，直接支撑转化漏斗（阶段四 ADS 复用了本表） |

### 3.2 dim.dim_item（商品维度表）

| 字段 | 设计理由 |
|---|---|
| item_id | 主键 |
| category_id | 商品所属类目；一个商品历史上可能对应多个类目，取 MAX 做简化处理（真实业务应做拉链表记录变更，本项目数据仅 9 天，做了取舍） |
| total_pv / total_buy | 商品热度与销量基础指标 |
| buyer_cnt | 购买人数，用于区分"一人多买"与"多人购买"的商品类型 |

### 3.3 dws.dws_user_action_1d（用户行为日汇总宽表）

| 字段 | 设计理由 |
|---|---|
| user_id + dt（分区） | 粒度定为"用户×天"：日粒度是电商运营复盘的标准节奏，也避免小时级数据量膨胀 |
| pv_cnt / cart_cnt / fav_cnt / buy_cnt | 当日四类行为次数，宽表设计让下游一次查询拿到全部指标，免除多表关联 |
| active_hours | 当日活跃小时数（`COUNT(DISTINCT HOUR(behavior_time))`），衡量单日活跃深度 |
| first_time / last_time | 当日首末行为时间，可用于分析用户活跃时段分布 |

### 3.4 dws.dws_item_action_1d（商品行为日汇总宽表）

| 字段 | 设计理由 |
|---|---|
| item_id + dt（分区） | "商品×天"粒度，支撑商品级趋势分析 |
| category_id | 冗余类目字段到 DWS，下游做类目聚合时无需再关联维表（维度退化，以空间换时间） |
| pv_cnt / cart_cnt / buy_cnt | 商品当日曝光、加购、销量 |
| uv | 当日触达用户数，用于计算商品级转化率 |

## 4. 数据对账（上下游一致性校验）

数仓开发的基本要求：汇总层指标必须能回溯印证明细层。

```sql
-- DWS 汇总的 pv 总量
SELECT SUM(pv_cnt) FROM dws.dws_user_action_1d;                 -- 结果：8861025

-- DWD 明细的 pv 总量
SELECT COUNT(*) FROM dwd.dwd_user_behavior WHERE behavior_type='pv';  -- 结果：8861025
```

结果：两值**完全一致**，对账通过，证明 DWD → DWS 聚合链路无数据丢失或重复。
![4c39eae9f2ef79a8793cc0ef07a6303e](C:\Users\周湘泉\OneDrive\xwechat_files\wxid_re0rln6zsscv22_9174\temp\RWTemp\2026-10\9e20f478899dc29eb19741386f9343c8\4c39eae9f2ef79a8793cc0ef07a6303e.png)

## 5. 建模要点总结

1. **粒度优先**：建表前先明确"一行代表什么"，粒度决定了一切下游能力；
2. **宽表化**：DWS 把常用指标拍平成列，下游查询免关联、免重复计算；
3. **分区设计**：按日期分区 + 动态分区写入，支撑增量更新与分区裁剪；
4. **维度退化**：类目等高频使用、低频变更的维度属性直接冗余进 DWS，减少关联开销；
5. **可回溯**：任何一层数据都能与上游对账，保证链路可信。
