# Kindle 每日文学推荐

云端定时任务生成文章后发布到公开仓库，KOReader 从仓库下载完整文章。电脑关机不影响云端内容和 Kindle 的下载。

仓库：https://github.com/adrianfrin/kindle-daily-literature

## Kindle 用法

1. 启动 KOReader，连接 Wi-Fi。
2. 打开顶部工具菜单里的“每日文学推荐”；如位于更多工具中，继续展开。
3. 点“立即同步”，再点“打开推荐文件夹”。文章按日期命名，可以调整字号并离线阅读。

自动同步默认开启，只在已有 Wi-Fi 连接时工作。打开 KOReader、唤醒后联网，以及使用中的每半小时会检查更新；连续检查间隔至少 15 分钟。自动同步不主动开启 Wi-Fi。休眠或离线时，下次打开并联网后再下载。

文章保存在 `/mnt/us/documents/DailyLiterature/`。HTML 是 KOReader 支持的可重排格式；文件不包含 Kindle 登录凭证。下载使用 HTTPS，校验 Git blob SHA，并在完整写入临时文件后替换目标文件。失败时已下载文章保留。每次最多补下 5 篇，后续同步会继续补齐。

## 文件约定

- `articles/YYYY-MM-DD.html`：完整 UTF-8 日报，保留自然段。
- `manifest.json`：最近 60 篇的日期、标题、路径和 blob SHA。
- `daily-literature.koplugin/`：KOReader 下载插件。
- `cloud-publishing-instructions.txt`：追加到原云端任务的发布要求。

发布顺序为先文章、再目录。目录写入前必须读取最新 SHA，防止覆盖并发更新。只公开本次推荐正文和参考链接，不公开聊天历史或账户信息。

## 当前部署状态

第一篇文章及目录已发布。插件已完成本地 LuaJIT 与下载校验测试。设备安装和原云端定时任务追加发布步骤仍待完成；此状态不表示每日自动发布已经启用。
