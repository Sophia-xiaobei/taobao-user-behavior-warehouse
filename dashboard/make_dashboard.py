import pandas as pd
from pyecharts.charts import Line, Bar, Funnel, Pie, Page
from pyecharts import options as opts

# ---------- 读取数据 ----------
daily = pd.read_csv("ads_daily_overview_202610112026.csv")
funnel = pd.read_csv("ads_conversion_funnel_202610112028.csv")
repurchase = pd.read_csv("ads_repurchase_summary_202610112029.csv")
rfm = pd.read_csv("_导出_保存为_rfm_segment_csv_RFM_各分层人数_SELECT_segment_COUNT_AS_user_c_202610112030.csv")

# ---------- 图1：每日大盘趋势（双折线：uv + 转化率） ----------
line = (
    Line()
    .add_xaxis(daily["dt"].tolist())
    .add_yaxis("独立访客 UV", daily["uv"].tolist(), is_smooth=True)
    .add_yaxis(
        "浏览-购买转化率(%)",
        daily["pv_to_buy_rate"].tolist(),
        yaxis_index=1,
        is_smooth=True,
    )
    .extend_axis(
        yaxis=opts.AxisOpts(name="转化率(%)", position="right")
    )
    .set_global_opts(
        title_opts=opts.TitleOpts(title="每日大盘：访客量与转化率趋势"),
        tooltip_opts=opts.TooltipOpts(trigger="axis"),
    )
)

# ---------- 图2：转化漏斗 ----------
f = (
    Funnel()
    .add(
        "用户数",
        [
            ["浏览", int(funnel["pv_user_cnt"][0])],
            ["加购", int(funnel["cart_user_cnt"][0])],
            ["购买", int(funnel["buy_user_cnt"][0])],
        ],
        label_opts=opts.LabelOpts(position="inside"),
    )
    .set_global_opts(title_opts=opts.TitleOpts(title="用户转化漏斗"))
)

# ---------- 图3：复购率饼图 ----------
pie = (
    Pie()
    .add(
        "",
        [
            ["复购用户", int(repurchase["repurchase_users"][0])],
            [
                "单次购买用户",
                int(repurchase["total_buyers"][0] - repurchase["repurchase_users"][0]),
            ],
        ],
        radius=["40%", "70%"],
    )
    .set_global_opts(
        title_opts=opts.TitleOpts(
            title=f"复购率 {repurchase['repurchase_rate'][0]}%"
        ),
        legend_opts=opts.LegendOpts(orient="vertical", pos_left="left"),
    )
)

# ---------- 图4：RFM 用户分层柱状图 ----------
bar = (
    Bar()
    .add_xaxis(rfm["segment"].tolist())
    .add_yaxis("用户数", rfm["user_cnt"].tolist())
    .set_global_opts(title_opts=opts.TitleOpts(title="RFM 用户分层分布"))
)

# ---------- 拼成一页看板 ----------
page = Page(layout=Page.DraggablePageLayout)
page.add(line, f, pie, bar)
page.render("dashboard.html")
print("看板已生成：dashboard.html，用浏览器打开即可（图表可拖拽排版）")