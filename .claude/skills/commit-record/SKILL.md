---
name: commit-record
version: 1.0.0
description: "将 git commit 信息自动记录到飞书多维表格。当用户需要记录 commit、追踪代码提交、初始化 commit 记录表时使用。"
---

# Commit Record

将 git commit 信息自动记录到飞书多维表格（Bitable），用于代码提交记录的追踪和分析。

## 前置条件

- `lark-cli` 已安装并完成认证（参考 `lark-shared` skill）
- `jq` 已安装
- 当前目录在一个 git 仓库内

## 首次使用流程

用户首次使用时，需要先初始化飞书多维表格：

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/skills/commit-record/setup.sh"
```

该脚本会：
1. 通过 `lark-cli base +base-create` 创建一个新的飞书多维表格
2. 创建 10 个字段（commit_hash, repository, branch, author, author_email, commit_time, commit_message, lines_added, lines_deleted, files_changed）
3. 将配置（base_token, table_id）保存到仓库根目录的 `.commit-record.json`

初始化完成后，提醒用户将 `.commit-record.json` 加入 `.gitignore`。

## 记录 commit

### 手动记录最近一次 commit

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/skills/commit-record/record-commit.sh"
```

### 记录指定 commit

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/skills/commit-record/record-commit.sh" <commit-hash>
```

### 自动记录（Hook）

项目的 `.claude/settings.json` 已配置 PostToolUse hook，在通过 Claude Code 执行 `git commit` 后会自动触发记录。

## 记录的字段

| 字段 | 类型 | 说明 |
|------|------|------|
| commit_hash | text | 完整 SHA 哈希 |
| repository | text | 仓库名 (owner/repo) |
| branch | text | 当前分支名 |
| author | text | 提交作者 |
| author_email | text | 作者邮箱 |
| commit_time | datetime | 提交时间 |
| commit_message | text | 提交信息 |
| lines_added | number | 新增行数 |
| lines_deleted | number | 删除行数 |
| files_changed | number | 修改文件数 |

## 配置文件

配置存储在仓库根目录的 `.commit-record.json`：

```json
{
  "base_token": "xxx",
  "table_id": "xxx",
  "base_url": "https://my.feishu.cn/base/xxx",
  "repo_name": "owner/repo"
}
```

## 故障排查

- **config not found**: 运行 `setup.sh` 完成初始化
- **lark-cli 权限不足**: 运行 `lark-cli auth login` 重新授权
- **字段写入失败**: 检查 `.commit-record.json` 中的 base_token 和 table_id 是否正确
