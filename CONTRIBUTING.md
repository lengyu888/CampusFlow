# CampusFlow 协作开发流程

感谢参与 CampusFlow 开发。仓库的 `main` 分支已启用保护，协作者不能直接向
`main` 推送代码。所有更改必须在独立分支完成，通过 Pull Request（PR）审查后合并。

## 1. 首次准备

确认已安装 Git，并接受仓库协作者邀请。首次克隆：

```powershell
git clone https://github.com/lengyu888/CampusFlow.git
cd CampusFlow
git switch main
git pull --ff-only origin main
```

开发前按照 [README](README.md) 完成后端与 ArkUI-X 客户端环境配置。

## 2. 从最新 main 创建工作分支

不要直接在 `main` 上修改。每项任务使用一个短期分支：

```powershell
git switch main
git pull --ff-only origin main
git switch -c feature/short-description
```

分支命名建议：

- `feature/...`：新功能
- `fix/...`：问题修复
- `docs/...`：文档调整
- `test/...`：测试补充
- `refactor/...`：不改变外部行为的重构

使用简短的英文小写名称和连字符，例如：

```text
feature/calendar-reminder
fix/agent-hduhelp-context
docs/setup-guide
```

## 3. 开发与提交

只修改当前任务需要的文件，不提交本机配置、密钥或生成物。特别禁止提交：

- DeepSeek API Key、HDUHelp PAT、订阅 token
- `.env`、SQLite 数据库、本机生成的加密密钥
- `local.properties` 中的个人 SDK 路径
- `.venv/`、`oh_modules/`、构建目录、录屏和调试输出

提交前查看变更：

```powershell
git status
git diff
```

按逻辑拆分提交，并使用清晰的提交信息：

```powershell
git add <本次修改的文件>
git commit -m "feat(agent): add weekly planning tool"
```

推荐的提交类型包括 `feat`、`fix`、`docs`、`test`、`refactor` 和 `chore`。

## 4. 提交前测试

后端变更至少运行：

```powershell
cd agent-service
.\.venv\Scripts\Activate.ps1
python -m pytest -q
cd ..
```

ArkUI-X 客户端变更至少运行：

```powershell
cd arkui-x-client
npm run fix:deveco
npm run check
npm run build:hap
cd ..
```

涉及客户端交互、Agent Tool Calling 或 HDUHelp 数据的变更，还应在 Phone 模拟器完成对应
流程测试。PR 中需要写明已执行的测试以及尚未覆盖的部分。

## 5. 推送前同步 main

在首次推送和更新 PR 前，将远程 `main` 的最新变更整理到当前分支：

```powershell
git fetch origin
git rebase origin/main
```

如果发生冲突，修改冲突文件后继续：

```powershell
git add <已解决的文件>
git rebase --continue
```

不要使用 `git reset --hard` 或强制覆盖他人的工作。已经推送过且经过 rebase 的个人分支，
如确实需要更新远程，请只对自己的分支使用：

```powershell
git push --force-with-lease
```

禁止对 `main` 使用强制推送。

## 6. 推送工作分支

首次推送：

```powershell
git push -u origin feature/short-description
```

后续更新：

```powershell
git push
```

如果收到 `main` 分支受保护的提示，说明推送目标错误；切换到工作分支后重新推送，不要尝试
绕过保护规则。

## 7. 创建 Pull Request

推送成功后，在 GitHub 仓库页面点击 **Compare & pull request**，确保：

- Base 分支：`main`
- Compare 分支：自己的工作分支
- 标题能概括变更，例如 `feat(agent): 支持一周智能规划`
- 描述包含变更内容、测试结果、界面截图及已知限制

也可以使用 GitHub CLI：

```powershell
gh pr create --base main --head feature/short-description `
  --title "feat(agent): add weekly planning" `
  --body "说明变更内容、测试结果和已知限制"
```

推荐的 PR 描述：

```markdown
## 变更内容
- 

## 测试
- [ ] 后端单元测试通过
- [ ] ArkUI-X 静态检查/构建通过
- [ ] Phone 模拟器流程通过

## 截图或录屏

## 已知限制
- 无
```

## 8. 审查与合并规则

当前 `main` 保护规则要求：

- 协作者的 PR 必须获得仓库拥有者 `@lengyu888` 的批准
- 最后一次推送者不能批准自己的 PR
- 所有审查对话必须解决
- PR 新增提交后，旧批准会失效，需要重新审查
- 禁止强制推送或删除 `main`

仓库拥有者可以直接向 `main` 推送，并可在必要时以管理员身份合并自己创建的 PR；该绕过
权限不授予普通协作者。

收到修改意见后，在原工作分支继续修改并正常 `git push`，PR 会自动更新；不要为同一任务
重复创建 PR。审查通过后，由仓库维护者在 GitHub 合并。

## 9. 合并后的本地清理

PR 合并后同步本地 `main` 并删除已完成分支：

```powershell
git switch main
git pull --ff-only origin main
git branch -d feature/short-description
git push origin --delete feature/short-description
```

远程分支已经由 GitHub 自动删除时，最后一条命令可以省略。

## 完整命令示例

```powershell
git switch main
git pull --ff-only origin main
git switch -c fix/agent-hduhelp-context

# 修改代码并运行测试
git status
git add agent-service/src agent-service/tests
git commit -m "fix(agent): expose synced HDUHelp context"

git fetch origin
git rebase origin/main
git push -u origin fix/agent-hduhelp-context

gh pr create --base main --head fix/agent-hduhelp-context `
  --title "fix(agent): 修复 HDUHelp 上下文读取" `
  --body "已补充测试并完成 Phone 模拟器验证。"
```

