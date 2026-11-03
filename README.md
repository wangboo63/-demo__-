# 绿茵战术卡（GreenTacticsCard）

> 足球战术卡牌游戏 · Godot 4.7 · 个人作品集项目
> 打牌驱动场上球员实时运动，带真实足球规则（越位/犯规/出界）的完整比赛模拟。

## 快速开始

- 引擎：**Godot 4.7.1**（导入项目后直接运行）
- 入口：项目主场景为 `Ui/00_beginning.tscn`，从开始界面进入游戏
- 流程：开始 → 过渡/新游戏 → 战斗 → 胜利 / 失败 → 重新开始

## 目录结构

```
green-tactics-card/
├── Ui/                 # 界面场景 + 脚本（开始/过渡/胜负）
│   ├── 00_beginning.tscn   开始界面
│   ├── 01_guodu.tscn       过渡/存档选择
│   ├── 03_win.tscn         胜利界面
│   └── 04_failure.tscn     失败界面
├── Scencs/
│   └── 03_fight.tscn       主战斗场景
├── Scripts/            # 核心逻辑脚本
│   ├── data_loader.gd      CSV 数据加载器（全局类）
│   ├── buff_system.gd      Buff/Debuff 系统
│   ├── fight_scene.gd      战斗主控（回合/卡牌/AI/规则）
│   ├── player_unit.gd      球员独立状态机 FSM
│   └── ball.gd             球独立状态机 FSM
├── Prefabs/
│   └── card.tscn           卡牌预制体（底板/名称/费用/描述）
├── csv/                 # 全部配置表（数据驱动，改表不改代码）
│   ├── card_config.csv     卡牌（35 张）
│   ├── buff_config.csv      Buff
│   ├── ai_config.csv        AI
│   ├── formation_config.csv 阵型
│   ├── relic_config.csv     遗物
│   ├── event_config.csv     事件
│   └── things_config.csv    地图节点/商店
├── shuoming/            # 设计文档
│   ├── 绿茵战术卡_游戏策划书V1.1.docx
│   └── 绿茵战术卡_prd文档.docx
├── Resource/           # 资源目录（预留）
├── project.godot        # 工程配置（主场景、窗口等）
└── README.md            # 本文件
```

## 核心玩法

- **纯时间制**：整场 120 秒，时间到按比分定胜负（支持平局）
- **战术点**：随时间恢复（每 8 秒 +1，封顶 4 点），出牌扣点、点数不足禁出
- **卡牌驱动跑位**：每张卡对应专属跑位方案，打出后给球员下订单
- **球员/球各自状态机**：带球/传球/射门/逼抢/盯防，球有真实飞行轨迹
- **真实足球规则**：越位、犯规任意球、出界（界外球/角球/门球）

## 规则参数

常量集中在 `Scripts/fight_scene.gd` 顶部，改数值即可调：比赛时长、战术点恢复、射门成功率、Buff 扣减节奏等。卡牌/Buff/AI 数值只改 `csv/` 下的表。

## 文档

设计文档在 `shuoming/`：`游戏策划书 V1.1` + `PRD 文档`。
