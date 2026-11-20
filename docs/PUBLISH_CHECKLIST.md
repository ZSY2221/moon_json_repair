# 发布与参赛核查清单

## 1. 核查本地版本

- [ ] 确认 `moon.mod` 的模块名、版本、许可证和仓库地址与准备发布的版本一致。示例使用 `ZSY2221/json_repair` 和 `ZSY2221/moon_json_repair`。如登记的账号或仓库名不同，先同步修改模块名、MoonBit 导入路径、README 和下列命令。
- [ ] 从仓库根目录完成检查、测试、文档生成和发布包预检。用支持原生 C 编译器的环境执行 `native` 命令。

  ```sh
  moon version
  moon fmt --check
  moon check --target js --deny-warn
  moon check --target wasm-gc --deny-warn
  moon check --target native --deny-warn
  moon test --target js
  moon test --target wasm-gc
  moon test --target native
  moon doc
  node web/build.mjs
  moon package --list
  ```

- [ ] 核对 `README.md` 的 API、CLI 与 Demo 步骤能从干净检出运行。打开 `web/index.html`，试跑六个案例，检查修复结果、位置日志和 Schema 通过或失败状态。
- [ ] 核对 `git status --short`、`git log --oneline` 和 `git remote -v`。将可复现的验证结果和实际开发记录留在公开仓库。

## 2. 推送 GitHub 并部署 Pages

1. 用 GitHub 账号创建公开仓库 `moon_json_repair`，以本地已有历史作为初始内容。以下命令适用于本地 `main` 和尚未配置的 `origin`。

   ```sh
   git remote add origin https://github.com/ZSY2221/moon_json_repair.git
   git push -u origin main
   ```

2. 打开仓库 **Settings → Pages → Build and deployment**，将 **Source** 设为 **GitHub Actions**。运行仓库的 Pages 工作流，或通过后续真实提交触发。工作流将 `web/` 上传为站点，`web/index.html` 是首页。部署完成后，从 **Settings → Pages** 打开实际站点地址。 [GitHub Pages 发布配置](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)
3. 用浏览器无痕窗口打开预期地址 `https://zsy2221.github.io/moon_json_repair/`，验证访问权限、静态资源加载和示例交互。将实际确认可访问的 URL 填入 README 或验收材料。

## 3. 发布到 Mooncakes

1. 打开 [mooncakes.io](https://mooncakes.io/) 确认账号命名空间。首次创建账号执行 `moon register`，已有账号执行 `moon login`，按提示完成身份验证。工具提示凭证写入 `~/.moon/credentials.json` 后即可继续。 [MoonBit 官方包发布教程](https://docs.moonbitlang.com/en/latest/toolchain/moon/package-manage-tour.html#setup-mooncakes-io-account)
2. 从模块根目录确认 SemVer 版本没有发布过，检查拟提交的文件，再验证权限和发布元数据。

   ```sh
   moon package --list
   moon publish --dry-run
   moon publish
   ```

3. 在 Mooncakes 搜索 `ZSY2221/json_repair`，核对版本、Apache-2.0 许可证、README 和源码链接。用一个独立 MoonBit 模块执行 `moon add ZSY2221/json_repair`，按 README 导入并运行最短样例。 [MoonBit 官方包发布教程](https://docs.moonbitlang.com/en/latest/toolchain/moon/package-manage-tour.html#publish-your-module)

## 4. 十一月赛申报

开赛页面、表单字段和项目申报书要求于 **2026-11-20**（UTC+8）核对。十一月赛的报名和验收日期由赛事官方通知公布。队伍最多三人，由队长统一提交队伍信息及全部队员 GitHub ID。所有队员加入赛事交流群，并将群昵称设为各自 GitHub ID。 [赛事官网](https://moonbitlang.github.io/Hackathon2026/) · [赛事章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)

1. 从赛事官网点击 **点击报名**，打开飞书 **2026 MoonBit 国产基础软件开源大赛-11月黑客松 项目申报**。用真实参赛者信息按表填写。身份证、联系方式、银行卡和学历证明仅通过赛事指定的表单提交。页面说明标注最多提交三次，并允许修改已提交内容。 [十一月赛官方申报表](https://bxup9uklfcb.feishu.cn/share/base/form/shrcnWUMlgpbwHaXgzV7HmNhNhg)

   | 字段 | 必填 | 本项目填写说明 |
   | --- | --- | --- |
   | 是否参加过MoonBit黑客松 | 是 | 按实际情况选「是」或「否」。选「是」可复用部分个人信息。 |
   | 参赛方向 | 是 | 选「新项目申报-参与季度评选」。表单另外提供新项目不参与季度评选及已有项目维护选项。 |
   | 姓名 | 是 | 填写真实姓名。 |
   | GitHub ID | 是 | 核对自己的 GitHub 用户名。团队填写全部队员的用户名。 |
   | 联系方式（邮箱） | 是 | 填写可收信邮箱，按表单提示使用国内邮箱。 |
   | 联系方式（电话） | 是 | 填写可联系的号码，表单提示优先填写能关联微信的号码。 |
   | 身份证照片 | 是 | 上传正反面，可加比赛用途水印。团队上传全部队员的照片。 |
   | 身份证号码 | 是 | 按表单格式填写，并核对号码。 |
   | 项目名称 | 是 | `moon_json_repair`。 |
   | 项目的GitHub仓库链接 | 是 | 填写实际公开仓库链接，如 `https://github.com/ZSY2221/moon_json_repair`。 |
   | 项目申报书 | 是 | 上传参赛者本人撰写的一页内 Markdown 文件，按下方核对。 |
   | 银行卡账号 | 是 | 单人填写纯号码。团队按表单示例逐一填写队员姓名和账号，用中文分号分隔。 |
   | 银行卡所属分行 | 是 | 填写银行及开户分行或支行全称。团队按表单示例分列对应队员。 |
   | 推荐人 | 否 | 有推荐人时填写其 GitHub ID，对方须已报名成功。已有项目维护方向填「无」。 |
   | 所属高校/组织 | 是 | 填写所在学校或组织全称，无所属机构填「无」。 |
   | 学信网认证报告 | 是 | 在读生上传教育部学籍在线验证报告，毕业人员上传学历相关认证材料。境外高校和其他情况按表单提交就读证明。团队上传全部队员的材料。 |
   | 《参赛诚信承诺书》 | 是 | 阅读条款后再按实际意愿选择同意。 |
   | 备注 | 否 | 填写需要组委会知晓的补充事项。 |
   | 你是通过什么渠道了解到本次比赛的？ | 否 | 按实际情况填写。 |

   [参赛诚信承诺书](https://bxup9uklfcb.feishu.cn/wiki/GKDswxuptiJRcxkzPgZcw1J6nAd) · [学信网](https://www.chsi.com.cn/)

2. **由参赛者亲自撰写项目申报书。** 表单要求一页内 Markdown，并明确要求本人写作。核对八项材料：项目名称、简介、方向及通用性、至少三个完整的预期使用场景、核心功能、原创或参考情况、移植项目的来源与许可证，以及公开 GitHub 仓库链接。此仓库链接需呈现至少 **10 个有效 commits**，每次提交应对应真实开发工作。仓库的五阶段里程碑与表单的有效提交数分别核对。 [官方申报表](https://bxup9uklfcb.feishu.cn/share/base/form/shrcnWUMlgpbwHaXgzV7HmNhNhg) · [申报书样本](https://bxup9uklfcb.feishu.cn/wiki/Rm3PwCxC7iEwJtkK1xMcYHZkn36)
3. 提交并保存回执，通过提交完成页进入赛事交流群。查阅群内的报名审核、当前验收截止时间和验收入口。如主办方要求修改，按对方给出的方式更新。正式报名时间以审核通过前最后一次有效提交或修改为准。 [赛事流程](https://moonbitlang.github.io/Hackathon2026/#process)

## 5. 月度验收与季度评选

- [ ] 确认公开仓库具备可追踪的实质性提交、Issues、PR 与更新记录，并附上 README、测试运行命令、在线 Demo 和可复现的演示步骤。记录验收用的 commit SHA 与测试结果。 [赛事验收标准](https://moonbitlang.github.io/Hackathon2026/#directions)
- [ ] 按十一月赛交流群的通知提交验收材料，保存审核结果。官网列出的月度项目支持为申报审核后 150 元启动支持、开发完成且通过验收后 350 元完成支持。季度奖池为 80,000 元，十一月属于第二赛季度（11 月至次年 1 月）。具体评审与发放以赛事章程和通知为准。 [官方奖励机制](https://moonbitlang.github.io/Hackathon2026/#awards)
