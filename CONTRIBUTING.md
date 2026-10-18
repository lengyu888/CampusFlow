# CampusFlow 协作开发流程

感谢参与 CampusFlow 开发。仓库的 `main` 分支已启用保护，协作者不能直接向
`main` 推送代码。所有更改必须在独立分支完成，通过 Pull Request（PR）审查后合并。

自 2026-10-18 起，采用每人一个持续协作分支与一个当前 PR。haohao 的完整版本在
`dev/haohao`，累计功能、修复和验证记录见 [协作分支说明](docs/haohao-collaboration.md)。
原阶段分支保留历史，后续更新集中到个人协作分支，不向其他成员分支提交。

## 1. 首次准备

确认已安装 Git，并接受仓库协作者邀请。首次克隆：

```powershell
git clone https://github.com/lengyu888/CampusFlow.git
cd CampusFlow
git switch main
git pull --ff-only origin main
```

开发前按照 [README](README.md) 完成后端与 ArkUI-X 客户端环境配置。

## 2. 创建或继续自己的协作分支

不要直接在 `main` 上修改。每位成员首次从 main 创建自己的分支，后续持续使用同一分支：

```powershell
git switch main
git pull --ff-only origin main
git switch -c dev/your-name
```

已有个人分支时直接跟踪远程版本。haohao 的分支已包含全部累计功能，不要重新从 main 创建同名分支：

```text
git fetch origin
git switch dev/haohao
git pull --ff-only origin dev/haohao
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
npm test
npm run check
# 已有原生环境的队友继续执行；不要把前两项当成原生编译。
npm run build:hap
cd ..
```

涉及客户端交互、Agent Tool Calling 或 HDUHelp 数据的变更，还应在 Phone 模拟器完成对应
流程测试。PR 中需要写明已执行的测试以及尚未覆盖的部分。当前用户不安装原生环境，
原生编译及设备验证由已有环境的队友完成；缺少这部分证据时保留 Draft，不宣称原生通过。

## 5. 推送前同步 main

在首次推送和更新 PR 前，将远程 `main` 的最新变更整理到当前分支：

```powershell
git fetch origin
git merge origin/main
```

如果发生冲突，修改冲突文件后继续：

```powershell
git add <已解决的文件>
git merge --continue
```

不要使用 `git reset --hard` 或强制覆盖他人的工作。已共享的个人分支采用追加提交，
不通过 rebase 后强推改写审查历史。main 的原保护与审查规则保持有效。

## 6. 推送工作分支

首次推送：

```powershell
git push -u origin dev/your-name
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
gh pr create --base main --head dev/your-name `
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

## 9. 合并后继续使用个人分支

PR 合并后保留个人分支，先同步 main，再开始下一轮工作。已合并的 PR 不能继续追加审查，
下一轮仍用同一分支开一个新 PR，不按功能或阶段另建分支：

```powershell
git fetch origin
git switch dev/your-name
git merge origin/main
```

如果远程分支被自动删除，应先核对 main 和本地历史，再恢复自己的同名分支；不删除其他成员的分支。

## 完整命令示例

```powershell
git fetch origin
git switch dev/your-name
git pull --ff-only origin dev/your-name

# 修改代码并运行测试
git status
git add agent-service/src agent-service/tests
git commit -m "fix(agent): expose synced HDUHelp context"

git fetch origin
git merge origin/main
git push -u origin dev/your-name

gh pr create --base main --head dev/your-name `
  --title "fix(agent): 修复 HDUHelp 上下文读取" `
  --body "填写实际执行的检查结果与尚未验证的部分。"
```

