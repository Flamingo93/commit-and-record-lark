# commit-and-record-lark

一个 [Claude Code](https://claude.ai/code) 的 Skill 插件，在执行 git commit 时自动将提交信息记录到**飞书多维表格（Bitable）**，实现代码提交的追踪与分析。

所有项目共享同一张多维表格，通过 `repository` 字段区分不同仓库。

## 功能

- **一键 commit + 记录** — 执行 `/commit-and-record-lark` 即可完成 git commit 并同步到飞书多维表格
- **自动采集 commit 元数据** — 仓库名、分支、作者、提交时间、变更行数、文件数等
- **Session 成本追踪** — 自动解析 Claude Code 的 transcript 文件，按模型计算每次 commit 区间的 token 消耗和预估费用（增量计算）
- **多维表格自动初始化** — 一条命令完成飞书多维表格的创建、字段配置、权限设置和视图排布
- **关联已有表格** — 支持通过 URL 直接关联已有的飞书多维表格
- **跨项目共享** — 全局安装，在任意 git 仓库中均可使用

## 前置条件

- [Claude Code](https://claude.ai/code) 已安装
- [`lark-cli`](https://github.com/nicepkg/lark-cli) 已安装并完成认证（`lark-cli auth login`）
- `jq` 已安装
- 当前目录在一个 git 仓库内

> 本项目依赖 `lark-cli` 的多维表格（Base）能力，包括 `+base-create`、`+table-list`、`+field-create`、`+record-upsert`、`+view-set-visible-fields` 等命令，用于创建和操作飞书多维表格。

## 安装

将本仓库克隆到 Claude Code 的全局 skills 目录，即可作为 Skill 使用：

```bash
# 克隆仓库
git clone https://github.com/<your-org>/commit-and-record-lark.git

# 创建符号链接到 Claude Code 的 skills 目录
ln -s "$(pwd)/commit-and-record-lark" ~/.claude/skills/commit-and-record-lark
```

或者直接克隆到 skills 目录下：

```bash
git clone https://github.com/<your-org>/commit-and-record-lark.git ~/.claude/skills/commit-and-record-lark
```

安装完成后，在 Claude Code 中即可通过 `/commit-and-record-lark` 调用。

## 使用方法

### 首次使用：初始化多维表格

```
/commit-and-record-lark setup
```

或手动执行：

```bash
bash ~/.claude/skills/commit-and-record-lark/setup.sh
```

该命令会自动：
1. 通过 `lark-cli` 创建飞书多维表格
2. 创建 13 个字段（commit 信息 + session 成本）
3. 授予当前用户管理员权限
4. 配置视图的字段顺序和按仓库分组
5. 将配置保存到 `bitable-meta.json`

初始化只需执行一次。

### 日常使用：commit 并记录

```
/commit-and-record-lark
```

这是最常用的操作：提交当前变更并将 commit 信息写入飞书多维表格。

### 重置（创建新表格）

```
/commit-and-record-lark reset
```

会创建一个全新的多维表格并覆盖旧配置。

### 关联已有表格

```
/commit-and-record-lark attach https://my.feishu.cn/base/xxx?table=yyy
```

从飞书多维表格 URL 中解析 `base_token` 和 `table_id`，验证连通性后保存到配置文件。

### 手动记录指定 commit

```bash
bash ~/.claude/skills/commit-and-record-lark/record-commit.sh <commit-hash>
```

## 记录的字段

| 字段 | 类型 | 说明 |
|------|------|------|
| repository | text | 仓库名（owner/repo），按此分组 |
| commit_message | text | 提交信息 |
| session_cost | number (USD) | 本次 commit 区间的预估费用 |
| session_input_tokens | number | 输入 token 数（含 cache） |
| session_output_tokens | number | 输出 token 数 |
| commit_hash | text | 完整 SHA 哈希 |
| branch | text | 当前分支名 |
| author | text | 提交作者 |
| author_email | text | 作者邮箱 |
| commit_time | datetime | 提交时间 |
| lines_added | number | 新增行数 |
| lines_deleted | number | 删除行数 |
| files_changed | number | 修改文件数 |

## Session 成本计价

通过解析 Claude Code 的 session transcript（JSONL）文件，按模型分别计算 token 消耗和费用。每次记录只计算自上次记录以来新增的消耗（增量计算）。

| 模型 | input | output | cache_write | cache_read |
|------|-------|--------|-------------|------------|
| claude-opus-4-6 | $5/M | $25/M | $6.25/M | $0.50/M |
| claude-sonnet-4-6 | $3/M | $15/M | $3.75/M | $0.30/M |
| claude-haiku-4-5 | $1/M | $5/M | $1.25/M | $0.10/M |

## 项目结构

```
commit-and-record-lark/
├── SKILL.md            # Skill 定义文件（Claude Code 读取）
├── setup.sh            # 初始化飞书多维表格
├── record-commit.sh    # 记录 commit 到多维表格
├── attach.sh           # 关联已有多维表格
├── bitable-meta.json   # 多维表格配置（自动生成，已 gitignore）
└── .last-offset        # transcript 偏移量（自动生成，已 gitignore）
```

## 故障排查

- **config not found** — 运行 `setup.sh` 完成初始化
- **lark-cli 权限不足** — 运行 `lark-cli auth login` 重新授权
- **字段写入失败** — 检查 `bitable-meta.json` 中的 `base_token` 和 `table_id` 是否正确

## 许可证

MIT
