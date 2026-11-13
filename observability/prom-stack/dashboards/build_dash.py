#!/usr/bin/env python3
# 生成 LLM 推理的 Grafana dashboard JSON。部署的是生成出来的 JSON(kustomization.yaml 把它们做成 ConfigMap)。
#
#   python3 build_dash.py                 # 生成全部 4 个,写到本脚本所在目录
#   python3 build_dash.py health gpu      # 只生成指定的
#   python3 build_dash.py --stdout main   # 打印 Grafana API 的 POST body(给仍用 API 导入的集群),不写文件
#
#   main   -> llm-obs-dashboard.json     LLM推理性能指标(性能/429/引擎状态)    uid=llm-obs-bodylog
#   health -> llm-health-dashboard.json  服务健康总览(所有服务一张表 + 副本)   uid=llm-health
#   gpu    -> llm-gpu-dashboard.json     GPU硬件监控(DCGM 温度/显存/util/降频) uid=llm-gpu
#   h3     -> h3-dashboard.json          H3 视频生成                           uid=h3-video
import json, sys

DS = {"type": "prometheus", "uid": "prometheus"}
SVC = 'service=~"$service",service!="unknown"'

# 「历史副本数」面板要求 total/ready 同 service 同色 —— Grafana 调色板按【序列名】散列,
# "X total" 和 "X ready" 名字不同必然分到不同颜色,只能逐 service 定死颜色。
# 刷新列表:./promq.sh 'count by(service)(bodylog_service_replicas{service!="unknown"})'
# 不在表里的新 service 不会报错,只是回落到默认调色板(那对 total/ready 就不同色了)。
SERVICES = [
    "kimi/kimi-k25",
    "modelforge/fallback-modelforge-01",
]
PALETTE = ["#7EB26D", "#EAB839", "#6ED0E0", "#EF843C", "#E24D42", "#705DA0",
           "#508642", "#CCA300", "#447EBC", "#C15C17", "#890F02", "#0A437C"]  # 排除 unknown(非真实服务:网关拒绝/非-ModelRoute 后端/churn 残留)

# 两套 $service 变量,别混用:
#  · VAR_SERVICE_TOP —— 选项按【近 1 小时请求量】降序(topk 实测就是降序返回),不带 All、不写 current
#    → Grafana 每次加载取第一项 = 当前流量最大的 service。用于【性能】dashboard(盯单个服务)。
#    sort 必须为 0,否则 Grafana 按字母重排会丢掉流量顺序。想看多个:多选框手动勾(multi=True)。
#  · VAR_SERVICE_ALL —— 带 All 且默认 All。用于【健康总览】和【GPU】,那两个的用途就是一眼看全集群,
#    默认只剩一个服务的话整张表就废了。
VAR_SERVICE_TOP = {"name": "service", "type": "query", "datasource": DS,
                   "query": {"query": 'query_result(topk(50, sum by(service)('
                                      'rate(bodylog_requests_total{service!="unknown"}[1h]))))', "refId": "sv"},
                   "regex": '/service="([^"]+)"/', "refresh": 2, "includeAll": False, "multi": True,
                   "sort": 0, "label": "service"}
VAR_SERVICE_ALL = {"name": "service", "type": "query", "datasource": DS,
                   "query": {"query": 'label_values(bodylog_service_replicas{service!="unknown"}, service)', "refId": "sv"},
                   "regex": "/(.*?)(?:-leader)?$/", "refresh": 2, "includeAll": True, "allValue": ".*", "multi": True,
                   "current": {"text": "All", "value": "$__all"}, "sort": 1, "label": "service"}

VAR_GPU_SCOPE = {"name": "gpu_scope", "type": "custom", "label": "GPU 范围",
                 "description": "GPU 面板范围:按 service(经 pod join 只看选中服务占的卡) / 全集群(所有 GPU 主机,含空闲卡)",
                 "query": "按 service : 0, 全集群 : 1",
                 # 默认【全集群】:这是硬件监控页,先看全部机器再按需收窄才符合直觉。
                 # 之前默认「按 service」会只画出正在跑推理的那几台(空闲卡因 join 不上被整台滤掉),
                 # 看起来像「监控漏了机器」—— 实际 20 台只显示 8 台。
                 "options": [{"text": "按 service", "value": "0", "selected": False},
                             {"text": "全集群", "value": "1", "selected": True}],
                 "current": {"text": "全集群", "value": "1"}, "includeAll": False, "multi": False}

panels, _id, _y = [], [1], [0]

def reset():
    global panels
    panels = []
    _id[0], _y[0] = 1, 0

def nid():
    _id[0] += 1
    return _id[0]

def collapsed_row(title, build):
    """折叠行:默认收起,点标题才展开。

    Grafana 的 schema 要求 collapsed=True 的 row 把子面板【嵌进 row["panels"]】,
    留在顶层 panels 里会既显示在行内又显示在行外(展开时重复)。
    这里先让 build() 正常 append,再把这批捞出来搬进 row。
    """
    start = len(panels)
    y0 = _y[0]
    _y[0] += 1                      # 给 row 自己留一行
    build()
    children = panels[start:]
    del panels[start:]
    panels.append({"type": "row", "id": nid(), "title": title, "collapsed": True,
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": y0}, "panels": children})
    _y[0] = y0 + 1                  # 收起时只占 1 行高

def row(title):
    panels.append({"type": "row", "id": nid(), "title": title, "collapsed": False,
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": _y[0]}})
    _y[0] += 1

# ── 速率窗口约定 ────────────────────────────────────────────────────────────
# 【趋势图】一律用 $__rate_interval,不写死 [1m]/[5m]。
#   Grafana 按面板像素宽度决定查询步长;窗口写死而步长变大时,每个点只覆盖步长里的
#   一小段,其余时间【根本没被采样】—— 不是平滑掉了,是真丢。实测(24h 真实均值
#   0.2108 req/s,step=1200s 即 7 天视图):rate[1m] 采样均值 0.3195(+51.6%),
#   rate[5m] 0.1897(-10.0%),rate[20m] 0.2091(-0.8%)。
#   $__rate_interval = max($__interval + scrape, 4 x scrape),窗口恒 >= 步长,时间轴完整覆盖。
#
# 已知代价(2026-08-27 权衡后接受,同时写进各面板 description,免得被当 bug 查):
#   ① 短范围窗口反而变大(下限 2m = 4 x 30s scrape)。TPM 由 1m 变 2m,实测 3 小时视图
#      峰值 2,105,812 -> 1,619,376(-23%)、p99 -26% —— 短突发在图上会矮一截。
#   ② 长范围查询变慢约 2 倍:7 天视图 rate[1m] 222ms/18 万样本 -> rate[20m] 406ms/366 万样本。
#   ③ 窗口依赖面板像素宽度 -> 同一面板全屏与缩小时数值不同,截图对不上。
#
# 【故意不改】的地方,窗口必须稳定,否则没法比阈值:
#   - health_table() 的 QPS / 错误率 / TTFT_p95(固定 5m,与告警规则同口径)
#   - 重启24h(固定 24h:那是语义定义,不是平滑参数)
#   - live() 的 last_over_time([10m]):判 service 是否仍存在,与采样精度无关
RATE_NOTE = ("  ⏱ 速率窗口 = $__rate_interval(随所选时间范围自适应,下限 2m)。"
             "写死窗口在长时间范围下每个点只覆盖步长里的一小段、其余时间不被采样,实测 7 天视图偏高 52%。"
             "代价:①短范围窗口反而变大(1m→2m),3 小时视图峰值实测 -23%,短突发会显得矮;"
             "②长范围查询慢约 2 倍;③窗口随面板像素宽度变 —— 同一面板全屏和缩小时数值会不同,截图对不上。"
             "「服务健康总览」表和告警规则仍用固定 5m(比阈值的口径必须稳定),与本图数值对不上是正常的。")

def ts(title, targets, unit="short", w=8, x=0, y=None, desc="", stacking=False, interval=None, minv=None, maxv=None, drawstyle="line", timeFrom=None, overrides=None, fill=None, legend_calcs=None, linestyle=None, tooltip_mode="multi", tooltip_sort=None, transformations=None, h=8, thresholds=None, thr_style=None):
    # thresholds / thr_style:在图上画阈值参考线,如 thresholds=[("green",0),("#EAB839",30),("red",55)]、thr_style="dashed"。
    if y is None:
        y = _y[0]
    tg = [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "datasource": DS} for i, (e, l) in enumerate(targets)]
    custom = {"drawStyle": drawstyle, "fillOpacity": 12 if drawstyle == "line" else 60, "showPoints": "never", "lineWidth": 1}
    if stacking:
        custom["stacking"] = {"mode": "normal"}
    if fill is not None:
        custom["fillOpacity"] = fill
    if linestyle is not None:
        custom["lineStyle"] = linestyle
    if thr_style is not None:
        custom["thresholdsStyle"] = {"mode": thr_style}
    fc = {"defaults": {"unit": unit, "custom": custom}, "overrides": overrides or []}
    if thresholds is not None:
        fc["defaults"]["thresholds"] = {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in thresholds]}
    if minv is not None:
        fc["defaults"]["min"] = minv
    if maxv is not None:
        fc["defaults"]["max"] = maxv
    p = {"type": "timeseries", "id": nid(), "title": title, "datasource": DS, "description": desc,
         "gridPos": {"h": h, "w": w, "x": x, "y": y}, "targets": tg, "fieldConfig": fc,
         "options": {"legend": ({"displayMode": "table", "placement": "bottom", "showLegend": True,
                                 "calcs": legend_calcs} if legend_calcs else
                                {"displayMode": "list", "placement": "bottom", "showLegend": True}),
                     # tooltip_sort 只有 none/asc/desc,且 asc/desc 是【按值】排 —— 想要自定义顺序
                     # 只能给 none,此时 tooltip 按 target 的查询顺序列,所以顺序由 targets 的排列决定。
                     "tooltip": {"mode": tooltip_mode,
                                 "sort": tooltip_sort if tooltip_sort is not None
                                         else ("desc" if tooltip_mode == "multi" else "none")}}}
    if interval:
        # 面板最小步长:把 $__interval(以及由它推出的 $__rate_interval)顶到这个值以上,
        # 免得缩放变细时窗口跟着变短、稀疏事件被切成一堆 0/1 的锯齿。
        p["interval"] = interval
    if timeFrom:
        p["timeFrom"] = timeFrom
    if transformations:
        p["transformations"] = transformations
    panels.append(p)

def statetimeline(title, expr, legend, w=16, x=0, desc="", mappings=None, thresholds=None, unit="short"):
    if mappings is None:
        mappings = [{"type": "value", "options": {"0": {"text": "DOWN", "color": "red"}, "1": {"text": "UP", "color": "green"}}}]
    if thresholds is None:
        thresholds = {"steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]}
    panels.append({"type": "state-timeline", "id": nid(), "title": title, "datasource": DS, "description": desc,
                   "gridPos": {"h": 8, "w": w, "x": x, "y": _y[0]},
                   "targets": [{"refId": "A", "expr": expr, "legendFormat": legend, "datasource": DS}],
                   "fieldConfig": {"defaults": {"unit": unit, "min": 0, "max": 1, "custom": {"fillOpacity": 80},
                                   "mappings": mappings, "thresholds": thresholds}, "overrides": []},
                   # showValue=never:状态文案只在 tooltip 里出现,不印在色块上
                   # mergeValues=False:合并会让 tooltip 显示【整段的起始时刻】而非鼠标处时刻
                   #   (实测显示 15:24,而坐标轴左边缘是 15:40 —— 那是这段状态的起点)
                   #   不合并 = 每个采样点自成一段,tooltip 时刻 ≈ 鼠标位置
                   "options": {"showValue": "never", "mergeValues": False,
                               # 不显式给 tooltip,Grafana 13 hover 不出时刻/取值
                               "tooltip": {"mode": "single", "sort": "none", "hideZeros": False},
                               "legend": {"showLegend": True, "displayMode": "list", "placement": "bottom"}}})

def mrg(rate_expr):
    # 把 service 尾缀 -leader(迁移前 LWS 过期 series)剥成 base 名 → kimi/kimi-k25-leader 并入 kimi/kimi-k25
    return 'label_replace(%s, "service", "$1", "service", "(.*)-leader$")' % rate_expr

def eng(sel):
    # 引擎(sglang/vllm)指标的 service label 是 k8s Service 名(kimi-k25-leader),
    # 跟 bodylog/openresty 的 "<ns>/<name>" 口径不是一套 → 归一:剥 -leader 再拼 namespace/
    #   kimi + kimi-k25-leader  ->  kimi/kimi-k25
    strip = 'label_replace(%s, "service", "$1", "service", "(.*?)(?:-leader)?")' % sel
    return 'label_join(%s, "service", "/", "namespace", "service")' % strip

def flt(expr):
    # 按 $service 过滤 + 甩掉已下线的旧 service:
    # and on(service) 只保留在【当前时间窗内仍被 bodylog 发现】的 service,
    # 归一后对不上活服务的历史 Service 名(如 kimi-sglang-sglang-svc)自然消失。
    return '(%s)\n  and on(service) (count by(service)(bodylog_service_replicas{%s}))' % (expr, SVC)

# 时间窗末尾仍在上报 = "当前存在"。与 flt() 的区别很关键:
#   flt()  的 and on(service) 是【逐时间点】求值 —— 旧服务在它还活着的那些时刻依然通过,
#          所以拉长时间范围时它照样进图例(实测:kimi-k25/kimi-k25 等已删服务仍显示)。
#   live() 用 @ end() 把右边【固定在时间范围末尾】求值,只有此刻仍有数据的 service 才留下,
#          但左边的历史曲线完整保留(不会只剩一个点)。
#   [10m] + last_over_time 是为了容忍一次采集抖动,比裸 @ end() 宽松(见 LIVE_WINDOW)。
LIVE_WINDOW = "10m"

def live(expr):
    return ('(%s)\n  and on(service) (count by(service)('
            'last_over_time(bodylog_service_replicas{service!="unknown"}[%s] @ end())))'
            % (expr, LIVE_WINDOW))

# pod -> service 映射向量(值恒 1,供 DCGM 这类没有 service label 的指标 join)
# 两段并集,否则 LWS 的 worker pod 占的 GPU 归不到 service:
#   ① leader/单 pod —— 直接来自引擎指标(只有 leader 被 ServiceMonitor 抓)
#   ② LWS worker   —— worker 的 owner StatefulSet 名【就等于 leader 的 pod 名】
#      (kimi-k25-0-1 --owner--> StatefulSet kimi-k25-0 == leader pod),
#      拿 kube_pod_owner 搭桥 join 回 ① 拿到 service
_ENGSEL = '{__name__=~"sglang:num_running_reqs|vllm:num_requests_running"}'
LEADER2SVC = '(0 * %s + 1)' % eng('max by(namespace,pod,service)(%s)' % _ENGSEL)
WORKER2SVC = ('max by(namespace,pod,service)(\n'
              '  label_replace(kube_pod_owner{owner_kind="StatefulSet"}, "leader_pod", "$1", "owner_name", "(.+)")\n'
              '  * on(namespace,leader_pod) group_left(service)\n'
              '    label_replace(%s, "leader_pod", "$1", "pod", "(.+)"))') % LEADER2SVC
POD2SVC = '(max by(namespace,pod,service)(%s)\n   or %s)' % (LEADER2SVC, WORKER2SVC)

HOSTF = 'Hostname=~"$host",modelName=~".*$gpu_model.*"'   # GPU 主机 + 型号过滤,A/B 两支都要带上

def gpu(agg, metric, rng=None):
    """DCGM 硬件指标:只按 GPU 主机 / 型号过滤,**不按 $service 过滤**。

    以前这里会经两层内连接把 DCGM 关联到 service:
        ① DCGM * on(namespace,pod) group_left(service) POD2SVC
        ② flt(): and on(service) count by(service)(bodylog_service_replicas)
    好处是曲线能按 $service 过滤,代价是【没跑服务的卡整台从图里消失】——
    而且 $service 选 All 也回不来:All 只放宽②的正则,挡在前面的①仍在。
    实测:h100-29 空闲时 DCGM 数据在 Prometheus 里齐全(8 张卡温度都有)、
    上方一览表也显示得出,但三个趋势图全是 No data,查一台机器的硬件状态反而没法看。

    这些是【硬件】指标:温度、显存、利用率、降频,本来就属于机器而不属于某个 service。
    空闲机器恰恰是最需要看的场景之一(刚重装、待分配、怀疑硬件有问题)。
    所以去掉 join —— service 下拉对这几个图不再起作用,要按服务看占用请用上方一览表。
    """
    sel = 'rate(%s{%s}[%s])' % (metric, HOSTF, rng) if rng else '%s{%s}' % (metric, HOSTF)
    return [('%s by(Hostname)(%s)' % (agg, sel), "{{Hostname}}")]


def gpu_percard(metric, rng=None):
    """每张卡一条 series,配合 PERCARD_HIDE 只在 tooltip 里出现。

    主曲线是 by(Hostname) 聚合后的(每机一条,图才看得清),但排查时想知道
    "是哪张卡热/哪张卡在降频" —— 展开成 8 条画出来图就废了。
    Grafana 的 hideFrom 正好能做到:从图形和图例里隐藏,但 tooltip 仍列出。

    **只在筛选到单台机器时才出数据**:`and on() (count(...) == 1)`。
    多机时逐卡会有 8 x N 条,tooltip 里几十行混在一起根本没法读(20 台就是 160 行),
    而且那种场景下你要的是机器间对比,不是某张卡。所以多机自动退化成"每机一条"。
    想看逐卡就把顶部「GPU 主机」筛到一台 —— 这也正是排查单机时的自然操作。
    """
    sel = 'rate(%s{%s}[%s])' % (metric, HOSTF, rng) if rng else '%s{%s}' % (metric, HOSTF)
    one_host = 'count(count by(Hostname)(%s{%s})) == 1' % (metric, HOSTF)
    return ('max by(Hostname,gpu)(%s)\n  and on() (%s)' % (sel, one_host), "{{Hostname}} #{{gpu}}")


# 匹配 "<host> #<n>" 这种 legend:从图形和图例隐藏,只留 tooltip。
# 注意三个开关的语义是"是否隐藏":viz/legend 为 true = 隐藏,tooltip 为 false = 不隐藏。
PERCARD_HIDE = [{"matcher": {"id": "byRegexp", "options": ".* #\\d+$"},
                 "properties": [{"id": "custom.hideFrom",
                                 "value": {"viz": True, "legend": True, "tooltip": False}}]}]


# 只选中一个 service 时,把 legend 里的 "<service> " 前缀剥掉(图例已经够长了)。
# 原理:正则里的 $service 会被 Grafana 先做变量插值 ——
#   单选 -> "^modelforge/fallback-modelforge-01 (.*)$"  匹配,前缀被剥
#   多选 -> 插值成 "{a,b}" 形式,正则匹配不上,前缀原样保留(多选时正是需要前缀区分)
# 只剩 service 本身一条(没有后缀)的面板不受影响:正则要求前缀后面还有内容。
STRIP_SVC = [{"id": "renameByRegex", "options": {"regex": "^$service (.*)$", "renamePattern": "$1"}}]

LEGEND_CALCS = ["lastNotNull", "max"]   # 表格图例列出的统计量:当前值 / 区间峰值
# 明细(每实例 / 每 reason)走 defaults 的虚线,「<service> 汇总」override 回实线并加粗
DASH = {"fill": "dash", "dash": [10, 10]}
TOTAL_OV = [{"matcher": {"id": "byRegexp", "options": ".* 汇总$"},
             "properties": [{"id": "custom.lineStyle", "value": {"fill": "solid"}},
                            {"id": "custom.lineWidth", "value": 3}]}]

def eng_panel(agg, metrics):
    # 每个 metric(sglang / vllm 两套名字)出两个 target:
    #   ① 该 service 的汇总(sum 面板求和 / avg 面板求均值)—— 常驻
    #   ② 每实例(pod)明细 —— 默认【不显示】,顶部「实例明细」下拉切到「显示」才画
    # 明细默认关是因为 modelforge 有 34 个副本,一上来 34 条细线会把汇总线埋掉。
    # 开关同 $gpu_scope 手法:`and on() (vector($eng_pods) == 1)`,为 0 时右侧空 vector,整条 target 消失。
    tg = []
    for m in metrics:
        tg.append((flt('%s by(service)(%s)' % (agg, eng(m))), "{{service}} 汇总"))
        tg.append(('%s\n  and on() (vector($eng_pods) == 1)' % flt('max by(service,pod)(%s)' % eng(m)), "{{pod}}"))
    return tg

# TTFT 专用:扣掉非流式请求。
# 背景:bodylog 的 details jsonl 里 stream 字段【只在流式时才写】,非流式是【没有这个键】,
#      所以 exporter 的 streamLabel 给出的 "unknown" 实际就等于非流式。
#      而 exporter 对 TTFT 的过滤条件是 `if d.Frt > 0`,注释以为"非流式 frt=0" —— 实际非流式
#      的 first_chunk_t ≈ rt(只有一个 body chunk,它到达时响应就结束了),恒 > 0,一条都没滤掉。
#      后果:TTFT 直方图里混进大量 frt≈rt 的非流式样本,实测 p99 甚至【超过】RT p99(物理不可能)。
# 不改 exporter 的绕法:非流式的 frt≈rt,而 rt 指标【带 stream 标签】,
#      于是 ttft(全部) - rt(stream="unknown") 就把非流式那部分扣掉了(native histogram 可直接相减)。
# 实测:相减后样本数 1.6481/s ≈ 实际流式请求 1.7000/s(差 3%,来自 ms 取整与时间对齐);
#      p90 从 31.98s(混合)降到 0.34s(纯流式)。
# ⚠️ 这是【近似】:根治要让 exporter 按 stream 过滤,或给 ttft 指标补 stream 标签。
# 窗口必须与被减数(hgram 里的 ttft)一致,否则两个分布的时间基准不同,相减无意义
TTFT_MINUS_NONSTREAM = 'sum by(service)(%s)' % mrg('rate(bodylog_rt_seconds{stream="unknown",%s}[$__rate_interval])' % SVC)

# 「是否需要扣非流式」的自动判据 —— 最近锚点分类,不含任何阈值魔数。
# TTFT 的观测数只可能贴近两个锚点之一:
#   exporter 坏着(现状)-> ttft 观测数 == 【全部】请求数(它把非流式也记进去了)
#   exporter 修好      -> ttft 观测数 == 【流式】请求数
# 所以问「离哪个锚点更近」即可,任意非流式占比都判得准。
# (原先用 ttft > 1.5 x 流式 的阈值法:等价于要求非流式占比 >33% 才判得出来,
#  一个只有 20% 非流式的服务会被漏判、污染一直留在图上。)
# 实测 modelforge:ttft 3.1296 / 全部 3.1333 / 流式 0.5741 -> 贴全部 -> 需扣;
#      kimi:三者都是 0.0889(本来全流式)-> 不扣(此时减法也是空操作)。
# `or (0 * ttft)`:某 service 完全没有流式请求时右侧缺失,补 0 以免整条比较消失。
# ⚠️ 判据的窗口必须与数据侧一致(都用 $__rate_interval)。
#    若判据固定 5m 而数据是 $__rate_interval:长范围下 step 涨到 30m、判据窗口仍 5m,
#    83% 的求值点上判据算不出值 -> `and on(service)` 匹配失败 -> 整个面板变空白。
_TTFT_N = 'histogram_count(sum by(service)(%s))' % mrg('rate(bodylog_ttft_seconds{%s}[$__rate_interval])' % SVC)
_ALL_N = 'sum by(service)(%s)' % mrg('rate(bodylog_requests_total{%s}[$__rate_interval])' % SVC)
_STREAM_N = 'sum by(service)(%s)' % mrg('rate(bodylog_requests_total{stream="true",%s}[$__rate_interval])' % SVC)
TTFT_CONTAM = '(abs(%s - %s) < bool abs(%s - (%s or (0 * %s))))' % (
    _TTFT_N, _ALL_N, _TTFT_N, _STREAM_N, _TTFT_N)

def ttft_gated(full, minus):
    """自动决定要不要扣掉非流式,不再有人工开关。

    判据 TTFT_CONTAM 逐 service 判:ttft 观测数显著多于流式请求数 = 混进了非流式 -> 扣;
    否则(含 exporter 修好后的情形)直接用原值,天然不会重复扣减。
    `or full`:某 service 当前没有非流式流量时,减法向量匹配失败会整条 series 消失
    (实测 kimi/kimi-k25 就这样没了),回落到未扣减的原值。
    """
    sub = '((%s\n      - %s)\n      or %s)' % (full, minus, full)
    return ('(%s and on(service) (%s == 1))\n'
            '  or (%s and on(service) (%s == 0))') % (sub, TTFT_CONTAM, full, TTFT_CONTAM)

def hgram(title, base, unit, w, x, desc="", transformations=None, minus=None, invert=False, thresholds=None, thr_style=None):
    # 直方图面板:分位由 $quantile 下拉切 + avg 常驻参考线。
    # invert=True 用于**越大越好**的指标(如单请求生成速率 tok/s):
    #   这类指标的"差"在**低端**,直接取 $quantile 的高分位等于在看"最快的那批能跑多快",
    #   后端再慢只要还有少数快请求,曲线依然好看 —— 对发现问题没有用。
    #   所以内部改取 1-q。配合下拉统一的「覆盖率」语义,选 pN 在两类面板上读法一致:
    #     TTFT   p95 → histogram_quantile(0.95) → 「95% 的请求不慢于 X 秒」
    #     生成速率 p95 → histogram_quantile(1-0.95=0.05) → 「95% 的请求不低于 Y tok/s」
    #   这样用户只需理解一个概念(N% 的请求),不必每次判断该选高位还是低位。
    #   PromQL 里 `1 - 0.95` 是合法的标量表达式,histogram_quantile 第一参可直接接受。
    # ⚠️ 用 native histogram(裸指标名)而不是经典的 _bucket:
    #    经典桶的上界是 10,所有 >10s 的请求都被压进最后一个桶,分位数直接卡死在 10 —
    #    实测 TTFT p90:_bucket 报 10.0s,native 报 32.8s,前者把整条长尾截没了。
    #    native 没有 le 标签,所以是 sum by(service) 而不是 by(service,le)。
    #    avg 也换成 histogram_avg(同一份 native 数据),不再用 _sum/_count 两条经典序列。
    # 窗口用 $__rate_interval 而非固定 5m:Grafana 按 max($__interval + scrape, 4*scrape) 算,
    # 随时间范围自适应。固定 5m 在长范围下会漏采 —— step 会涨到 30m 而窗口还是 5m,
    # 时间轴只有 16.7% 落在求值窗口里,实测 24h 内 72 个高峰点只覆盖到 9 个(12.5%),
    # 落在盲区的异常在图上不留任何痕迹。换成 $__rate_interval 后窗口首尾相接,覆盖 100%。
    # 代价:同一个分位在不同时间范围下数值会变(窗口宽了更平滑),排查时别跨缩放级别对数。
    # health 表的 TTFT_p95 仍用固定 5m —— 那是当前值快照、将来要挂告警,口径必须稳定。
    h = 'sum by(service)(%s)' % mrg('rate(%s{%s}[$__rate_interval])' % (base, SVC))
    if minus:
        h = '(%s)' % ttft_gated(h, minus)
    # ⚠️ $quantile 的值是【百分数】(90 / 99.9 / 72),不是小数 —— 查询里除以 100 再用。
    #    为什么这么设计:变量开了 allowCustomValue,用户自定义时最自然的输入就是 "72"。
    #    若值直接当小数用,histogram_quantile(72, ...) 【不报错】,静默返回 +Inf(实测),
    #    图上画一条无穷大而没有任何提示 —— 静默算错比报错危险得多。
    #    改成百分数后,输 72 恰好就是 p72;预设 90 也走同一条路径,两者语义统一。
    q   = '((100 - $quantile) / 100)' if invert else '($quantile / 100)'
    # 标题/图例统一加 p 前缀,所以预设选项的 text 是 "90" 而不是 "p90" —— 否则会显示成 "pp90"。
    leg = "{{service}} p${quantile:text}保障" if invert else "{{service}} p${quantile:text}"
    p = 'histogram_quantile(%s, %s)' % (q, h)
    a = 'histogram_avg(%s)' % h
    ts(title, [(p, leg), (a, "{{service}} avg")], unit=unit, w=w, x=x, minv=0, desc=desc,
       transformations=transformations, thresholds=thresholds, thr_style=thr_style)

# ── 副本数三口径 ────────────────────────────────────────────────────────────
# 就绪 / 期望 / 实际。判「降级」只能拿【就绪】比【期望】,不能比【实际】:
# 实际 = EndpointSlice 的 endpoint 数,滚动更新时 maxSurge 会把它抬高
# (实测 kimi 一次 rollout:就绪 2 / 实际 3 / 期望 2 —— 服务是满的,却被判成降级)。
# desired 由 exporter 沿 ownerRef 上溯顶层工作负载取 spec.replicas 得来;
# 查不到时那条 series 不存在(裸 pod / RBAC 不足),此处 `or` 回退到实际数
# —— 退化成改动前的老口径,而不是让整行空掉。
# ⚠️ 中间那层 `avg by(service,route)` 是为了【把 instance 维度聚合掉】,不能省。
# 直接 sum by(service) 会连 instance 一起求和:exporter 滚动更新时新旧两个 pod 的 series
# 在 Prometheus 的 staleness 窗口里短暂并存(旧 pod 已删、series 还能查到 ~5min),
# 于是每个副本数被算两遍 —— 图上是一根尖峰(实拍 2026-08-27 13:16 升级 exporter:
# modelforge 17→34、kimi 2→4),表格里则是三口径集体翻倍。
# avg 而非 max:两个 exporter 读同一份 bodylog,同一个 (service,route) 的值本就相同,
# avg 取回它自己;真要跑分片双活(各读一部分节点)得先解决数据分片,那时这里也要重新想。
def _repl(metric, filt='service=~"$service",service!="unknown"'):
    per_route = 'avg by(service, route)(%s)' % mrg('%s{%s}' % (metric, filt))
    return 'sum by(service)(%s)' % per_route

def repl_ready(filt=None):
    return _repl('bodylog_service_replicas_ready', filt) if filt else _repl('bodylog_service_replicas_ready')

def repl_actual(filt=None):
    return _repl('bodylog_service_replicas', filt) if filt else _repl('bodylog_service_replicas')

def repl_desired(filt=None):
    d = _repl('bodylog_service_replicas_desired', filt) if filt else _repl('bodylog_service_replicas_desired')
    return '(%s\n  or %s)' % (d, repl_actual(filt))

def up_panel():
    # 值 = 就绪比例 ready/【期望】(0~1,percentunit 显示成 50%),这样 tooltip 能看出【降级程度】
    # (三态 0/1/2 只能显示 UP/降级/DOWN 文字,看不出降到什么程度)。
    # 分母是期望而不是实际 —— 见上面 _repl 那组函数的注释(实际会被 maxSurge 抬高)。
    # 颜色仍是三色:0=红 / (0,1)=橙 / 1=绿,靠 thresholds 分段;0 和 1 另配文案。
    # min(...,1):扩容中实际就绪短暂超过期望时(缩容窗口内旧副本仍就绪)比值会 >1,
    # 不夹住会掉出 mapping 的 [0,1] 区间 → 既不绿也不橙,染成 thresholds 的兜底色。
    R = repl_ready()
    ratio = 'clamp_max((%s) / clamp_min(%s, 1), 1)' % (R, repl_desired())
    statetimeline("历史服务状态(绿=全就绪 / 橙=部分就绪 / 红=无就绪)", ratio, "{{service}}", w=24, x=0,
                  unit="percentunit",
                  # 颜色用 range/value mapping 显式指定,不靠 thresholds:
                  # 实测 thresholds 缺 "mode" 时染色不符合预期(0.886 被染成红,应为橙),
                  # 与其赌 Grafana 的默认 mode,不如把三档颜色写死在 mapping 里。
                  # mapping 顺序即优先级:先精确 0 / 1,再 (0,1) 区间。
                  mappings=[{"type": "value", "options": {
                                 "0": {"text": "DOWN 无就绪副本", "color": "red", "index": 0},
                                 "1": {"text": "UP 全部就绪", "color": "green", "index": 1}}},
                            {"type": "range", "options": {
                                 "from": 0.000001, "to": 0.999999,
                                 "result": {"color": "orange", "index": 2}}}],
                  thresholds={"mode": "absolute",
                              "steps": [{"color": "red", "value": None},
                                        {"color": "orange", "value": 0.000001},
                                        {"color": "green", "value": 1}]},
                  desc="值 = 就绪副本 / 【期望】副本(百分比),鼠标划过看该 service 该时刻的就绪比例 —— "
                       "100%=全就绪(绿) / 0<x<100%=降级(橙,数字即降级程度) / 0%=无就绪(红)。"
                       "未合并相邻同值,所以 tooltip 时刻≈鼠标位置;精确的 ready/total 个数看下方「历史副本数」"
                       "(已开共享 tooltip,hover 会同步弹出)或最上面那张表。")

def replicas_panel():
    # legend 顺序 = target 顺序,所以【按 service 逐对下发】(total,ready)(total,ready)…,
    # 同一 service 的两条在图例里才挨着。用「一个 total 查询 + 一个 ready 查询」的话
    # 帧顺序是「全部 total 再全部 ready」;Prometheus 的 or 也不排序(左全+右全,实测过)。
    # 末尾一对兜底 target 收 SERVICES 之外的新服务(regex 反向匹配),不至于漏画。
    # live(): 只画【当前仍存在】的 service,已删/改名的历史服务不再进图例(见 live() 注释)
    # 两条线:desired(期望,虚线)/ ready(就绪,实线)。**故意不画 total(EndpointSlice 实际)** ——
    # 滚动更新时 total 会鼓出 maxSurge 那一格,画出来是一堆和健康无关的锯齿,把真正要看的
    # 「ready 有没有掉到 desired 之下」淹掉。实际数在表格里仍有一列,要对 surge 去那儿看。
    # 每个 service 现拼一次 filter 再取两口径。不用「先建带 %s 的模板、后 % 代入」——
    # repl_desired 里有 `or` 回退,模板会含两个 %s,单参数代入直接报错。
    def pair(sel):
        f = 'service=~"$service",service!="unknown",' + sel
        return [(live(repl_desired(f)), '{{service}} desired'),
                (live(repl_ready(f)), '{{service}} ready')]
    tg = []
    for svc in SERVICES:
        tg += pair('service="%s"' % svc)
    tg += pair('service!~"%s"' % '|'.join(SERVICES))

    # desired 虚线 / ready 实线,同 service 同色(色号见 SERVICES/PALETTE)
    ov = [{"matcher": {"id": "byRegexp", "options": ".* desired$"},
           "properties": [{"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}}]}]
    ov += [{"matcher": {"id": "byRegexp", "options": "^%s (desired|ready)$" % svc},
            "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": PALETTE[i % len(PALETTE)]}}]}
           for i, svc in enumerate(SERVICES)]
    # tooltip=multi:只按【横坐标】取值,鼠标在图里任意高度都能同时看到 desired 和 ready
    # —— 正好用来判两条线贴不贴合。
    # 曾经用 single(只显示离光标最近的那条)是因为当时每 service 三条线、两个 service 共 6 条,
    # multi 会糊一大片;去掉 total 后只剩 4 条,single 的代价反而更大:
    # 鼠标落在两条线之间的空白处时"最近的曲线"不存在,tooltip 什么都不弹。
    ts("历史副本数(期望/就绪,随扩缩实时)", tg,
       unit="short", w=24, x=0, minv=0, drawstyle="line", fill=0, overrides=ov, tooltip_mode="multi",
       desc="每 service 后端 pod 数随时间(扩缩容动态);desired=期望副本(虚线,工作负载 spec.replicas),"
            "ready=就绪(实线),同 service 同色且图例里相邻。**两线贴合=健康,ready 掉到 desired 之下=降级**。"
            "不画 EndpointSlice 的实际数:滚动更新的 maxSurge 会让它鼓包,是正常 surge 不是降级,画出来只会干扰"
            "(要看实际数去上面的表格)。tooltip=multi(鼠标在图里任意高度都列出该时刻全部值)。"
            "-leader 已并入。已删/改名服务旧名字随 retention 老化。")

# ═══════════════ 主 dashboard:性能/429/引擎状态/GPU ═══════════════
def build_main():
    reset()
    ROUTEDESC = ("openresty 侧指标,序列本身是【每 route】一条,这里按 route 对应的 service 命名,"
                 "跟其余面板口径统一。当前 route 与 service 是 1:1;若某 service 将来挂多个 route,"
                 "会出现同名多条线(此时可把 legend 改回 {{route}} 区分)。")
    row("限流 / 自适应并发 / EWMA(openresty)")
    # ── 四合一:429 / 自适应并发 / TPS / TTFT 同图(仿 monitor nginx 页) ──────────
    # 原来这四张各占一格,看"连接数顶到 cc 的那一刻有没有开始拒绝、TTFT 有没有同时抬头"
    # 要在四张图之间来回对时间轴。合成一张后,一条竖直的 hover 线就能同时读到四组值。
    # 量纲差三个数量级(429 ~0.x req/s、cc 40~4000、TPS ~300、TTFT 最大几千 ms),
    # 所以【按 unit 分轴】:同一 unit 的 series 共用一根轴,unit 不同的各自成轴。
    #   左轴 short  = 自适应并发四条(cc/上限/下限/连接数,数量级最大,当主轴)
    #   右轴 reqps  = 429 拒绝速率
    #   右轴 ops    = TPS EWMA        (故意不用 short —— 用 short 会被左轴那根吸过去合并)
    #   右轴 ms     = TTFT EWMA
    # ⚠️ 加新 series 时,unit 别跟左轴的 short 撞,否则会被挤到 0~4000 的刻度上压成一条平线。
    REJ = 'rate(openresty_rejected_total{reason!="tps",%s}[$__rate_interval])' % SVC
    # ⚠️ `max by(service)` 把 instance/pod 维度聚合掉,否则 exporter 滚动更新时
    #    新旧两个 pod 的 series 在 staleness 窗口里并存(旧 pod 已删、series 还能查 ~5min),
    #    7 天视图里每条线画成好几根同名重复曲线(实拍 modelforge-01-glm 上限 400/800/2K 三条,
    #    是不同代 exporter 死前抓到的历史值)。用 max 而非 avg:HA 双 openresty 里 standby 报 0/默认值,
    #    avg 会把 active 的真实值拉低一半,max 取回 active 那份。同理 route 改名/蓝绿产生的旧 route series 也一并折叠。
    # 颜色全部钉死,不用调色板:调色板按 series 顺序发色,红色会被随便分给某条线
    # (实拍:TPS 拿到了红),而【红色在这张图里有语义 —— 只属于 429】。
    # series 增删都会让调色板重新洗牌,所以不能靠"看起来没撞"。
    def _c(name):
        return {"id": "color", "value": {"mode": "fixed", "fixedColor": name}}

    ov = [
        # 上限/下限:AIMD 的活动区间,虚线当参考线,不填色。同色系一深一浅,一眼看出是一对。
        {"matcher": {"id": "byRegexp", "options": ".* 上限$"},
         "properties": [{"id": "custom.lineStyle", "value": DASH},
                        {"id": "custom.fillOpacity", "value": 0}, _c("semi-dark-blue")]},
        {"matcher": {"id": "byRegexp", "options": ".* 下限$"},
         "properties": [{"id": "custom.lineStyle", "value": DASH},
                        {"id": "custom.fillOpacity", "value": 0}, _c("light-blue")]},
        # cc/tps/ttft/429:全部对齐 monitor nginx 页 —— 颜色 + 线型都一致,并排看同一指标
        # 一眼认得出。monitor 里这四条都是虚线(cc/tps/ttft=dash 5,4;429=点线 2,3),
        # 实线只留给 total/连接数;这里照抄,只有【当前连接数】保持实线+填色。
        {"matcher": {"id": "byRegexp", "options": ".* cc$"},
         "properties": [_c("#f472b6"),
                        {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [5, 4]}}]},
        # 当前连接数:唯一填色的一条 —— 它顶到 cc 线就是"正在被限流"
        {"matcher": {"id": "byRegexp", "options": ".* 当前连接数$"},
         "properties": [{"id": "custom.fillOpacity", "value": 25}, _c("orange")]},
        # 429:跟并发数【共用左轴】,口径对齐旧 monitor nginx 页 —— monitor 画的是「近 1 分钟拒绝
        # 【条数】」(count/min,整数、几十的量级),不是每秒速率。所以 429 也用【每分钟条数】:查询
        # 里对 rate 结果 ×60(见下 target),数值放大到跟并发同数量级,共左轴才看得清、不被连接数压扁。
        # ⚠️ 共用左轴 = 不设 unit(跟面板默认 short 走);值是"每分钟拒绝数",别当成瞬时计数。
        # 按 reason 拆的分项【不查】—— 这张图已经很挤,分项会多出 service x reason 条
        # 几乎贴地的线;要看是 ttft 还是 concurrency 触发的,去 openresty_rejected_total
        # 直接按 reason 查(Explore 里一条 PromQL 的事),不值得常驻在这张图里。
        {"matcher": {"id": "byRegexp", "options": ".* 429$"},
         "properties": [{"id": "custom.fillOpacity", "value": 0}, _c("#ef4444"),
                        {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [2, 3]}}]},
        {"matcher": {"id": "byRegexp", "options": ".* TPS$"},
         "properties": [{"id": "unit", "value": "ops"},
                        {"id": "custom.axisPlacement", "value": "right"},
                        {"id": "custom.axisLabel", "value": "TPS"},
                        {"id": "custom.fillOpacity", "value": 0}, _c("#38bdf8"),
                        {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [5, 4]}}]},
        {"matcher": {"id": "byRegexp", "options": ".* TTFT$"},
         "properties": [{"id": "unit", "value": "ms"},
                        {"id": "custom.axisPlacement", "value": "right"},
                        {"id": "custom.axisLabel", "value": "TTFT"},
                        {"id": "custom.fillOpacity", "value": 0}, _c("#fbbf24"),
                        {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [5, 4]}}]},
    ]
    ts("限流 / 自适应并发 / TPS / TTFT(openresty · 每 service)",
       # ⚠️ 这个顺序【同时】决定 tooltip 的行序(tooltip sort=none 时按查询顺序列)。
       # 排法是从"此刻在发生什么"到"配置边界":cc 与当前连接数(现状)→ 429(有没有被拒)
       # → TTFT / TPS(后果)→ 上限 / 下限(静态参考,放最后)。改顺序前先想想 tooltip。
       [('max by(service)(openresty_adaptive_cc{%s})' % SVC, "{{service}} cc"),
        ('max by(service)(openresty_adaptive_cc_conc{%s})' % SVC, "{{service}} 当前连接数"),
        ('sum by(service)(%s) * 60' % mrg(REJ), "{{service}} 429"),  # ×60:rate(/s) → 每分钟条数,对齐 monitor
        ('openresty_ttft_ewma_ms{%s}' % SVC, "{{service}} TTFT"),
        ('openresty_tps_ewma{%s}' % SVC, "{{service}} TPS"),
        ('max by(service)(openresty_adaptive_cc_max{%s})' % SVC, "{{service}} 上限"),
        ('max by(service)(openresty_adaptive_cc_min{%s})' % SVC, "{{service}} 下限")],
       unit="short", w=24, x=0, h=14, minv=0, overrides=ov, legend_calcs=LEGEND_CALCS, tooltip_sort="none",
       desc="openresty 限流全景,四组指标同图,按 unit 分轴 —— 左轴(short)自适应并发 + 429(每分钟拒绝条数);"
            "右轴 ops=TPS EWMA;右轴 ms=TTFT EWMA。"
            "【怎么读】上限/下限(虚线)是 AIMD 配置的活动区间;cc 是实时算出的并发配额,在区间内升降;"
            "当前连接数(填色)是真正在途的请求数 —— 它顶到 cc 线的时刻,应当同时看到 429 柱子起来、TTFT 抬头,"
            "这正是把四张图合一要看的因果。cc 长期贴着下限 = 后端持续压力大。"
            "429(红点线)与并发数共用左轴 —— 口径对齐旧 monitor:画的是【每分钟拒绝条数】(rate×60,整数、"
            "几十量级),不是每秒速率,这样才跟并发同数量级、不被连接数峰值压扁。读数是「这一分钟拒了多少条」。"
            "429 是该 service 各 reason 之和,不按 reason 拆 —— 要看是 ttft 还是 concurrency 触发的,"
            "去 Explore 查 openresty_rejected_total 按 reason 分组。已排除 reason=tps(TPS 限流未启用,计数器恒 0)。"
            "图例是表格,列当前值/区间峰值,可点表头排序;series 多时点图例名可单独高亮一条。"
            + ROUTEDESC + RATE_NOTE)
    _y[0] += 14

    row("性能($service)")
    # 顺序:TTFT · 单请求生成速率 · 缓存命中率 / TPM · RPM · 错误率 / RT(整行)
    hgram("TTFT p${quantile:text} / avg (秒,仅流式)", "bodylog_ttft_seconds", "s", 8, 0,
          minus=TTFT_MINUS_NONSTREAM, transformations=STRIP_SVC,
          # 参考线与告警 LLMTTFTHigh 同阈值(warning 30s / critical 55s)
          thresholds=[("green", 0), ("#EAB839", 30), ("red", 55)], thr_style="dashed",
          desc="仅流式请求的首 token 时间。exporter 没能滤掉非流式(它们的 first_chunk_t≈rt,恒>0),"
               "这里用 ttft(全部) - rt(stream=unknown,即非流式) 把它们扣掉 —— 实测 p90 从 31.98s 降到 0.34s。"
               "分位由顶部「分位」下拉切;avg 为常驻参考线。")
    hgram("单请求生成速率 p${quantile:text}保障 / avg (tok/s)", "bodylog_output_tok_per_second", "short", 8, 8,
          invert=True, transformations=STRIP_SVC,
          # 参考线与告警 LLMOutputRateLow 同阈值(critical 10 / warning 20 tok/s)
          thresholds=[("green", 0), ("red", 10), ("#EAB839", 20)], thr_style="dashed",
          desc="单请求解码速率(2026-08-26 起分母已扣除 prefill,只统计流式;此前口径含 prefill,"
               "系统性偏低约 2.4 倍,跨该时点的历史数据不可比)。"
               "⚠️ 该指标**越大越好**,所以本面板取的是 **1-分位** 的低尾:选 p95 画的是 "
               "histogram_quantile(0.05),读作「95% 的请求不低于此值」,与 TTFT 面板的「95% 的请求"
               "不慢于此值」语义对称。直接看高分位没有意义(那是最快的那批)。"
               "另注意单请求速率受批处理并发摊薄——同一后端单请求可达 123 tok/s、14 并发时降到 20~30,"
               "低值未必是故障,先看并发。")
    # 缓存命中率:cache-sim(tools/cache_sim/exporter.py)导出的「实际 vs 理论最大」,两条线共用同一分母。
    # 由线上 UI 改动回流(2026-09-14 比对:线上已是 cachesim 口径 + $calib,脚本仍是 bodylog 单线)。
    # calib 是 cache-sim 的口径版本,变了就是新序列,用 $calib 锁定当前那批。
    CS = 'service=~"$service",service!="unknown",calib="$calib"'
    CS_DEN = 'clamp_min(sum by(service)(rate(cachesim_prompt_tokens_total{%s}[$__rate_interval])),0.001)' % CS
    ts("缓存命中率(cached / prompt tokens)",
       [('sum by(service)(rate(cachesim_theoretical_cached_tokens_total{%s}[$__rate_interval])) / %s' % (CS, CS_DEN),
         "{{service}} 理论最大"),
        ('sum by(service)(rate(cachesim_actual_cached_tokens_total{%s}[$__rate_interval])) / %s' % (CS, CS_DEN),
         "{{service}} 实际")],
       unit="percentunit", w=8, x=16, minv=0, maxv=1, transformations=STRIP_SVC,
       overrides=[{"matcher": {"id": "byRegexp", "options": ".*理论最大"},
                   "properties": [{"id": "custom.lineStyle", "value": {"dash": [10, 10], "fill": "dash"}},
                                  {"id": "custom.fillOpacity", "value": 0}]}],
       desc="两条线,**共用同一个分母**(后端真实 prompt_tokens),所以可以直接比大小:\n"
            "· 实际:cache-sim 记录的后端真实 cached_tokens;\n"
            "· 理论最大:同一批请求在「无多实例打散 / 无驱逐」的理想前缀缓存里重放算出的上界。\n"
            "两者的差 = 路由打散 + 驱逐吃掉的部分;理论低于实际说明口径或渲染有问题,不是好事。\n\n"
            "只统计 200 + 有 usage + 未截断 + cache-sim 认识的模型,覆盖率见 cachesim_skipped_total"
            "(实测与 bodylog 全量口径差 0.2–0.4pp)。calib 是口径版本,变了就是新序列,故用 $calib 锁定当前那批。")
    _y[0] += 8
    # TPM / RPM:速率 × 60 换算成「每分钟」。× 60 与窗口大小无关 —— rate() 返回的就是每秒值,
    # 乘 60 即每分钟;窗口只决定平滑程度。(曾经写死 [1m] 并把理由记成「换算成每分钟」,是误解。)
    # TPM 四条:total(=input+output) / input(prompt) / output(completion) / cached(命中缓存的 input)
    # cached 是 input 的子集,cached/input 就是上面那个缓存命中率
    ts("TPM(tokens/min)",
       [('60 * sum by(service)(%s)' % mrg('rate(bodylog_%s_total{%s}[$__rate_interval])' % (m, SVC)), '{{service}} ' + lbl)
        for m, lbl in [("total_tokens", "total"), ("prompt_tokens", "input"),
                       ("completion_tokens", "output"), ("cached_tokens", "cached")]],
       unit="short", w=8, x=0, minv=0, transformations=STRIP_SVC,
       desc="每分钟 token 量(= 速率 x 60)。total=input+output;input=prompt;output=生成;"
            "cached=命中前缀缓存的 input(是 input 的子集,cached/input 即缓存命中率)。" + RATE_NOTE)
    ts("RPM 请求量(requests/min)",
       [('60 * sum by(service)(%s)' % mrg('rate(bodylog_requests_total{backend!="(none)",%s}[$__rate_interval])' % SVC), "{{service}}")],
       unit="reqpm", w=8, x=8, minv=0, transformations=STRIP_SVC, desc="每分钟请求数(= 速率 x 60);排除 4xx 无后端噪声" + RATE_NOTE)
    ts("错误率 (5xx 占比)",
       [('sum by(service)(%s) / clamp_min(sum by(service)(%s),0.001)'
         % (mrg('rate(bodylog_requests_total{status_class="5xx",backend!="(none)",%s}[$__rate_interval])' % SVC),
            mrg('rate(bodylog_requests_total{backend!="(none)",%s}[$__rate_interval])' % SVC)), "{{service}}")],
       unit="percentunit", w=8, x=16, minv=0, transformations=STRIP_SVC,
       desc="只算 5xx(服务侧错误);4xx 不计 —— 含 400 客户端坏请求 / 499 客户端断连 / 429 限流,不反映服务健康。" + RATE_NOTE)
    _y[0] += 8
    hgram("RT p${quantile:text} / avg (秒,端到端)", "bodylog_rt_seconds", "s", 16, 0,
          desc="端到端响应时间;顶部「分位」下拉可切,avg 常驻", transformations=STRIP_SVC)
    # finish_reason 分布:length 抬头 = 大量请求被 max_tokens 截断(答案被切,用户侧表现为答到一半没了)
    ts("结束原因分布(requests/min)",
       [('60 * sum by(finish_reason)(%s)' % mrg('rate(bodylog_finish_reason_total{%s}[$__rate_interval])' % SVC), "{{finish_reason}}")],
       unit="reqpm", w=8, x=16, minv=0, stacking=True, drawstyle="line",
       desc="按 finish_reason 拆的请求速率(堆叠)。stop=正常结束;length=撞到 max_tokens 被截断"
            "(占比高说明输出上限设小了或提示词让模型停不下来);tool_calls=触发工具调用。" + RATE_NOTE)
    _y[0] += 8


    row("引擎状态(sglang/vllm · 按 service)")
    ENGDESC = ("引擎指标的 service 是 k8s Service 名,已归一到 bodylog 的 <ns>/<name> 口径(剥 -leader)并受顶部「service」下拉过滤;"
               "归一后对不上活服务的历史名(如 kimi-sglang-sglang-svc)自动消失。"
               "默认只画该 service 的汇总(粗实线);顶部「实例明细」切到【显示】后,每个后端 pod 再各画一条细虚线,用来看实例间倾斜/掉队。"
               "图例是表格,列当前值/峰值,可点表头排序。")
    ts("KV / token_usage 占用",
       eng_panel("avg", ["sglang:token_usage", "vllm:gpu_cache_usage_perc"]),
       unit="percentunit", w=8, x=0, minv=0, maxv=1, overrides=TOTAL_OV, legend_calcs=LEGEND_CALCS, linestyle=DASH,
       desc="sglang token_usage / vllm gpu_cache_usage_perc(0-1)。汇总线 = 该 service 所有实例均值。" + ENGDESC)
    # 运行中 / 等待中 合成一张:两者是同一队列的两端(在跑 vs 排队),分开看要来回扫视,
    # 而且 num_queue 平时恒 0、单独占一格浪费。合并后「等待中抬头而运行中压顶」= 后端打满。
    _run = ["sglang:num_running_reqs", "vllm:num_requests_running"]
    _que = ["sglang:num_queue_reqs", "vllm:num_requests_waiting"]
    _tg = []
    for _ms, _lb in [(_run, "运行中"), (_que, "等待中")]:
        for _m in _ms:
            _tg.append((flt('sum by(service)(%s)' % eng(_m)), "{{service}} %s 汇总" % _lb))
            _tg.append(('%s\n  and on() (vector($eng_pods) == 1)' % flt('max by(service,pod)(%s)' % eng(_m)),
                        "{{pod}} %s" % _lb))
    ts("运行中 / 等待中(num_running / num_queue)", _tg,
       unit="short", w=8, x=8, minv=0, overrides=TOTAL_OV, legend_calcs=LEGEND_CALCS, linestyle=DASH,
       desc="运行中=引擎正在处理的请求数;等待中=在引擎队列里排队的请求数。"
            "等待中长期大于 0 = 后端已打满、请求在排队(该扩容或降并发上限)。" + ENGDESC)
    # ⚠️ 不能用 avg(sglang:cache_hit_rate):那是【瞬时比率】,空闲 pod 报 0,
    #    实测 modelforge 40 个 pod 里 37 个是 0,一平均把 59% 稀释成 5.96%(差 10 倍)。
    #    正确口径是 token 加权:sum(cached_tokens)/sum(prompt_tokens),分子分母各自先求和再相除。
    _cn = eng('rate(sglang:cached_tokens_total[$__rate_interval])')
    _cd = eng('rate(sglang:prompt_tokens_total[$__rate_interval])')
    ts("引擎 cache 命中率(token 加权)",
       [(flt('sum by(service)(%s) / clamp_min(sum by(service)(%s), 0.001)' % (_cn, _cd)), "{{service}} 汇总"),
        ('%s\n  and on() (vector($eng_pods) == 1)'
         % flt('sum by(service,pod)(%s) / clamp_min(sum by(service,pod)(%s), 0.001)' % (_cn, _cd)), "{{pod}}")],
       unit="percentunit", w=8, x=16, minv=0, maxv=1, overrides=TOTAL_OV, legend_calcs=LEGEND_CALCS, linestyle=DASH,
       desc="命中前缀缓存的 prompt token 占比(sum(cached)/sum(prompt),按 token 量加权)。"
            "不是各 pod 命中率的平均 —— 空闲 pod 的瞬时命中率是 0,直接平均会把结果稀释十倍。"
            "与「性能」区那个 bodylog 口径的缓存命中率可互相印证(一个是引擎自报,一个是网关记账)。" + ENGDESC + RATE_NOTE)
    _y[0] += 8
    _y[0] += 8

    return {"uid": "llm-obs-bodylog", "title": "LLM推理性能指标", "tags": ["llm", "inference"],
            "timezone": "browser", "schemaVersion": 42, "refresh": "30s", "time": {"from": "now-3h", "to": "now"},
            "templating": {"list": [
                VAR_SERVICE_TOP,
                # allowCustomValue:除了下面几个预设,还能在框里直接敲任意分位。
                # ⚠️ 自由输入要填【小数】(0.995 / 0.999),不能填 "p99.5" —— 输入内容会原样代进
                # histogram_quantile($quantile, ...),写成 pXX 会让查询报错(报错比静默算错好,
                # 所以没做成百分数口径:那样误填 0.99 会被当成 0.99% 分位,悄悄给出错误结果)。
                {"name": "eng_pods", "type": "custom", "label": "实例明细",
                 "description": "引擎状态面板是否画出每个 pod 的明细线(默认只画 service 汇总;副本多时明细会淹没汇总)",
                 "query": "隐藏 : 0, 显示 : 1",
                 "options": [{"text": "隐藏", "value": "0", "selected": True},
                             {"text": "显示", "value": "1", "selected": False}],
                 "current": {"text": "隐藏", "value": "0"}, "includeAll": False, "multi": False},
                # 这个下拉被两类**方向相反**的面板共用,统一按「覆盖率」理解,不要理解成"取第几百分位":
                #   选 pN 一律读作「N% 的请求」——
                #   · TTFT / RT(越大越坏)→ 直接用 q=N%,读作「N% 的请求不慢于 X 秒」
                #   · 单请求生成速率(越大越好)→ 面板内部自动换成 **1-q**(见 hgram 的 invert),
                #     读作「N% 的请求不低于 Y tok/s」
                #   所以这里**只列高分位**:低尾由 invert 面板自己翻,不需要用户手选 p5/p10,
                #   否则同一个 pN 在两类面板上含义会打架。
                {"name": "quantile", "type": "custom", "label": "分位",
                 # ⚠️ 值是【百分数】不是小数:自定义请输 72 / 99.9,【不要输 0.72】。
                 #    输小数会得到 histogram_quantile(0.0072) —— 一个极小的分位,不报错、静默算错。
                 #    (反过来,旧版是小数制,那时输 72 会得到 +Inf,同样静默。两种写法都无法在
                 #     Grafana 变量层做校验,只能靠这段描述;选百分数是因为它匹配用户的自然输入。)
                 #    text 不带 p 前缀 —— p 由面板标题/图例统一加,否则会显示成 "pp90"。
                 "description": "统一读作「N% 的请求」:TTFT/RT 看不慢于多少秒,生成速率看不低于多少 tok/s(该面板内部自动取 100-N 的低尾)。自定义请输【百分数】,如 72、99.9 —— 不要输 0.72",
                 "query": "50 : 50, 75 : 75, 80 : 80, 90 : 90, 95 : 95, 99 : 99, 99.9 : 99.9",
                 "allowCustomValue": True,
                 "options": [{"text": "50", "value": "50", "selected": False},
                             {"text": "75", "value": "75", "selected": False},
                             {"text": "80", "value": "80", "selected": False},
                             {"text": "90", "value": "90", "selected": True},
                             {"text": "95", "value": "95", "selected": False},
                             {"text": "99", "value": "99", "selected": False},
                             {"text": "99.9", "value": "99.9", "selected": False}],
                 "current": {"text": "90", "value": "90"}, "includeAll": False, "multi": False},
                # cache-sim 口径版本(缓存命中率面板用):calib 变了就是新序列,新旧口径的数不可比。
                # sort=4 = 数值降序,默认选中最新口径。
                {"name": "calib", "type": "query", "datasource": DS, "label": "cache-sim 口径",
                 "definition": "label_values(cachesim_prompt_tokens_total, calib)",
                 "query": {"query": "label_values(cachesim_prompt_tokens_total, calib)", "refId": "calib"},
                 "refresh": 2, "sort": 4, "includeAll": False, "multi": False},
                ]},
            "panels": panels}

# ═══════════════ GPU dashboard:DCGM 硬件指标 ═══════════════
def gpu_util_panel():
    """集群 GPU 利用率历史曲线:已用卡 / 总卡数。

    「已用」判据与下方表格的「已用卡」列一致 —— exported_pod!="",即【被 k8s pod 分配走】。
    ⚠️ 因此它衡量的是【k8s 侧的分配率】,不是算力/显存的实际占用率。两者会背离:
       部分节点上跑着裸机 docker 的服务,
       显存实打实被占,但 kubelet 不知情 → 这里算作「空闲」,整体利用率被低估。
       那两台在 k8s 里是 cordon 状态,本就不参与调度,所以这个口径对「还能调度多少」
       是准的,对「机器闲不闲」不准。要看后者去下方表格的「最大显存占用」列。

    受 $host / $gpu_model 筛选(所以想看单一型号的利用率,切「GPU 类型」下拉即可,
    不必把曲线拆成多条)。

    `or vector(0)`:某档筛选下一张卡都没被占用时(如当前的 H800),count 返回空 vector,
    不兜底整条曲线会消失、看起来像「没数据」,而不是「利用率 0」。
    """
    H = '{Hostname=~"$host",modelName=~".*$gpu_model.*"}'
    used = 'count(DCGM_FI_DEV_GPU_TEMP{Hostname=~"$host",modelName=~".*$gpu_model.*",exported_pod!=""})'
    tot = 'count(DCGM_FI_DEV_GPU_TEMP%s)' % H
    ts("集群 GPU 利用率(已用卡 / 总卡数)",
       [('(%s or vector(0))\n  / %s' % (used, tot), "已分配占比"),
        (used, "已用卡数"),
        (tot, "总卡数")],
       # h=9 而非默认 8:表格式图例本身占掉一行,8 高会把曲线区挤得很扁。
       # (线上手工调过一次,这里同步回来 —— 面板布局的权威来源是本文件,
       #  下次 POST 会整体覆盖,在 UI 上拖的改动不回流就会丢。)
       unit="percentunit", w=24, x=0, minv=0, maxv=1, fill=10, h=9,
       # 表格式图例:三条线垂直排一列。用 list 模式时 Grafana 会把图例项按各自所属的 Y 轴
       # 左右对齐(占比在左轴、卡数在右轴),看起来像被拆成了两组;表格模式天然连在一起,
       # 顺带还能显示当前值/峰值。
       legend_calcs=LEGEND_CALCS,
       overrides=[{"matcher": {"id": "byRegexp", "options": "^(已用卡数|总卡数)$"},
                   "properties": [{"id": "unit", "value": "short"},
                                  {"id": "custom.axisPlacement", "value": "right"},
                                  {"id": "custom.fillOpacity", "value": 0},
                                  {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [8, 8]}},
                                  {"id": "max", "value": None}]}],
       desc="已用卡 / 总卡数。**已用 = 被 k8s pod 分配走的卡**(DCGM 的 exported_pod 非空),"
            "衡量的是【k8s 侧分配率】而非实际算力占用 —— 裸机 docker 跑的服务(a100-5 / a100-24)"
            "显存实打实被占但 kubelet 不知情,在这里算作空闲,会低估整体利用率;"
            "那两台在 k8s 里是 cordon 状态、本就不参与调度,所以这个口径对「还能调度多少」是准的。"
            "受顶部「GPU 主机」「GPU 类型」筛选 —— 想看单一型号切「GPU 类型」下拉即可。"
            "右轴虚线是已用/总卡的绝对值,便于看清是分子变了还是分母变了。")
    _y[0] += 9


def gpu_table():
    """GPU 机器一览:一行一台。service=All → 显示全部主机(含空闲);选具体 service → 只列跑该 service 的机器
    (空闲机/跑别的 service 的机器都隐掉)。$host / $gpu_model 仍生效,用于收窄。

    「已用卡」判据是 exported_pod!="" —— DCGM exporter 通过 kubelet 的 pod-resources API
    知道每张卡被哪个 pod 分配走,并打进 exported_pod/exported_namespace。
    ⚠️ 它反映的是【k8s 侧的分配】,不是实际算力占用:裸机 docker 跑的服务(a100-* 那几台
    modelforge)显存明明被占,已用卡仍是 0 —— 那些机器在 k8s 里是 cordon 状态。

    三个筛选($host / $gpu_model / $service)都生效:
      - $host / $gpu_model 是普通 label,直接写进选择器;
      - $service 麻烦在【空闲机没有 service 标签】,普通 service=~ 匹配不到它们。
        故先算一个「允许的主机集合」HOSTSEL = 跑着选中 service 的机器(经 exported_pod → POD2SVC 桥拿 service);
        **仅当选中 All(选中 service 数==全部 service 数)时**再并入纯空闲机。再让每条指标 `and on(Hostname) HOSTSEL`。
    """
    H = '{Hostname=~"$host",modelName=~".*$gpu_model.*"}'
    TEMP = 'DCGM_FI_DEV_GPU_TEMP%s' % H
    # service → 主机 的桥。用 POD2SVC 拿【真正的 service】(与服务健康表/性能页口径一致),
    # 且必须带 WORKER2SVC 那一支:LWS 的 worker pod 不暴露引擎指标,只 join leader 会漏掉
    # worker 占的卡(实测 8 台会只剩 6 台)。
    JOIN = ('group by(Hostname, service)(\n'
            '  label_replace(label_replace(DCGM_FI_DEV_GPU_TEMP{Hostname=~"$host",'
            'modelName=~".*$gpu_model.*",exported_pod!=""},'
            ' "pod", "$1", "exported_pod", "(.+)"), "namespace", "$1", "exported_namespace", "(.+)")\n'
            '  * on(namespace,pod) group_left(service) %s)') % POD2SVC
    # $service 的白名单向量(-leader 已剥,与 VAR_SERVICE_ALL 的取值一致)
    SVC_ALLOW = ('count by(service)(label_replace(bodylog_service_replicas{service=~"$service",'
                 'service!="unknown"}, "service", "$1", "service", "(.*)-leader$"))')
    # 全部 service 数(不受 $service 过滤),用于判断是否选了 All。
    ALL_SVC = ('count(count by(service)(label_replace(bodylog_service_replicas{service!="unknown"},'
               ' "service", "$1", "service", "(.*)-leader$")))')
    # 主机集合 = 跑着选中 service 的机器;**仅当选中 All 时**再并入纯空闲机(一张卡都没被 pod 占的机器)。
    #   判据「选了 All」= 选中 service 数 == 全部 service 数(count(SVC_ALLOW) == ALL_SVC);
    #   不等(选了具体 service / 子集)则右侧空 vector,空闲机分支整支被 and 掉 → 只留在用机器。
    IDLE_IF_ALL = ('(group by(Hostname)(%s)\n      unless on(Hostname) group by(Hostname)(%s))'
                   '\n   and on() (count(%s) == %s)') % (TEMP, JOIN, SVC_ALLOW, ALL_SVC)
    HOSTSEL = '(group by(Hostname)(%s\n   and on(service) %s)\n or %s)' % (JOIN, SVC_ALLOW, IDLE_IF_ALL)
    sel = lambda e: '%s\n  and on(Hostname) %s' % (e, HOSTSEL)
    # 空 vector 兜底:某台一张卡都没被占用时 count 返回空 → 表格该格是空白而不是 0。
    used = ('(count by(Hostname)(DCGM_FI_DEV_GPU_TEMP{Hostname=~"$host",modelName=~".*$gpu_model.*",exported_pod!=""})'
            '\n   or (0 * count by(Hostname)(%s)))' % TEMP)
    qs = [
        (sel('count by(Hostname)(%s)' % TEMP), "卡数"),
        (sel(used), "已用卡"),
        (sel('max by(Hostname)(%s)' % TEMP), "最高温度"),
        (sel('max by(Hostname)(DCGM_FI_DEV_MEMORY_TEMP%s)' % H), "显存温度"),
        (sel('max by(Hostname)(DCGM_FI_DEV_FB_USED%s)' % H), "最大显存占用"),
        (sel('avg by(Hostname)(DCGM_FI_DEV_GPU_UTIL%s)' % H), "平均利用率"),
        (sel('sum by(Hostname)(DCGM_FI_DEV_POWER_USAGE%s)' % H), "整机功耗"),
        # 热降频:取增速而非累计值(累计值只会单调上涨,看不出「此刻是否正在降频」),
        # 再换算成【降频时间占比】—— 原始值是一串纳秒数,没人能直接判断严重程度。
        #
        # DCGM_FI_DEV_THERMAL_VIOLATION 是只增计数器,累计该卡因过热被限频的时长,
        # ⚠️ 单位是【纳秒】不是微秒:实测 h100-46 gpu1 在 2.1 小时内增长 51,488,379,168,
        #    按微秒解释 = 降频了 686% 的时间(物理上不可能);按纳秒 = 51.5s/7500s = 0.69%,合理。
        # 除以 1e9 得秒,再除以卡数 → 全机平均「有百分之多少的时间在热降频」。
        # 分母跟着同一套 $host/$gpu_model 过滤,否则筛选后分子分母不同源。
        (sel('sum by(Hostname)(rate(DCGM_FI_DEV_THERMAL_VIOLATION{Hostname=~"$host",'
             'modelName=~".*$gpu_model.*"}[$__rate_interval]))\n  / (1e9 * count by(Hostname)(%s))' % TEMP),
         "热降频"),
        (sel('max by(Hostname)(DCGM_FI_DEV_CLOCK_THROTTLE_REASONS%s)' % H), "降频原因"),
    ]
    tg = [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "datasource": DS, "format": "table", "instant": True}
          for i, (e, l) in enumerate(qs)]
    # 服务名单独一支(带额外 label,不能和上面按 Hostname 聚合的混在一个 refId 里)。
    # 用 POD2SVC 桥拿【真正的 service】而不是 exported_namespace —— 与服务健康表/性能页的
    # service 口径完全一致(kimi/kimi-k25、modelforge/fallback-modelforge-01),跨页能对上。
    # ⚠️ POD2SVC 必须带 WORKER2SVC 那一支:LWS 的 worker pod 不暴露引擎指标,只 join
    #    LEADER2SVC 会漏掉 worker 占的卡(实测 8 台会只剩 6 台)。
    # ⚠️ 这一支只是【把 service 这个 label 带进表格】,它的 value 恒为 1、没有意义,
    #    必须在 organize 里 exclude 掉,否则 Grafana 会原样显示成一列 "Value #J"(踩过)。
    # 型号列:modelName 是 DCGM 原生 label(实测每台机器只有一种型号,不会因此裂行)
    model_ref = "Value #" + chr(65 + len(qs) + 1)
    # 型号显示简称(A100 / H100 / H800),不显示 "NVIDIA H100 80GB HBM3" 这种长串 ——
    # 一列挤不下会折行,而后缀(SXM4-80GB / HBM3)对看机器状态没有信息量。
    # label_replace 要求正则【整体匹配】,三种型号("NVIDIA A100-SXM4-80GB" / "NVIDIA H100 80GB HBM3"
    # / "NVIDIA H800")都能被 "NVIDIA ([A-Z]+[0-9]+).*" 整体匹配并截出首段;匹配不上则原样保留。
    tg.append({"refId": chr(65 + len(qs) + 1),
               "expr": sel('group by(Hostname, modelName)(label_replace(%s,'
                           ' "modelName", "$1", "modelName", "NVIDIA ([A-Z]+[0-9]+).*"))' % TEMP),
               "legendFormat": "型号", "datasource": DS, "format": "table", "instant": True})
    svc_ref = "Value #" + chr(65 + len(qs))
    tg.append({"refId": chr(65 + len(qs)), "expr": sel(JOIN),
               "legendFormat": "服务", "datasource": DS, "format": "table", "instant": True})

    ref = {lbl: "Value #" + chr(65 + i) for i, (_, lbl) in enumerate(qs)}
    rename = dict({v: k for k, v in ref.items()}, Hostname="主机", service="服务", modelName="型号")
    cols = ["卡数", "已用卡", "最高温度", "显存温度", "最大显存占用", "平均利用率", "整机功耗", "热降频", "降频原因"]
    order = dict({"Hostname": 0, "modelName": 1, "service": 2},
                 **{ref[c]: i + 3 for i, c in enumerate(cols)})

    ov = [{"matcher": {"id": "byName", "options": n}, "properties": [{"id": "custom.width", "value": w}]}
          # 型号已截成简称(A100/H100/H800),不再需要容纳 "NVIDIA H100 80GB HBM3";
          # 服务是全限定名(modelforge/fallback-modelforge-01,33 字符),要给够否则截断。
          for n, w in [("主机", 110), ("型号", 80), ("服务", 280), ("卡数", 60), ("已用卡", 72), ("最高温度", 88),
                       ("显存温度", 88), ("最大显存占用", 112), ("平均利用率", 96), ("整机功耗", 96),
                       ("热降频", 96), ("降频原因", 130)]]
    ov += [
        # 温度阈值与 monitor.conf 的 gpu_temp_warn/alert 对齐(75 / 83),两处别各写一套。
        {"matcher": {"id": "byName", "options": "最高温度"}, "properties": [
            {"id": "unit", "value": "celsius"},
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "green", "value": None}, {"color": "orange", "value": 75}, {"color": "red", "value": 83}]}}]},
        {"matcher": {"id": "byName", "options": "显存温度"}, "properties": [{"id": "unit", "value": "celsius"}]},
        {"matcher": {"id": "byName", "options": "最大显存占用"}, "properties": [{"id": "unit", "value": "decmbytes"}]},
        {"matcher": {"id": "byName", "options": "平均利用率"}, "properties": [
            {"id": "unit", "value": "percent"}, {"id": "max", "value": 100}, {"id": "min", "value": 0},
            {"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "gradient"}}]},
        {"matcher": {"id": "byName", "options": "整机功耗"}, "properties": [{"id": "unit", "value": "watt"}]},
        # 值域 0~1(percentunit 渲染成 0%~100%)。0 = 此刻无任何卡因过热降频。
        # >1% 橙:偶发热降频,值得看一眼;>10% 红:相当一部分时间在降频,算力已被明显吃掉。
        {"matcher": {"id": "byName", "options": "热降频"}, "properties": [
            {"id": "unit", "value": "percentunit"},
            {"id": "decimals", "value": 2},
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "green", "value": None}, {"color": "orange", "value": 0.01},
                {"color": "red", "value": 0.10}]}}]},
        # ⚠️ 位图的低两位是【良性】的,不能按「非 0 就报警」染色:
        #   0x01 GPU Idle(空闲,实测 20 台里 16 台是这个值)、0x02 Applications clocks setting(管理员设定时钟)
        #   0x04 SW Power Cap / 0x08 HW Slowdown / 0x10 Sync Boost / 0x20 SW Thermal /
        #   0x40 HW Thermal / 0x80 HW Power Brake  ← 这些才是真降频
        # 任一有害位置位 ⇒ 数值 >= 4;而良性组合最大是 1+2=3。故用 >=4 做判据。
        # (Prometheus 没有按位与,只能靠这个数值边界;所幸边界是严格成立的。)
        # 直接显示【原因文字】而不是原始位掩码 —— 掩码要人肉换算,一列 "1" 谁也看不出是「空闲」。
        # 用【区间】映射而非逐值映射,因为位可以组合(如 36 = 0x20 SW热降频 + 0x04 SW功耗墙)。
        # 区间按 2 的幂切,落在哪一段 = 【最高置位】在哪一位 = 最严重的那个原因 —— 正好是想看的。
        # (上游是 max by(Hostname),取该机数值最大的卡;位越高越严重,故 max 天然凸显最严重原因。)
        {"matcher": {"id": "byName", "options": "降频原因"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "mappings", "value": [{"type": "range", "options": {
                 "from": f, "to": t, "result": {"text": txt, "color": c, "index": i}}}
                for i, (f, t, txt, c) in enumerate([
                    (0, 0, "正常", "green"),
                    (1, 3, "空闲", "green"),                 # 0x01 GPU 空闲 / 0x02 管理员设定时钟
                    (4, 7, "SW 功耗墙", "orange"),           # 0x04
                    (8, 15, "HW 降速", "orange"),            # 0x08
                    (16, 31, "Sync Boost", "orange"),        # 0x10
                    (32, 63, "SW 热降频", "red"),            # 0x20
                    (64, 127, "HW 热降频", "red"),           # 0x40
                    (128, 100000, "HW 功耗刹车", "red"),     # 0x80
                ])]},
            # mapping 自带颜色;thresholds 仅作 mapping 未覆盖时的兜底
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "green", "value": None}, {"color": "orange", "value": 4}, {"color": "red", "value": 32}]}}]},
        {"matcher": {"id": "byName", "options": "已用卡"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "text", "value": None}, {"color": "blue", "value": 1}]}}]},
        # 服务列单元格自动换行:一机多服务(binpack 共卡)时 uniqueValues 并成
        # "svcA, svcB" 会超宽被截断,wrapText 让它折行显示全(Grafana 11+ 的 table cellOptions)。
        {"matcher": {"id": "byName", "options": "服务"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "auto", "wrapText": True}}]},
    ]
    panels.append({"type": "table", "id": nid(), "title": "GPU 机器一览", "datasource": DS,
                   "description": "一行一台 GPU 服务器。**service=All → 全部主机(含空闲);选具体 service → 只列跑该 service 的机器**(空闲机/别的 service 的机器隐掉)。"
                                  "(下面的曲线面板在「按 service」档会把空闲机整台滤掉 —— 那对趋势图是对的,"
                                  "但清单漏机器就没意义了);「GPU 主机」下拉仍然生效,用于收窄。"
                                  "已用卡 = DCGM 报告了 exported_pod 的卡数 —— 即【被 k8s pod 分配走】的卡。注意它反映的是 k8s 侧的分配,不是实际算力占用:裸机 docker 跑的服务(如 a100-* 那几台 modelforge)显存明明被占,已用卡仍是 0。服务 = 经 POD2SVC 桥拿到的 service 名,与服务健康表/性能页口径一致;空白 = 无 k8s pod 占卡。温度阈值 75 橙 / 83 红,与 monitor.conf 的 gpu_temp_warn/alert 一致。"
                                  "热降频 = 该机【有百分之多少的时间在因过热降频】(THERMAL_VIOLATION 计数器的增速 / 1e9 / 卡数)。⚠️ 该计数器单位是【纳秒】不是微秒 —— 实测 h100-46 gpu1 在 2.1 小时内增长 5.1e10,按微秒解释等于降频了 686% 的时间(不可能),按纳秒 = 0.69%,合理。0% = 此刻没有任何卡在热降频;>1% 橙 / >10% 红。注意它与「降频原因」列的分工:本列只管【热】且表达【持续时长】,「降频原因」管【任意原因】且表达【此刻状态】—— 所以出现「降频原因=SW 功耗墙 但热降频=0%」是自洽的,不是矛盾。降频原因由 DCGM 的按位掩码翻译成文字(不再让人肉换算 0x 值):正常 / 空闲(0x01 GPU 空闲、0x02 管理员设定时钟 —— 这两位良性,实测 20 台里 15 台常驻「空闲」)/ SW 功耗墙(0x04,满载撞功耗上限,正常,但说明吞吐已被功耗限制)/ HW 降速(0x08)/ Sync Boost(0x10)/ SW 热降频(0x20)/ HW 热降频(0x40)/ HW 功耗刹车(0x80)。位可组合,故按 2 的幂分区间映射,落在哪段=最高置位在哪位=最严重的原因;上游取 max by(Hostname),位越高越严重,天然凸显最严重的那张卡。要定位到具体是哪张卡,看下方曲线面板。"
                                  "某台若同时跑两个 namespace 会出现两行 —— 那是事实不是 bug。",
                   "gridPos": {"h": 13, "w": 24, "x": 0, "y": _y[0]}, "targets": tg,
                   "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": ov},
                   # merge → organize(改中文名) → groupBy(按主机收成一行) → organize(去掉聚合后缀).
                   # ⚠️ 为什么要 groupBy:binpack 把两个 GPU 服务装到同一台机(如 h100-56 = fallback-modelforge-01
                   #    + modelforge-02-kimi)后,「服务」列带 service 维度 → 按 Hostname 合并时裂成两行,per-host
                   #    的 GPU 列(卡数/温度/功耗…只带 Hostname)只贴得上一行,另一行 GPU 全空。groupBy 按主机收成
                   #    一行,服务列用 uniqueValues 把该机所有服务并成一格("svcA, svcB"),GPU 列取 lastNotNull
                   #    (per-host 唯一值,非空那份)。聚合后 Grafana 会把列名加后缀"(reducer)",末尾 organize 再改回中文名,
                   #    使 overrides(按中文名匹配的单位/阈值/染色)照常生效。
                   "transformations": [{"id": "merge", "options": {}},
                       {"id": "organize", "options": {"excludeByName": {"Time": True, svc_ref: True, model_ref: True},
                                                      "renameByName": rename, "indexByName": order}},
                       {"id": "groupBy", "options": {"fields": dict(
                           {"主机": {"operation": "groupby", "aggregations": []},
                            "服务": {"operation": "aggregate", "aggregations": ["uniqueValues"]},
                            "型号": {"operation": "aggregate", "aggregations": ["lastNotNull"]}},
                           **{c: {"operation": "aggregate", "aggregations": ["lastNotNull"]} for c in cols})}},
                       {"id": "organize", "options": {
                           "renameByName": dict({"服务 (uniqueValues)": "服务", "型号 (lastNotNull)": "型号"},
                                                **{"%s (lastNotNull)" % c: c for c in cols}),
                           "indexByName": dict({"主机": 0, "型号": 1, "服务": 2},
                                               **{c: i + 3 for i, c in enumerate(cols)})}}],
                   "options": {"showHeader": True, "sortBy": [{"displayName": "主机"}]}})
    _y[0] += 13


def build_gpu():
    # 整个 dashboard 就是 GPU,不再套一层 row
    reset()
    gpu_util_panel()  # 先放利用率曲线:进页面第一眼是「集群整体用了多少」
    gpu_table()   # 再放清单表:进页面第一眼是「有哪些机器、谁在用、有没有过热」,再往下看趋势
    GPUDESC = ("DCGM 硬件指标,只受「GPU 主机」「GPU 类型」过滤,**不受「service」下拉影响** —— 温度/显存/利用率/降频属于机器而不属于某个服务,空闲机器(刚重装、待分配、怀疑硬件问题)也画得出来。要按服务看哪些卡被谁占用,见上方一览表。")
    ts("GPU 温度 °C(每 host 最高)",
       gpu("max", "DCGM_FI_DEV_GPU_TEMP") + [gpu_percard("DCGM_FI_DEV_GPU_TEMP")],
       unit="celsius", w=8, x=0, overrides=PERCARD_HIDE,
       desc="曲线是每主机最热的那张卡。**把顶部「GPU 主机」筛到一台时,鼠标悬停会额外列出该机每张卡的温度**"
            "(逐卡数据只进 tooltip,不画线也不进图例;多机时自动不出 —— 8 卡 x N 机会让 tooltip 有几十行没法读)。" + GPUDESC)
    ts("显存占用 MiB(每 host 最高)", gpu("max", "DCGM_FI_DEV_FB_USED"),
       unit="decmbytes", w=8, x=8, minv=0, desc=GPUDESC)
    ts("GPU 利用率 %(每 host 均值)", gpu("avg", "DCGM_FI_DEV_GPU_UTIL"),
       unit="percent", w=8, x=16, minv=0, maxv=100, desc=GPUDESC)
    _y[0] += 8
    ts("热降频(THERMAL_VIOLATION 增速)",
       gpu("sum", "DCGM_FI_DEV_THERMAL_VIOLATION", rng="$__rate_interval")
       + [gpu_percard("DCGM_FI_DEV_THERMAL_VIOLATION", rng="$__rate_interval")],
       overrides=PERCARD_HIDE,
       unit="short", w=12, x=0, desc="THERMAL_VIOLATION 计数器的增速(全机各卡之和)。该计数器累计因过热被限频的时长,单位【纳秒】(不是微秒,实测验证过);故数值 / (1e9 x 卡数) = 降频时间占比,上面的一览表直接给的就是这个百分比。数值大于 0 = 正在因过热降频。" + GPUDESC + RATE_NOTE, drawstyle="bars")
    # 降频原因:把 CLOCK_THROTTLE_REASONS 位掩码【直接翻译成原因文字】(功耗墙/热降频…),
    # 用 state-timeline 显示色块 + 文字,比原来看裸数字(4/32/…)直观。按 2 的幂分区间 = 最高置位=最严重原因。
    #
    # 0~3 合并成一个「正常」状态,不再把"空闲"单列 —— 空闲(bit0)只是没活干、时钟自动降下来,
    # 和满速(0)一样良性。分成两个状态的后果是:卡每次忙闲切换都断一次色块、印一次文字,
    # 而生产上这个翻转极其频繁(实拍 160 张卡里 71 张=0、83 张=1,同一张卡随负载来回跳),
    # 于是整个面板被"正常 空闲 正常 空闲"糊满 —— 而看这个面板的目的恰恰是找异常。
    # 合并后长时间是一整条绿,只有真出现功耗墙(橙)/热降频(红)才断开,一眼能看出哪台有问题。
    _reason_maps = [{"type": "range", "options": {"from": f, "to": t,
                     "result": {"text": txt, "color": c, "index": i}}}
                    for i, (f, t, txt, c) in enumerate([
                        (0, 3, "正常", "green"),
                        (4, 7, "功耗墙", "orange"), (8, 15, "HW 降速", "orange"),
                        (16, 31, "Sync Boost", "orange"), (32, 63, "SW 热降频", "red"),
                        (64, 127, "HW 热降频", "red"), (128, 1e9, "HW 功耗刹车", "red")])]
    panels.append({"type": "state-timeline", "id": nid(), "title": "降频原因(每 host 最严重)", "datasource": DS,
        "description": "CLOCK_THROTTLE_REASONS 位掩码翻成文字(按最高置位取最严重那个)。**绿=正常**(掩码 0~3:满速、空闲、管理员设定时钟,都良性,合并成一个状态以免忙闲切换把图糊满);**橙=功耗墙(0x04),满载撞 TDP,仅提示**;**红=SW/HW 热降频(0x20/0x40),散热问题,要处理**。" + GPUDESC,
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": _y[0]},
        "targets": [{"refId": "A", "expr": gpu("max", "DCGM_FI_DEV_CLOCK_THROTTLE_REASONS")[0][0],
                     "legendFormat": "{{Hostname}}", "datasource": DS}],
        "fieldConfig": {"defaults": {"custom": {"fillOpacity": 80}, "mappings": _reason_maps,
            "thresholds": {"steps": [{"color": "green", "value": None}, {"color": "orange", "value": 4},
                                     {"color": "red", "value": 32}]}}, "overrides": []},
        # showValue=never:色块上不印文字,只靠颜色 —— 绿的时候满屏"正常"两个字纯属噪音,
        # 而颜色本身已经把信息说完了。具体是哪种降频原因、持续多久,悬停看 tooltip。
        # mergeValues 保持 True:相同状态连成一段,tooltip 给的是【这一段的起止 + 时长】
        # (如"功耗墙 8m30s"),比逐采样点的瞬时值有用。
        "options": {"showValue": "never", "mergeValues": True,
                    "tooltip": {"mode": "single", "sort": "none"},
                    "legend": {"showLegend": True, "displayMode": "list", "placement": "bottom"}}})
    _y[0] += 8

    return {"uid": "llm-gpu", "title": "GPU硬件监控", "tags": ["llm", "gpu"],
            "timezone": "browser", "schemaVersion": 42, "refresh": "30s", "time": {"from": "now-3h", "to": "now"},
            "templating": {"list": [VAR_SERVICE_ALL,
                {"name": "gpu_model", "type": "query", "datasource": DS, "label": "GPU 类型",
                 "description": "按 GPU 型号过滤(DCGM 的 modelName),多选;表格与曲线面板都生效",
                 "query": {"query": "label_values(DCGM_FI_DEV_GPU_TEMP, modelName)", "refId": "gm"},
                 # regex 把 "NVIDIA H100 80GB HBM3" 截成 "H100" —— 注意它同时改掉 text 和 value,
                 # 所以查询侧的匹配器必须是【子串】 modelName=~".*$gpu_model.*",不能是全等。
                 "regex": "/NVIDIA ([A-Z]+[0-9]+).*/",
                 "refresh": 2, "includeAll": True, "allValue": ".*", "multi": True,
                 "current": {"text": "All", "value": "$__all"}, "sort": 1},
                {"name": "host", "type": "query", "datasource": DS, "label": "GPU 主机",
                 "description": "按 GPU 服务器过滤,多选",
                 "query": {"query": "label_values(DCGM_FI_DEV_GPU_TEMP, Hostname)", "refId": "hv"},
                 "refresh": 2, "includeAll": True, "allValue": ".*", "multi": True,
                 "current": {"text": "All", "value": "$__all"}, "sort": 1}]},
            "panels": panels}

# ═══════════════ 健康 dashboard:所有服务一张表 + up + 副本 ═══════════════
def health_table():
    # 每 service 一行:就绪/总数、QPS、错误率、TTFT p95、出词 tok/s(全按 bodylog service 口径,-leader 已并)。
    # 全部剔除 unknown(非真实服务=归因不到 ModelRoute 的请求),三面板同集合
    R, T, D = repl_ready(), repl_actual(), repl_desired()
    # 2=就绪>=期望 / 1=有就绪但不足期望 / 0=无就绪。
    # 分母用【期望】而非【实际】:实际含 maxSurge surge 出来的新副本,拿它当分母会让
    # 每次滚动更新都把满员的服务染成「降级」(2026-08-27 kimi 的误报就是这么来的)。
    state = '(%s > bool 0) + (%s >= bool %s)' % (R, R, D)
    # 行门控:只保留近 24h 内副本数 >0 过的 service。ModelRoute/namespace 删除后,openresty 落的
    # bodylog 请求计数器仍冻结在 exporter 内存里持续上报(不随对象删除消失,累计跨天也不重置,
    # 滚天清不掉),会让早已下线的 service 永远以红 DOWN 幽灵行赖在表里。用 max_over_time(...[24h])>0
    # 把「24h 都没有副本(或根本没有副本 series)」的 service 整行剔除。阈值取【实际副本】:真部署了但
    # 短时(<24h)缩到 0 的仍保留,彻底下线(无 workload / 无副本 series)的才去掉。
    # 挂在所有会【单独产生 service 行】的查询上(请求派生的 QPS/错误率/TTFT/出词 + 引擎派生的并发/重启);
    # 副本三列与状态本就基于副本 series,幽灵 service 天然为空,不需再门控。
    GATE = ('\n  and on(service) (max by(service)('
            'max_over_time(bodylog_service_replicas{service=~"$service",service!="unknown"}[24h])) > 0)')
    qs = [
        (R, "就绪"),
        (D, "期望"),
        (T, "实际"),
        ('sum by(service)(%s)' % mrg('rate(bodylog_requests_total{backend!="(none)",service=~"$service",service!="unknown"}[5m])') + GATE, "QPS"),
        # 只算 5xx:4xx 里混着 400(客户端发坏请求)/499(客户端断连)/429(限流),
        # 反映的不是服务侧健康;且 exporter 只暴露 status_class 无精确码,499 无法单独排除
        # (要精确排 499 得改 openresty/bodylog-exporter-go/metrics.go:97 的 statusClass)
        # `or (0 * 全量)`:某 service 当前一条 5xx 都没有时分子是空 vector,不兜底整行会没有这个字段
        # (表格里显示空单元格而非 0%)
        ('(sum by(service)(%s) or (0 * sum by(service)(%s))) / clamp_min(sum by(service)(%s),0.001)'
         % (mrg('rate(bodylog_requests_total{status_class="5xx",backend!="(none)",service=~"$service",service!="unknown"}[5m])'),
            mrg('rate(bodylog_requests_total{backend!="(none)",service=~"$service",service!="unknown"}[5m])'),
            mrg('rate(bodylog_requests_total{backend!="(none)",service=~"$service",service!="unknown"}[5m])')) + GATE, "错误率"),
        # 同样用 native histogram:_bucket 上界 10s 会把 p95 死死钉在 10(实测过)
        # 同样扣掉非流式(它们的 frt≈rt 会把 TTFT 抬到 RT 的量级),口径与性能页 TTFT 面板一致
        ('histogram_quantile(0.95, %s)' % ttft_gated(
            'sum by(service)(%s)' % mrg('rate(bodylog_ttft_seconds{service=~"$service",service!="unknown"}[5m])'),
            'sum by(service)(%s)' % mrg('rate(bodylog_rt_seconds{stream="unknown",service=~"$service",service!="unknown"}[5m])')) + GATE,
         "TTFT_p95"),
        ('sum by(service)(%s)' % mrg('rate(bodylog_completion_tokens_total{service=~"$service",service!="unknown"}[1m])') + GATE, "出词tok/s"),
        (state, "状态"),
        # 当前并发 = 引擎侧正在处理的请求数之和。openresty 的 adaptive_cc_conc 也能反映在途并发,
        # 但它缺 auto-scaling-test/kimi-sglang 那条 route(实测只有 2/3 个服务有),引擎侧三个全覆盖。
        # 本 dashboard 没有 $service 变量,所以不能用 flt(),直接 and on(service) 交 bodylog 活服务白名单(GATE)。
        ('sum by(service)(%s)' % eng('{__name__=~"sglang:num_running_reqs|vllm:num_requests_running"}') + GATE, "并发"),
        # 24h 内容器重启次数:kube-state-metrics 只有 namespace/pod,靠 POD2SVC 桥接到 service
        # (跟 GPU 面板同一套桥:引擎指标给 leader,kube_pod_owner 给 LWS worker)
        # round():increase() 会在窗口边界做线性外推,即使计数器只按整数跳,结果也是小数
        # (实测 4.04 —— 由 4 条短命 series 各贡献 ~1.01 相加而来;pod 每次重建都会新起一条
        #  series,kimi-k25-1 一天内重建多次,24h 采样点只有 42/25/55/42/142 而非满窗 2880)。
        ('round(sum by(service)(increase(kube_pod_container_status_restarts_total[24h])\n'
         '  * on(namespace,pod) group_left(service) %s))'
         % POD2SVC + GATE, "重启24h"),
    ]
    tg = [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "datasource": DS, "format": "table", "instant": True} for i, (e, l) in enumerate(qs)]
    # rename / order 都由 qs 推导,不手写 refId 字母:qs 里插一列就要把后面每个
    # "Value #X" 往后挪一格,手维护迟早错位(而错位是静默的 —— 列名对了值是别人的)。
    ref = {lbl: "Value #" + chr(65 + i) for i, (_, lbl) in enumerate(qs)}
    rename = dict({v: k for k, v in ref.items()}, service="service")
    # 列顺序(indexByName 要原始字段名,所以过 ref 翻译一次)
    cols = ["状态", "就绪", "期望", "实际", "重启24h", "QPS", "并发", "错误率", "TTFT_p95", "出词tok/s"]
    order = dict({"service": 0}, **{ref[c]: i + 1 for i, c in enumerate(cols)})
    # 列宽:全部列(含 service)定宽。只给数字列定宽的话,service 会自动吃掉所有剩余空间
    # 变得过宽(最长的名字也就 ~34 字符);全定宽后右侧留白,总比第一列拉到半屏强。
    ov = [{"matcher": {"id": "byName", "options": n}, "properties": [{"id": "custom.width", "value": w}]}
          for n, w in [("service", 300), ("状态", 84), ("就绪", 64), ("期望", 64), ("实际", 64), ("QPS", 104),
                       ("重启24h", 80), ("并发", 72), ("错误率", 88), ("TTFT_p95", 96), ("出词tok/s", 96)]]
    ov += [
        {"matcher": {"id": "byName", "options": "状态"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "mappings", "value": [{"type": "value", "options": {
                "0": {"text": "DOWN", "color": "red"}, "1": {"text": "降级", "color": "orange"}, "2": {"text": "UP", "color": "green"}}}]},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "orange", "value": 1}, {"color": "green", "value": 2}]}}]},
        {"matcher": {"id": "byName", "options": "错误率"}, "properties": [{"id": "unit", "value": "percentunit"},
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"steps": [{"color": "green", "value": None}, {"color": "orange", "value": 0.02}, {"color": "red", "value": 0.05}]}}]},
        {"matcher": {"id": "byName", "options": "TTFT_p95"}, "properties": [{"id": "unit", "value": "s"}]},
        {"matcher": {"id": "byName", "options": "重启24h"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 3}]}}]},
        {"matcher": {"id": "byName", "options": "QPS"}, "properties": [{"id": "unit", "value": "reqps"}]},
    ]
    panels.append({"type": "table", "id": nid(), "title": "当前服务健康", "datasource": DS,
                   "description": "类 monitor 主页:每 service 一行 —— 状态(UP 绿/降级 橙=就绪<期望/DOWN 红)、就绪/期望/实际副本、QPS、并发(引擎侧 num_running 之和)、错误率、TTFT p95、出词速率(bodylog 口径,-leader 已归并)。副本三列:期望=工作负载 spec.replicas(LWS 取 LWS 本身),实际=EndpointSlice 全部(滚动更新时会比期望多出 maxSurge,那是正常 surge 不是降级),就绪=conditions.ready。错误率【只算 5xx】=服务侧错误;4xx 不计(含 400 客户端坏请求 / 499 客户端断连 / 429 限流,非服务健康信号)。>2% 橙 / >5% 红。",
                   "gridPos": {"h": 9, "w": 24, "x": 0, "y": _y[0]}, "targets": tg,
                   "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": ov},
                   "transformations": [{"id": "merge", "options": {}},
                       {"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": rename, "indexByName": order}}],
                   "options": {"showHeader": True, "sortBy": [{"displayName": "service"}]}})
    _y[0] += 9

def component_table():
    """组件健康:openresty / logserver(bodylog) / bodylog-exporter / autoconfig / CART。

    这些组件【没有 ServiceMonitor】(实测 Prometheus 的 scrape target 里只有 bodylog exporter),
    所以健康度走 kube-state-metrics 的副本口径:就绪/期望 + 24h 重启次数。
    CART 是按服务分开部署的(cart-kimi-k25 / cart-mf-fallback / ...),用 .*cart.* 一并收进来。
    """
    SEL = 'deployment=~"openresty|bodylog.*|autoconfig-controller|.*cart.*|decision-gen"'
    R = 'sum by(namespace,deployment)(kube_deployment_status_replicas_ready{%s})' % SEL
    T = 'sum by(namespace,deployment)(kube_deployment_spec_replicas{%s})' % SEL
    state = '(%s > bool 0) + (%s >= bool %s)' % (R, R, T)
    # 重启:pod -> ReplicaSet -> Deployment(RS 名去掉末尾 -<hash> 即 Deployment 名)
    # round() 同上:increase() 外推会产生小数
    RST = ('round(sum by(namespace,deployment)(increase(kube_pod_container_status_restarts_total[24h])\n'
           '  * on(namespace,pod) group_left(deployment)\n'
           '    (0 * label_replace(kube_pod_owner{owner_kind="ReplicaSet"}, "deployment", "$1", "owner_name", "(.*)-[^-]+") + 1)))\n'
           '  and on(namespace,deployment) (%s)' % T)
    qs = [(state, "状态"), (R, "就绪"), (T, "期望"), (RST, "重启24h")]
    tg = [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "datasource": DS, "format": "table", "instant": True}
          for i, (e, l) in enumerate(qs)]
    rename = {"Value #A": "状态", "Value #B": "就绪", "Value #C": "期望", "Value #D": "重启24h",
              "namespace": "namespace", "deployment": "组件"}
    order = {"deployment": 0, "namespace": 1, "Value #A": 2, "Value #B": 3, "Value #C": 4, "Value #D": 5}
    ov = [{"matcher": {"id": "byName", "options": n}, "properties": [{"id": "custom.width", "value": w}]}
          for n, w in [("组件", 240), ("namespace", 200), ("状态", 96), ("就绪", 72), ("期望", 72), ("重启24h", 88)]]
    ov += [
        {"matcher": {"id": "byName", "options": "状态"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "mappings", "value": [{"type": "value", "options": {
                "0": {"text": "DOWN", "color": "red"}, "1": {"text": "降级", "color": "orange"},
                "2": {"text": "UP", "color": "green"}}}]},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "red", "value": None}, {"color": "orange", "value": 1}, {"color": "green", "value": 2}]}}]},
        {"matcher": {"id": "byName", "options": "重启24h"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 3}]}}]},
    ]
    panels.append({"type": "table", "id": nid(), "title": "组件健康(openresty / logserver / autoconfig / CART)",
                   "datasource": DS,
                   "description": "网关与控制面组件的副本健康:就绪/期望 + 24h 重启次数。"
                                  "这些组件没有 ServiceMonitor(Prometheus 只 scrape 了 bodylog exporter),"
                                  "所以走 kube-state-metrics 的副本口径 —— 能发现「挂了/没起来/在反复重启」,"
                                  "但看不到进程内部指标(如 openresty 的 QPS 在上面的服务表里看)。"
                                  "CART 按服务分开部署,故有多行。",
                   "gridPos": {"h": 11, "w": 24, "x": 0, "y": _y[0]}, "targets": tg,
                   "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": ov},
                   "transformations": [{"id": "merge", "options": {}},
                       {"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": rename,
                                                      "indexByName": order}}],
                   "options": {"showHeader": True, "sortBy": [{"displayName": "组件"}]}})
    _y[0] += 11

def autoconfig_panels():
    """autoconfig(控制面 operator)的深层健康 —— 组件健康表只能回答「进程在不在」。

    ⚠️ 两副本主备,【只看 leader】:standby 不跑 controller,它的队列恒空、reconcile 计数为 0,
    混在一起会把 leader 的异常稀释掉。用 controller-runtime 自带的
    leader_election_master_status==1 过滤(leader=1 / standby=0)。
    """
    # ⚠️ leader 过滤必须【贴着原始 series】做,不能放在 sum() 外面 ——
    #    sum() 不带 by 会把 pod 标签一起丢掉,外层 `and on(pod)` 就没得匹配、结果恒空(踩过)。
    J = 'job=~"autoconfig.*"'
    def leader(m):
        return '(%s\n     and on(pod) (leader_election_master_status{%s} == 1))' % (m, J)

    # 卡死探测:健康探针(healthz.Ping)只证明进程能应答 HTTP,发现不了 reconcile 卡死。
    ts("autoconfig 卡死探测(队列积压 / 未完成时长)",
       [('sum(%s)' % leader('workqueue_depth{%s}' % J), "队列积压"),
        ('sum(%s)' % leader('workqueue_unfinished_work_seconds{%s}' % J), "当前调谐已跑(秒)"),
        ('sum(%s)' % leader('workqueue_longest_running_processor_seconds{%s}' % J), "最久处理(秒)")],
       unit="short", w=8, x=0, minv=0,
       desc="健康时三条都贴 0。【未完成时长持续上涨且不归零 = reconcile 卡死】"
            "(如 cart ConfigMap wedge:peer 不更新但进程活着、探针全绿、restartCount 恒 0)。"
            "队列积压持续 >0 = 处理速度跟不上入队。只统计 leader 副本。")

    ts("autoconfig reconcile(次/分)",
       [('60 * sum by(result)(%s)' % leader('rate(controller_runtime_reconcile_total{%s}[$__rate_interval])' % J), "{{result}}"),
        ('60 * sum(%s)' % leader('rate(controller_runtime_reconcile_errors_total{%s}[$__rate_interval])' % J), "errors")],
       unit="short", w=8, x=8, minv=0,
       desc="result=requeue_after 是常态 —— 每次调谐结束都预约 resyncEvery(10s)后再跑一轮"
            "(informer 事件之外的兜底重扫),所以【空转也有稳定速率,不代表配置在变】,稳态约 16 次/分。"
            "判断有没有真失败看 errors 这条(应恒 0);retries_total 会跟着 requeue 涨,不是失败次数。")

    ts("autoconfig → apiserver(次/分 · 按状态码)",
       [('60 * sum by(code)(%s)' % leader('rate(rest_client_requests_total{%s}[$__rate_interval])' % J), "{{code}}")],
       unit="short", w=8, x=16, minv=0,
       desc="controller 对【k8s kube-apiserver】的调用(list/watch ModelRoute、读写 ConfigMap、"
            "查 Pod/EndpointSlice、续 Lease),与推理服务无关。出现 429 = 被 APF 限流,"
            "此时调谐会变慢甚至堆积。")
    _y[0] += 8

def build_health():
    reset()
    row("服务健康总览")
    health_table()
    row("组件健康(网关 / 控制面)")
    component_table()
    collapsed_row("autoconfig 控制面详情(点击展开:卡死探测 / reconcile / apiserver)", autoconfig_panels)
    row("历史")
    up_panel()
    _y[0] += 8
    replicas_panel()
    _y[0] += 8
    return {"uid": "llm-health", "title": "服务健康总览", "tags": ["llm", "health"],
            "timezone": "browser", "schemaVersion": 42, "refresh": "30s", "time": {"from": "now-1h", "to": "now"},
            # graphTooltip=2(Shared tooltip):state-timeline 只能显示单值(0/1/2 三态),
            # 塞不下 ready/total 两个数字 → 划过状态条时,下方「历史副本数」同步弹 tooltip,
            # 从那里读该时刻的 total(虚线)/ready(实线)具体个数。
            "graphTooltip": 2,
            "templating": {"list": [VAR_SERVICE_ALL]}, "panels": panels}

# ══════════════════════════════════════════════════════════════════════
# H3 视频生成(minimax-h3):积压 / 异常 / 后端 SGLang / 副本
#
# ⚠️ 聚合口径是这张表最容易做错的地方 —— H3 的指标分两类(见 server.py 的 HELP):
#   · **集群维度**:每个副本都从共享 PostgreSQL 读同一份值、各报一次。
#     h3_queue_tasks / completed_24h / oldest_*_age / waiting_takeover / backend_unavailable
#     → 必须 max() 去重;用 sum() 会按副本数(当前 4)成倍放大。
#   · **每副本自己的值**:running_on_instance / backend_up / backend_jobs(各报各的 SGLang)
#     → 这几个才该 sum()/按 pod 展开。
#
# ⚠️ h3_queue_tasks 是【库里各状态的任务数】,含历史累计的 succeeded —— 画"全部状态"
#   会被 succeeded 的存量压平,看不出问题(第一版就踩了:三张图都在画同一个 32)。
#   所以这里只画 **queued/running(积压)**,完成量交给 completed_24h(滚动窗口)。
#
# ⚠️ ts() 不推进 _y[0](只读不写),每排面板之后必须手动 _y[0] += 8,
#   否则下一个 row() 会压在上一排面板头上(第一版踩过:面板串到别的分组去了)。
# ══════════════════════════════════════════════════════════════════════

def h3_status_table():
    """H3 当前状态:每个工作负载一行(router / fl2va / ref2va)。

    所有列都按 **deployment** 对齐,而 H3 的业务指标本身没有 deployment 标签,
    所以要把它们映射过去:
      · running_on_instance 的 h3_instance 是 **Pod 名** → 正则剥掉 "-<rs哈希>-<后缀>";
      · h3_queue_tasks 的 capability(fl2va/ref2va) → 拼成 "h3-minimax-h3-server-<capability>"。

    两个坑(都踩过,写下来免得再犯):
      ① `or (0 * X)` 兜底时,右侧必须也 `sum by (deployment)` —— 否则右侧还带着
         namespace/job/instance 等标签,与左侧标签集不同,`or` 不去重,表格会出现重复行。
      ② 重启数按 Pod 名反推 deployment 时,**选择器里就要过滤** Pod 名形状
         (`-<8~10位哈希>-<5位后缀>`)。否则 StatefulSet 时代遗留的 Pod 名
         (h3-minimax-h3-server-fl2va-0)会匹配成 deployment="h3-minimax-h3-server",
         再加上匹配不上的会归到空名字,表里多出 `?` 和半截名的假行。
    """
    NS = 'namespace="minimax-h3"'
    # 每条查询都必须 sum by (deployment) —— KSM 的原始 series 带着 __name__/container/
    # endpoint/instance/job/pod/uid 一大串标签,各条查询标签集不同,表格的 merge 就 join 不到
    # 同一行:结果是【同一个 deployment 裂成多行】(一行只有"就绪"、另一行只有"期望"),
    # 而且那些标签会全部变成多余的列。聚合掉只剩 deployment,才能合成一行。(踩过)
    R = 'sum by (deployment) (kube_deployment_status_replicas_ready{%s})' % NS
    D = 'sum by (deployment) (kube_deployment_status_replicas{%s})' % NS
    Z = '(0 * sum by (deployment) (%s))' % R          # 空闲时补 0,见坑 ①
    POD_RE = '[a-f0-9]{8,10}-[a-z0-9]{5}'
    qs = [
        (R, "就绪"),
        (D, "期望"),
        # 2=就绪>=期望 / 1=有就绪但不足 / 0=全挂。分母用期望而非实际,理由同健康总览。
        ('(%s > bool 0) + (%s >= bool %s)' % (R, R, D), "状态"),
        ('sum by (deployment) (label_replace(h3_queue_running_on_instance,'
         ' "deployment", "$1", "h3_instance", "(.*)-[^-]+-[^-]+")) or %s' % Z, "正在执行"),
        ('sum by (deployment) (label_replace(max by (capability,status) '
         '(h3_queue_tasks{status=~"queued|running"}),'
         ' "deployment", "h3-minimax-h3-server-$1", "capability", "(.*)")) or %s' % Z, "积压"),
        # ⚠️ 24h 失败数【不能】用 h3_queue_completed_24h:它带着 job/service 标签、看着像按服务分,
        #    但值是集群级的(每个副本都从共享 PG 读同一份,两个 job 报的是同一个数)——
        #    按 job 拆会把同一批失败在每行各显示一次。只能从 capability 推(实测:capability 推出
        #    fl2va=2 / ref2va 无 series,合计正好等于集群级的 2)。
        #    子查询分辨率给 5m 而不是 1h:1h 的话最近一小时内的失败要等到下个整点才进得来。
        ('round(sum by (deployment) (label_replace(delta(max by (capability,status) '
         '(h3_queue_tasks{status="failed"})[24h:5m]),'
         ' "deployment", "h3-minimax-h3-server-$1", "capability", "(.*)"))) or %s' % Z, "错误24h"),
        ('round(sum by (deployment) (increase(label_replace('
         'kube_pod_container_status_restarts_total{%s,pod=~"h3-minimax-h3-.*-%s"},'
         ' "deployment", "$1", "pod", "^(.*)-%s$")[24h:1h]))) or %s' % (NS, POD_RE, POD_RE, Z), "重启24h"),
    ]
    tg = [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "datasource": DS,
           "format": "table", "instant": True} for i, (e, l) in enumerate(qs)]
    # refId 由 qs 推导,不手写:中间插一列就要把后面每个 "Value #X" 挪一格,手维护迟早错位,
    # 而错位是静默的(列名对、值是别人的)。同 health_table。
    ref = {lbl: "Value #" + chr(65 + i) for i, (_, lbl) in enumerate(qs)}
    rename = dict({v: k for k, v in ref.items()}, deployment="工作负载")
    cols = ["状态", "就绪", "期望", "正在执行", "积压", "错误24h", "重启24h"]
    order = dict({"deployment": 0}, **{ref[c]: i + 1 for i, c in enumerate(cols)})
    ov = [{"matcher": {"id": "byName", "options": n}, "properties": [{"id": "custom.width", "value": w}]}
          for n, w in [("工作负载", 300), ("状态", 90), ("就绪", 70), ("期望", 70),
                       ("正在执行", 90), ("积压", 80), ("错误24h", 90), ("重启24h", 90)]]
    ov += [
        {"matcher": {"id": "byName", "options": "状态"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "mappings", "value": [{"type": "value", "options": {
                "0": {"text": "DOWN", "color": "red"}, "1": {"text": "降级", "color": "orange"},
                "2": {"text": "UP", "color": "green"}}}]},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "red", "value": None}, {"color": "orange", "value": 1}, {"color": "green", "value": 2}]}}]},
        {"matcher": {"id": "byName", "options": "积压"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "green", "value": None}, {"color": "orange", "value": 5}, {"color": "red", "value": 20}]}}]},
        {"matcher": {"id": "byName", "options": "错误24h"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 5}]}}]},
        {"matcher": {"id": "byName", "options": "重启24h"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 3}]}}]},
    ]
    panels.append({"type": "table", "id": nid(), "title": "当前状态", "datasource": DS,
                   "description": "每个工作负载一行。状态:UP(就绪≥期望)/降级(有就绪但不足期望)/DOWN。"
                                  "正在执行=该池各副本手上的任务数之和(单副本最多 1);积压=queued+running;"
                                  "错误24h=过去 24 小时进入 failed 终态的任务数(按能力池拆开,"
                                  "不是集群级的 h3_queue_completed_24h —— 那个按服务拆会重复计数)。"
                                  "router 没有业务指标,这几列恒为 0 属正常。",
                   "gridPos": {"h": 6, "w": 24, "x": 0, "y": _y[0]}, "targets": tg,
                   "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": ov},
                   "transformations": [{"id": "merge", "options": {}},
                       {"id": "organize", "options": {"excludeByName": {"Time": True},
                                                      "renameByName": rename, "indexByName": order}}],
                   "options": {"showHeader": True, "sortBy": [{"displayName": "工作负载"}]}})
    _y[0] += 6



def check_table_overrides(d):
    """Fail the build on a byName override that matches no column in that table.

    An override whose name matches nothing is silently ignored by Grafana, so a
    column added to one dashboard's table can be pasted into another's without
    anyone noticing -- until the ConfigMap diff on a cluster shows dozens of
    added lines that change nothing visible. That is how the H3「错误24h」column
    leaked into llm-health (see 060c9b7): the override block is duplicated per
    table, not shared, and the column was added to all three copies.

    Column names come from the organize transformation's renameByName (that is
    what the table actually displays) plus any raw legendFormat, since a target
    with a legendFormat and no rename shows up under that name.
    """
    bad = []
    for pnl in d.get("panels", []):
        if pnl.get("type") != "table":
            continue
        cols = set()
        for tr in pnl.get("transformations", []):
            if tr.get("id") == "organize":
                cols |= set(tr.get("options", {}).get("renameByName", {}).values())
        cols |= {t.get("legendFormat") for t in pnl.get("targets", []) if t.get("legendFormat")}
        # Field names Grafana synthesizes or that come straight from labels.
        cols |= {"Time", "service", "namespace", "组件", "服务", "型号"}
        for ov in pnl.get("fieldConfig", {}).get("overrides", []):
            m = ov.get("matcher", {})
            if m.get("id") == "byName" and m.get("options") not in cols:
                bad.append("%s / %s: override byName=%r matches no column %s"
                           % (d.get("uid"), pnl.get("title"), m.get("options"), sorted(cols)))
    if bad:
        raise SystemExit("dead table overrides:\n  " + "\n  ".join(bad))

def build_h3():
    reset()

    row("当前状态")
    h3_status_table()

    row("积压与吞吐")
    # ⚠️ h3_queue_tasks 只上报**实际存在的** (capability,status) 组合 —— 空闲时没有
    #   queued/running 这两行,series 整个不存在,面板会显示 "No data"。那分不清
    #   「真没积压」和「采集挂了」,所以这里补 0:
    #     · 总量:两条 target 各自 `or vector(0)`,legend 写死(补出来的 0 没有 status 标签);
    #     · 按池:用 `0 * max by(capability)(h3_queue_backend_up)` 兜底 ——
    #       backend_up 每个 capability 恒有,正好提供带正确标签的 0。
    ts("积压任务(按能力池 × 状态)",
       [('max by (capability,status) (h3_queue_tasks{status="queued"}) '
         'or label_replace(0 * max by (capability) (h3_queue_backend_up), "status", "queued", "", "")',
         "{{capability}} {{status}}"),
        ('max by (capability,status) (h3_queue_tasks{status="running"}) '
         'or label_replace(0 * max by (capability) (h3_queue_backend_up), "status", "running", "", "")',
         "{{capability}} {{status}}")],
       w=8, stacking=True,
       desc="**只画 queued/running**:h3_queue_tasks 含历史累计的 succeeded,一起画会被存量压平、"
            "看不出积压。堆叠,所以顶端就是总积压;分组同时按能力池(fl2va 文生视频 / ref2va 参考图)"
            "和状态拆开,一张图既看得出总量抬头,也看得出是哪个池、卡在排队还是在跑。"
            "空闲时补 0(而不是 No data),这样能区分「真没积压」和「采集挂了」—— "
            "h3_queue_tasks 只上报**实际存在的** (capability,status) 组合,空闲时那两行整个不存在;"
            "补零用 h3_queue_backend_up(每个 capability 恒有)再 label_replace 补上 status,"
            "这样补出来的 0 标签集与真实 series 一致,图例不会多出没名字的一条。"
            "这张图抬头 = 产能跟不上或有任务卡住。")
    ts("完成量(每 10 分钟)+ 历史累计",
       [('sum by (status) (rate(max by (capability,status) '
         '(h3_queue_tasks{status=~"succeeded|failed|cancelled"})[$__rate_interval:])) * 600',
         "{{status}}"),
        # 累计线:h3_queue_tasks 本身就是累计值,直接画(24h 实测单调、零回退)。
        # 量级与速率差两个数量级(324 vs 0~2),必须挂右轴,否则速率线会被压成一条贴地的直线。
        ('sum by (status) (max by (capability,status) '
         '(h3_queue_tasks{status=~"succeeded|failed|cancelled"}))',
         "{{status}} 累计")],
       unit="short", w=8, x=8,
       # ⚠️ interval="10m" 是这张图的关键:任务完成是【稀疏离散事件】(高峰期也才每分钟 2~4 个),
       #   窗口短于 10 分钟时曲线会在 0 和 1 之间高频跳变、糊成一片竖线(2026-09-16 实拍:
       #   2 天视图下窗口 ~190s,28% 的点是 0,峰值只有 1.33)。把最小步长顶到 10m 后
       #   $__rate_interval ≥ 10m30s,零点降到 16%、峰值 9,而积分仍精确等于真值 231。
       #   ×600 而非 ×60:读数随之改成「每 10 分钟完成数」—— 窗口≈10min 时基本都是整数。
       interval="10m",
       # 图例走 table 模式:list 模式下,挂右轴的那两条会被 Grafana 推到图例行的最右端,
       # 与左轴那两条被一大段空白隔开(2026-09-16 实拍)。table 把四条竖排在一起,
       # 顺带给出当前值/峰值 —— 累计线的"当前值"就是至今总数,正好是想看的。
       legend_calcs=LEGEND_CALCS,
       overrides=[{"matcher": {"id": "byRegexp", "options": ".* 累计$"},
                   "properties": [{"id": "custom.axisPlacement", "value": "right"},
                                  {"id": "custom.fillOpacity", "value": 0},
                                  {"id": "custom.lineStyle",
                                   "value": {"fill": "dash", "dash": [8, 8]}}]}] +
                 # 四条线颜色写死。不写死的话 Grafana 按 series 出现顺序发调色板色,
                 # 结果 failed 被分到绿色(2026-09-16 实拍)—— 失败画成绿的是会看错的。
                 # 而且顺序会随 series 有无而变(比如哪天出现 cancelled),颜色就跟着漂。
                 # 语义:成功=绿系、失败=红系;实线(速率)用正色,虚线(累计)用同系浅一档。
                 [{"matcher": {"id": "byName", "options": n},
                   "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]}
                  for n, c in [("succeeded", "green"), ("succeeded 累计", "semi-dark-green"),
                               ("failed", "red"), ("failed 累计", "orange"),
                               ("cancelled", "purple"), ("cancelled 累计", "semi-dark-purple")]],
       desc="两组线,两个纵轴:\n\n"
            "**实线(左轴)= 当前出活速度**,每 10 分钟进入终态的任务数。取自 h3_queue_tasks(累计值)的速率,"
            "不是 24h 滚动存量 —— 后者忙完之后会平在高位、看不出此刻有没有在出活。"
            "窗口跟着缩放走($__rate_interval,下限 10 分钟),所以任何时间范围下都不漏采"
            "(写死窗口时看 2 天会漏掉 20%+,failed 甚至整条消失);下限 10 分钟是因为完成是稀疏离散事件,"
            "窗口再短就会在 0/1 之间高频跳变糊成一片。偶尔出现小数是 rate 对窗口边界的外推"
            "(Prometheus 只存累计值快照,求增量必然外推),不是精度问题。\n\n"
            "**虚线(右轴)= 历史累计**,建库以来各终态的总数,只增不减。斜率就是左轴那条线。\n\n"
            "速率归零 = 当前没有任务完成(是空闲还是卡住,看左边的积压图和最老任务年龄)。"
            "拉长时间范围会被窗口平滑,速率峰值变矮属正常。failed/cancelled 抬头是质量信号。")
    # 这个**故意不补 0**:0 的含义是「有任务、刚进来 0 秒」,和「根本没有任务」是两回事,
    # 补零等于撒谎(会让"有没有卡住的任务"这个判断失真)。改成在标题里点明空闲即无数据。
    ts("最老任务年龄(空闲时无数据)",
       [('max(h3_queue_oldest_queued_age_seconds)', "最老排队"),
        ('max(h3_queue_oldest_running_age_seconds)', "最老运行中")],
       unit="s", w=8, x=16,
       desc="没有排队/运行中的任务时**不上报**,所以空闲时是 No data —— 这里**故意不补 0**:"
            "0 表示「有任务、刚进来」,与「没有任务」语义不同,补零会让判断失真。"
            "运行中那条一直涨 = 有任务卡住。")
    _y[0] += 8

    # 原先分「后端 SGLang」「副本」两节,实测证实其中两对面板是重复的(结构上必然重复,
    # 不只是当下数值巧合),已删:
    #   · SGLang 可达性(backend_up) ≡ 就绪副本数 —— Pod Ready 要求两个容器都 ready,
    #     而 sglang 容器自己就有 readinessProbe(/health),就绪数已蕴含"后端可达"。
    #   · SGLang 作业数(in_progress) ≡ 各副本正在执行的任务 —— 一个 Pod 只有一个
    #     TaskWorker、最多一条在途任务;state=queued 也必然恒 0(一次只提交一个)。
    row("运行与健康")
    ts("各副本正在执行的任务",
       [('sum by (h3_instance) (h3_queue_running_on_instance)', "{{h3_instance}}")],
       w=8, desc="每个副本手上正在跑的任务数(单副本最多 1)。既能看负载分布,也能看出谁在干活、谁闲着。")
    ts("副本数(期望 / 就绪)",
       [('kube_deployment_status_replicas{namespace="minimax-h3"}', "{{deployment}} 期望"),
        ('kube_deployment_status_replicas_ready{namespace="minimax-h3"}', "{{deployment}} 就绪")],
       w=8, x=8, desc="来自 kube-state-metrics。就绪 < 期望 = 正在滚动或有副本起不来(**包含 SGLang 没就绪**"
                      "的情况,因为 sglang 容器有自己的 readinessProbe);滚动更新时 maxSurge=1 会短暂出现就绪 > 期望。")
    ts("异常任务",
       [('max(h3_queue_waiting_takeover)', "等待接管"),
        ('max(h3_queue_backend_unavailable)', "与 SGLang 失联")],
       w=8, x=16,
       desc="两条都是**持续大于 0 才算问题**。等待接管:租约过期/为空、等别副本接手 —— 持续大于 0 = "
            "该能力池副本全挂或全卡(滚动时短暂抬头正常)。与 SGLang 失联:running 但连不上后端、仍在租约内重试。")
    _y[0] += 8

    return {"uid": "h3-video", "title": "H3 视频生成", "tags": ["h3", "video", "minimax"],
            "timezone": "browser", "schemaVersion": 42, "refresh": "30s",
            "time": {"from": "now-6h", "to": "now"},
            "graphTooltip": 2,
            "templating": {"list": []}, "panels": panels}


# 参数名 -> (生成函数, 快照文件名)。文件名是 kustomization.yaml 里引用的名字,改名要两边一起改。
TARGETS = {
    "main": (build_main, "llm-obs-dashboard.json"),
    "health": (build_health, "llm-health-dashboard.json"),
    "gpu": (build_gpu, "llm-gpu-dashboard.json"),
    "h3": (build_h3, "h3-dashboard.json"),
}


if __name__ == "__main__":
    import argparse, os
    ap = argparse.ArgumentParser(description="生成 LLM 推理 Grafana dashboard JSON")
    ap.add_argument("which", nargs="*", help="要生成的 dashboard:%s(默认全部)" % " / ".join(TARGETS))
    ap.add_argument("--stdout", action="store_true",
                    help="打印 Grafana API POST body({dashboard, overwrite}),不写文件;只能指定一个")
    ap.add_argument("--out-dir", default=os.path.dirname(os.path.abspath(__file__)),
                    help="JSON 写到哪个目录(默认本脚本所在目录)")
    args = ap.parse_args()
    names = args.which or list(TARGETS)
    # 参数写错直接报错 —— 旧入口会把未知参数静默当成 main,生成了错的 dashboard 还不自知
    unknown = [n for n in names if n not in TARGETS]
    if unknown:
        ap.error("未知 dashboard: %s(可选 %s)" % (", ".join(unknown), " / ".join(TARGETS)))
    if args.stdout:
        if len(names) != 1:
            ap.error("--stdout 只能指定一个 dashboard")
        d = TARGETS[names[0]][0]()
        check_table_overrides(d)
        print(json.dumps({"dashboard": d, "overwrite": True, "message": "build_dash.py " + names[0]}))
    else:
        for n in names:
            d = TARGETS[n][0]()
            check_table_overrides(d)
            path = os.path.join(args.out_dir, TARGETS[n][1])
            with open(path, "w", encoding="utf-8") as f:
                json.dump(d, f, ensure_ascii=False, indent=2)   # 格式固定:改格式会让快照 diff 整片变动
            print("wrote %s  uid=%s panels=%d" % (path, d.get("uid"), len(d.get("panels", []))), file=sys.stderr)
