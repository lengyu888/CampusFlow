# 行简个人协作分支

从 2026-10-18 起，haohao 的后续修改统一保存在 `dev/haohao`。两个仓库各保留一个当前协作 PR，直接以各自的 `main` 为审查目标。功能、修复和验证记录在本分支持续更新，不再每阶段新建分支或依赖前一个阶段 PR。

## 本次收拢范围

- 学长仓库 `lengyu888/CampusFlow`：累计包含本人的 PR #2–#29。#2–#4 已由维护者合入 main，其余历史阶段的源码和提交保留在本分支祖先历史中。
- 个人仓库 `haohao6666666/CampusFlow-Personal`：累计包含本人的 PR #1–#20；更早阶段已存在于个人 main。
- 具体原提交号见 [PR 覆盖记录](evidence/collaboration-pr-coverage.json)。记录证明版本包含关系，不代表每个历史快照均已重新编译。
- 本次兼容修复在累计完整版本进行。旧阶段分支保留作历史，不向它们重复推送修复，不删除、重写他人的提交，不把历史未修复快照称为可交付版本。

## 日常协作

每位成员维护自己的一个工作分支，例如 `dev/<成员名>`，并向 main 发起一个当前 PR。不要向其他成员分支提交。具体流程：

1. 拉取远程信息，检查工作区与分支，再切换到自己的分支。第一次接手 haohao 完整版本时从远程 `dev/haohao` 创建本地跟踪分支，不从旧阶段分支挑一段代码拼接。
2. 在自己的分支按具体问题提交小 commit，每条写清行为变化与原因。新提交正常 push，已有 PR 会自动更新。
3. 同步 main 时，先审查差异，再将 main 合入自己的分支；处理冲突后验证。共享过的分支保持追加历史，不 rebase 后强推。
4. PR 描述保持一份当前汇总：累计功能、本次变更、实际测试、原生编译待验项。维护者审查通过后才合入 main。
5. PR 合并后仍保留个人分支。下一轮先同步 main，再使用同一分支开下一次 PR；GitHub 已合并的 PR 不能继续追加新一轮审查。不要为每个功能新建分支。

```sh
git fetch origin
git switch dev/haohao
git pull --ff-only origin dev/haohao
# 查看 main 新增内容后，在自己的分支同步。
git merge origin/main
# 修改、测试、按文件选择提交。
git add <本次修改的文件>
git commit -m "fix: 描述具体修复"
git push origin HEAD:dev/haohao
```

发生冲突时先解决并验证，不使用 `reset --hard`、`push --force` 或整目录覆盖来同步。不要删除 main 或其他成员的文件、分支。维护者若使用 squash 合并，下一轮应先检查历史和差异，不能盲目重推已合并的变更。

## 验证边界

`Cross-platform compatibility` 工作流在 Windows 和 Linux 上运行完整客户端逻辑测试、后端离线测试、配置预检与客户端/后端连续流程。它不安装 DevEco、原生 SDK 或模拟器，不调用真实云模型，不使用个人账号数据。

静态预检和逻辑测试不替代原生编译。鸿蒙正式构建交给学长现有 DevEco 6.1.1 / ArkUI-X API24 环境；Android、iOS 原生构建及设备验证仍按团队现有环境验收。交接必须带具体 commit 与完整结果，不能只说“测试全过”。

本次修复细节与实际验证结果见 [兼容修复说明](compatibility-repair.md)。
