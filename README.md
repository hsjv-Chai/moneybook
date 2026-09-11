# 记账本 MoneyBook

一个本地优先的 macOS 个人记账应用：**SwiftUI + SwiftData + Swift Charts**，中文界面，零第三方依赖，不联网、不上传任何数据。

## 功能

- **概览**：本月/上月/近三月/今年/自定义时间范围，收入·支出·结余·总资产四张卡片，近 6 个月收支柱状图、支出构成环形图、最近流水。
- **流水**：原生表格展示明细，可按时间范围、账户、类型、分类筛选，也可按备注/分类/账户搜索；右键菜单编辑删除，选中后按 Delete 删除，双击行编辑。
- **账户**：账户余额与总资产汇总，支持新增/编辑/归档账户，支持账户之间转账（转出转入余额同步变化，净资产不变）。
- **统计**：月度收支趋势（6/12/24 个月）、分类排行与占比、账户余额分布。
- **设置**：默认记账账户、已归档显示开关、分类管理（图标与配色）、数据库位置定位与清空数据。

金额全程使用 `Decimal`，统一保留两位小数，不使用浮点数。

## 环境要求

- macOS 14 或更高版本（SwiftData 与 `SectorMark` 的下限）
- Xcode（含命令行工具）。若 `xcode-select` 指向 CommandLineTools 而非 Xcode.app，运行脚本会自动显式指定 `DEVELOPER_DIR`

## 运行

```bash
./script/build_and_run.sh            # 构建并启动应用
./script/build_and_run.sh --test     # 运行单元测试
./script/build_and_run.sh --selftest # 无界面自检（校验数据层是否正常）
./script/build_and_run.sh --logs     # 启动并跟踪应用日志
./script/build_and_run.sh --telemetry # 启动并按子系统过滤日志
./script/build_and_run.sh --verify   # 启动并确认进程存活
./script/build_and_run.sh --debug    # 在 lldb 下启动
```

脚本会把可执行文件打包成 `dist/MoneyBook.app` 后再用 `open` 启动，因此应用拥有正常的 Dock 图标、窗口与菜单栏行为。

> 说明：脚本内部固化了三处构建环境设置——显式 `DEVELOPER_DIR`、把 SwiftPM 缓存重定向到项目内 `.build/`（避免写入 `$HOME` 下的缓存目录）、以及 `--disable-sandbox`（在受限环境中 SwiftPM 自身的沙箱会失败）。

## 数据

数据库为 SwiftData 生成的 SQLite 文件：

```
~/Library/Application Support/MoneyBook/MoneyBook.store
```

可通过环境变量 `MONEYBOOK_DATA_DIR` 覆盖存放目录（测试与自检用）。应用内「设置 → 数据」可以定位文件、查看统计、清空数据。

## 快捷键

| 快捷键 | 功能 |
| --- | --- |
| `⌘N` | 记一笔 |
| `⌘⇧T` | 转账 |
| `⌘F` | 搜索流水 |
| `⌘,` | 打开设置 |
| `Delete` | 删除选中的流水 |

## 项目结构

```
Sources/MoneyBook/
  App/       应用入口、场景、命令与共享状态
  Models/    SwiftData 模型（Account / EntryCategory / Entry）与统计值类型
  Services/  持久化、余额计算、统计聚合、校验、种子数据
  Views/     界面（概览 / 流水 / 账户 / 统计 / 设置）与公共组件
  Support/   金额与日期格式化、颜色、精度处理
Tests/MoneyBookTests/   数据层与统计逻辑的单元测试
script/build_and_run.sh 统一的构建、运行、测试入口
```

## 测试覆盖

`swift test` 覆盖余额累加、转账对净资产的影响、输入校验、归档与删除保护、跨月/跨年归属、空数据、金额精度、筛选组合、种子数据幂等、清空数据，以及磁盘数据库重开后数据仍在；另有一项 5000 笔流水下的月度汇总性能冒烟测试。

## 未包含

预算、周期账单提醒、CSV 导入导出、多币种、标签、小票附件、菜单栏常驻、全局快捷键、iOS 端与任何联网能力。
