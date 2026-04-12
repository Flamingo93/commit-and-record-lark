---
name: commit-and-record-lark
version: 1.0.0
description: "将 git commit 信息自动记录到飞书多维表格。当用户需要记录 commit、追踪代码提交、初始化 commit 记录表时使用。"
---

# Commit Record

将 git commit 信息自动记录到飞书多维表格（Bitable），用于代码提交记录的追踪和分析。
所有项目共享同一张多维表格，通过 repository 字段区分不同仓库。

## 前置条件

- `lark-cli` 已安装并完成认证（参考 `lark-shared` skill）
- `jq` 已安装
- 当前目录在一个 git 仓库内

## 首次使用流程

用户首次使用时，需要先初始化飞书多维表格：

```bash
bash "$HOME/.claude/skills/commit-and-record-lark/setup.sh"
```

该脚本会：
1. 通过 `lark-cli base +base-create` 创建一个新的飞书多维表格
2. 创建 13 个字段（repository, commit_message, commit_hash, branch, author, author_email, commit_time, lines_added, lines_deleted, files_changed, session_cost, session_input_tokens, session_output_tokens）
3. 为当前用户授予管理员权限
4. 配置默认视图的字段顺序和按 repository 分组
5. 将配置保存到 `~/.claude/skills/commit-and-record-lark/bitable-meta.json`

初始化只需执行一次，之后在任意 git 仓库中都可以直接记录 commit。

## 默认行为

不带任何子命令直接执行 `/commit-and-record-lark` 时，执行默认操作：**提交当前变更并记录到飞书多维表格**。

具体流程：
1. 将当前已修改的文件 `git commit`
2. 执行 `record-commit.sh HEAD` 将该 commit 记录到飞书多维表格

这是最常用的操作，等价于"commit 并记录"。

## 管理多维表格

### 重置（新建表格）

用户在 skill 名字后加 `reset`（如 `/commit-and-record-lark reset`）时，执行：

```bash
bash "$HOME/.claude/skills/commit-and-record-lark/setup.sh" --force
```

会创建一个全新的多维表格并覆盖旧配置。

### 关联已有表格

用户在 skill 名字后加 `attach <URL>`（如 `/commit-and-record-lark attach https://my.feishu.cn/base/xxx?table=yyy`）时，执行：

```bash
bash "$HOME/.claude/skills/commit-and-record-lark/attach.sh" "<URL>"
```

从飞书多维表格 URL 中解析 base_token 和 table_id，验证连接后保存到配置文件。

## 记录 commit

### 手动记录最近一次 commit

```bash
bash "$HOME/.claude/skills/commit-and-record-lark/record-commit.sh"
```

### 记录指定 commit

```bash
bash "$HOME/.claude/skills/commit-and-record-lark/record-commit.sh" <commit-hash>
```

## 记录的字段

| 字段 | 类型 | 说明 |
|------|------|------|
| repository | text | 仓库名 (owner/repo)，主字段，按此分组 |
| commit_message | text | 提交信息 |
| session_cost | number | 本次 commit 区间的预估费用 (USD) |
| session_input_tokens | number | 本次 commit 区间的输入 token 数（含 cache） |
| session_output_tokens | number | 本次 commit 区间的输出 token 数 |
| commit_hash | text | 完整 SHA 哈希 |
| branch | text | 当前分支名 |
| author | text | 提交作者 |
| author_email | text | 作者邮箱 |
| commit_time | datetime | 提交时间 |
| lines_added | number | 新增行数 |
| lines_deleted | number | 删除行数 |
| files_changed | number | 修改文件数 |

## 配置文件

全局配置存储在 `~/.claude/skills/commit-and-record-lark/bitable-meta.json`：

```json
{
  "base_token": "xxx",
  "table_id": "xxx",
  "base_url": "https://my.feishu.cn/base/xxx"
}
```

## 故障排查

- **config not found**: 运行 `setup.sh` 完成初始化
- **lark-cli 权限不足**: 运行 `lark-cli auth login` 重新授权
- **字段写入失败**: 检查 `bitable-meta.json` 中的 base_token 和 table_id 是否正确
