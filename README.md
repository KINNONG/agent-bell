# Agent Bell

[![test](https://github.com/KINNONG/agent-bell/actions/workflows/test.yml/badge.svg)](https://github.com/KINNONG/agent-bell/actions/workflows/test.yml)

Agent Bell 是一个 Windows 优先、仅面向 Codex 的本地语音提醒插件。你可以在 Codex 执行较长任务时离开电脑；当这一轮执行结束、需要授权，或明确遇到问题时，Agent Bell 会用会话名称提醒你回来。

> v0.1 范围：Windows、Codex、Windows SAPI Lite 模式，以及可选的实验性本地 Qwen Voice Pack。Claude Code、macOS、Linux、手机推送和托盘 App 均不在本版范围内。

Agent Bell 是非官方开源项目，与 OpenAI 没有隶属或背书关系。

## 它会提醒什么

| 状态 | 判断来源 | 默认行为 |
| --- | --- | --- |
| 完成 | Codex 的 Stop Hook | 默认每次语音播报 |
| 等待确认 | Codex 的 PermissionRequest Hook | 立即语音播报 |
| 执行遇到问题 | Stop 中最后一条助手消息出现明确失败措辞 | 保守推断后立即语音播报 |

UserPromptSubmit Hook 只记录当前回合的开始时间，不会播报，也不会保存用户提示词。启用本地 Voice Pack 时，它还会在思考开始时启动独立后台预生成，不阻塞 Codex 或主通知队列。

Codex 每日自动化运行默认保持静音，包括完成、失败和等待确认；Agent Bell 根据本地 rollout 的 `thread_source=automation` 判断，不依赖会话名称。手动打开或继续的普通会话仍正常提醒。

默认中文话术：

- 完成：主人，{title} 任务已完成，请回来查看了。
- 等待确认：主人，{title} 正在等待您的确认，请回来处理。
- 遇到问题：主人，{title} 执行遇到问题，请回来查看。

### 关于“任务已完成”

Stop 表示 Codex 的一个回合已经停止，并不等于整个项目在语义上已经成功完成。默认完成话术可以在配置中修改。

Codex 当前没有单独的失败 Hook。Agent Bell 只在最后一条助手消息包含明确、未解决的失败措辞时标记为失败；模糊问题、早先失败但最终修复等情况不会被主动判成失败。这是一项保守推断，不是执行结果审计。

## 工作方式

~~~text
Codex Hook
  -> 清洗并写入最小事件文件
  -> 立即返回，不等待语音
  -> 隐藏的一次性 worker 排队处理
  -> 解析最新会话名并应用去重与播报策略
  -> 思考开始时立即尝试预生成自定义语音
  -> Windows SAPI 或本地 HTTP Voice Pack
  -> 自定义语音缓存未就绪时使用配置的 SAPI 兜底
~~~

插件文件是只读代码。为了让安装脚本与 Hook 始终读取同一份设置，配置、队列、状态、日志和缓存统一位于 `%LOCALAPPDATA%\AgentBell`。可选 Voice Pack 的私人参考音频也应保存在该数据目录，而不是插件源码中。高级用户可以通过 `AGENT_BELL_DATA` 显式覆盖位置。

## 系统要求

- Windows
- 支持 Plugins 与 Hooks 的 Codex
- Windows PowerShell 5.1
- 可用的音频输出设备
- Lite 模式需要至少一个已安装的 Windows SAPI 语音

Lite 模式不需要 Python、GPU、模型文件或 API Key。

## 一句话让 Codex 安装

把下面这句话发给 Codex：

~~~text
请以 Lite 模式安装 https://github.com/KINNONG/agent-bell 的 v0.1.7：先审计仓库，再运行 codex plugin marketplace add KINNONG/agent-bell --ref v0.1.7 和 codex plugin add agent-bell@agent-bell；只安装基础插件，不安装 Qwen Voice Pack、不下载任何模型；让我确认必要的 Plugins 安装提示，定位已安装的插件目录，依次运行 Initialize、Test 和 Doctor；保留我现有的 notify 与其他 hooks，不要绕过 /hooks 的信任确认。
~~~

安装过程中有两次必要确认：

1. 在 Codex 的 Plugins 界面确认安装或启用 Agent Bell。
2. 打开 /hooks，检查 Agent Bell 的命令内容，并信任该 Hook。

这是 Codex 的正常安全边界。安装插件不会自动信任其中的 Hook，Agent Bell 也不会写入信任哈希或绕过确认。

## 初始化与自检

下面的命令以已安装插件根目录为例：

~~~powershell
$pluginRoot = "<已安装的 agent-bell 插件根目录>"
$setup = Join-Path $pluginRoot "scripts\setup.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action Initialize
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action Test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action Doctor
~~~

- Initialize：创建或补全本地数据目录和默认配置。
- Test：进行一次真实测试播报。
- Doctor：检查 Windows 环境、插件文件、Hook 定义、运行配置和用户 hooks.json。

在文档检查或 CI 中，可给 Test 加上 -DryRun，避免真实播放声音：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action Test -DryRun
~~~

需要机器可读的诊断结果时，加上 -AsJson。

## Lite SAPI 模式

Lite 是公开 v0.1 的默认模式：

- 全程本地运行。
- 优先选择配置中的 SAPI 音色。
- 指定音色不存在时，尝试其他 zh-CN 音色，再回退到 Windows 默认音色。
- 不下载模型，不上传会话名称，也不调用外部 API。

默认配置位于 [config.example.json](plugins/agent-bell/config.example.json)。Initialize 会在数据目录创建实际的 config.json。

常用配置项：

| 字段 | 默认值 | 作用 |
| --- | --- | --- |
| mode | always | 完成提醒策略 |
| duration_threshold_seconds | 60 | 达到该运行时长后语音播报 |
| idle_threshold_seconds | 45 | Windows 空闲达到该时长后语音播报 |
| stop_debounce_seconds | 5 | 等待其他 Hook 继续任务的防误报窗口 |
| max_title_characters | 60 | 播报标题的最大字符数 |
| voice.sapi_voice | Microsoft Huihui Desktop | 优先 SAPI 音色 |
| voice.rate | 0 | SAPI 语速，范围 -10 到 10 |
| voice.volume | 100 | SAPI 音量，范围 0 到 100 |
| voice.http.timeout_seconds | 30 | 本地音色超时后回退到 SAPI |
| notifications.automation_runs | none | 自动化运行保持静音；normal 恢复普通提醒 |

## 播报策略

默认 `always` 会语音播报每一个 Complete。需要减少短回合打扰时，可以把 `mode` 改为 `smart`，其规则如下：

- Permission 和保守推断的 failure 始终立即语音播报。
- Complete 在回合运行至少 60 秒时语音播报。
- Complete 在 Windows 已空闲至少 45 秒时语音播报。
- 两项都未达到时，只显示 Windows 通知，避免短回合连续打断用户。

`threshold` 模式只使用运行时长阈值。

## 可选本地 Qwen Voice Pack

仓库包含一个可选的实验性 [Qwen Voice Pack](plugins/agent-bell/voice-pack/README.md)。它使用本地 Qwen3-TTS 0.6B Base 模型，从用户明确授权的参考音频生成自定义音色，并实现下面的本地 HTTP 接口。模型、Python 环境和私人音频不会进入插件仓库。

这是独立于基础插件的大体积可选安装：预计下载 `5.5–6 GB`，安装后占用约 `7.8 GB`，新安装的目标磁盘必须至少有 `12 GiB`（约 `12.9 GB`）可用空间。最低硬件为 `16 GiB` 系统内存和 `6 GiB` NVIDIA 显存，推荐 `32 GiB` 系统内存和 `8 GiB` 显存，并需要 Python 3.12、CUDA、bfloat16 和计算能力 8.0 或更高版本。Lite 模式不需要其中任何条件，也不会下载模型。

Voice Pack 的模型会在服务就绪前完成加载，并在服务运行期间常驻显存。收到 UserPromptSubmit 后，后台进程会立即尝试读取真实会话名；名称已经可用时直接检查 CPU、内存与 GPU 余量并提交预生成，新会话名称尚未写入时会在 10 秒后重试一次。预生成启动前要求至少 1.5 GiB 可用系统内存，并继续执行 CPU、显存和 GPU 忙碌保护；首次资源不足时，只要任务仍在运行，还会在约 15、45 和 75 秒时有限重试，等待期间不会占用预生成活动槽。等待 helper 最多 4 个，资源探测与提交最多同时 2 个，超过上限的并行任务会跳过本次预生成。四次都未通过时，完成事件不会现场等待合成、稍后补播或播放 Windows 提示音；若 `fallback_provider` 为 `sapi`，完成时改用系统语音播报，设为 `none` 才保持静默。生成进程使用较低优先级且队列有界，但仍可能与剪辑、游戏或其他本地 AI 任务争用 GPU；16 GiB 最低配置仍可能发生分页，推荐 32 GiB。权限和失败播报仍使用按需合成，默认最多等待 30 秒后回退到 SAPI。

### 一句话让 Codex 安装自定义音色

仅在确实需要自定义音色时，把下面这句话中的两个占位符替换为自己的授权资料，再发给 Codex：

~~~text
请为 Agent Bell v0.1.7 安装可选的本地 Qwen 自定义音色。开始任何下载或写入前，先向我明确展示并说明：预计下载 5.5–6 GB、安装后占用约 7.8 GB、新安装的目标磁盘必须至少有 12 GiB（约 12.9 GB）可用空间；最低硬件为 16 GiB 系统内存和 6 GiB NVIDIA 显存，推荐 32 GiB 系统内存和 8 GiB 显存。等我明确同意大体积下载后才能继续并传入 -ConfirmLargeDownload。参考音频使用 "<本人拥有或已取得明确授权的音频绝对路径>"，逐字准确台词是 "<与参考音频完全一致的准确台词>"；同时让我确认音色权利后再传入 -ConfirmVoiceRights。请提醒我：参考路径和台词会保留在当前 Codex 会话及工具调用记录中；不要把它们提交到仓库或写入 Agent Bell 日志。请定位并运行已安装插件的 voice-pack\install.ps1，让安装器先完成只读硬件与容量预检，只有通过后才把 provider 改为 http，再运行 Agent Bell Test 和 Doctor；资源不足时不要绕过安全门槛，并保留 `fallback_provider: sapi`，让完成、权限和失败事件在自定义音色不可用时仍有系统语音兜底。
~~~

当前 v0.1.7 安装器使用固定 revision 的官方 Hugging Face 模型仓库。中国大陆网络访问 Hugging Face 可能较慢；Qwen 官方虽然为大陆用户提供 ModelScope 下载方式，但本版安装器还没有 ModelScope 切换参数。遇到下载条件不佳时应先使用无需模型的 Lite 模式，不要擅自改用未经校验的第三方镜像；后续版本可以增加经过校验的镜像源支持。

服务要求：

- 只监听回环地址，不暴露到局域网或公网；客户端会拒绝非回环地址和 HTTP 重定向。
- `/synthesize` 接收包含 `text` 与 `voice_id` 的 POST JSON，并按需返回 `audio/wav`。
- `/prewarm` 立即接受后台预生成请求；`/cached` 只返回已经准备好的 WAV，不会现场生成。
- 预生成音频使用有界的内存缓存，服务停止后自动清空，不保存到磁盘。

配置示例：

~~~json
{
  "voice": {
    "provider": "http",
    "fallback_provider": "sapi",
    "http": {
      "endpoint": "http://127.0.0.1:17863/synthesize",
      "timeout_seconds": 30,
      "voice_id": "default"
    }
  }
}
~~~

### 从旧版 Voice Pack 升级

`v0.1.3` 引入了 `/prewarm` 与 `/cached` 低延迟播报，`v0.1.4` 进一步限制后台资源占用，`v0.1.5` 改为思考开始时立即尝试预生成，`v0.1.6` 为 16 GiB 机器调整内存门槛并增加有限资源重试，`v0.1.7` 在缓存未命中时执行配置的 SAPI 兜底。从 `v0.1.5` 或 `v0.1.6` 升级到 `v0.1.7` 不需要再次更新 Voice Pack 运行时；从更早版本升级的用户仍需按下面步骤更新一次。

先关闭当前 Voice Pack，确认 `127.0.0.1:17863` 已不再监听，然后从已安装插件根目录运行：

~~~powershell
$updater = Join-Path $pluginRoot "voice-pack\update.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -InstallRoot "D:\AgentBell\voice-pack"
~~~

使用默认安装目录时可以省略 `-InstallRoot`。更新器不会终止任何预先存在的进程；它只替换 `server.py`、`start.ps1` 和 `requirements.txt`，不接触 `.venv`、模型或私人音色。更新完成后会隐藏启动服务并验证低延迟协议；若更新失败，会尝试恢复并重启旧运行时。

完成播报仍只读取预生成缓存，不会现场生成、延迟补播或播放 Windows 提示音；缓存未命中或服务不可用时会按 `fallback_provider` 使用 SAPI，设为 `none` 可保持静默。权限或失败播报遇到服务不可用、超时或无效 WAV 时也会执行相同兜底。只有在 Voice Pack 已单独安装并通过测试后，才把 provider 改为 http。

只使用本人拥有或已取得明确授权的参考音频。Agent Bell 不提供公共音色库，也不会在本地模式中主动上传参考音频。

## 隐私

- Lite 模式不需要联网。
- 事件队列只保存处理所需的最小本地元数据，不保存提示词、转录、工具参数或完整助手回答。
- Stop 的最后一条助手消息只在内存中用于保守失败分类，不写入事件队列。
- 运行日志默认不记录会话名称和 session ID。
- 会话名称只在本机解析和播报。启用 HTTP provider 时，最终播报文本会发送到你配置的本地端点；Voice Pack 预生成缓存只存在于内存中。
- 若会话名可能包含敏感信息，可从 templates 中移除 {title}。
- 安装和卸载不会修改 Codex 的 notify 配置，也不会覆盖无关 Hook。

更多安全边界见 [SECURITY.md](SECURITY.md)。

## 测试

运行全部 Pester 测试：

~~~powershell
Invoke-Pester .\tests
~~~

对现有兼容入口进行无声 Dry Run：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex-voice-notifier.ps1 -TestSessionId "00000000-0000-0000-0000-000000000001" -TestTurnId "readme-dry-run" -DryRun
~~~

测试覆盖标题清洗、三种话术、smart 边界、保守失败分类、隐私日志、状态裁剪、队列去重、非阻塞 Hook、完成语音预生成，以及 Voice Pack 的 localhost HTTP 缓存合同。

## Doctor

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action Doctor
~~~

Doctor 用于确认 Windows 环境、必要插件文件、三个 Hook 事件、运行配置和用户 hooks.json 是否有效。使用 HTTP Voice Pack 时，它还会通过无重定向、限长、两秒总超时的本地健康检查验证低延迟协议。它不会探测 Hook 信任状态，而会返回打开 /hooks 检查的提示。反馈问题前，可加 -AsJson 获取结构化结果；分享结果前仍应检查并移除私人路径。音频链路应使用 Test 验证。

## 卸载

正式 marketplace 安装：

1. 在 Codex Plugins 中禁用或卸载 Agent Bell。
2. 确认 /hooks 中不再加载 Agent Bell Hook。
3. 本地数据默认保留，方便以后重装；需要清理时，先通过 Doctor 确认数据目录。

源码开发接入只供贡献者使用：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action EnableLocalDevelopment
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Action UninstallLocalDevelopment
~~~

UninstallLocalDevelopment 默认保留本地数据。确认不再需要配置、缓存和私人音频后，可以明确追加 -PurgeData。

正式 marketplace 安装不要运行 EnableLocalDevelopment。源码卸载只移除 Agent Bell 自己合并的 Hook，不删除整个 ~/.codex/hooks.json，不修改 config.toml 或 notify，也不会写入 Hook 信任状态。

## 已知限制

- v0.1 仅支持 Windows 与 Codex。
- Stop 是回合级事件，不是可靠的项目完成信号。
- 多个 Stop Hook 若在 5 秒防误报窗口之后才决定继续任务，仍可能提前播报；可把 `stop_debounce_seconds` 调高到最多 120 秒。
- failure 是对明确失败措辞的保守推断。
- 会话标题来自 Codex 本地状态；读取失败时使用安全回退名称。
- 自定义音色依赖单独安装并验证的实验性 Qwen localhost 服务，并需要兼容的 NVIDIA GPU。
- 新会话名称尚未写入 Codex 本地状态时会在 10 秒后重试一次；资源门槛首次未通过时会在任务仍运行的前提下再试三次。任务短于生成时间、标题后来改变或四次资源检查都未通过时，自定义音色可能无法就绪，此时按 `fallback_provider` 回退。
- Agent Bell 不是任务结果验证器，也不替代测试、日志或人工验收。

## 许可证

Agent Bell 使用 [MIT License](LICENSE)。第三方组件说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
