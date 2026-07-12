# Agent Bell Qwen Voice Pack

这是 Agent Bell 的可选本地音色包。它使用官方 `qwen-tts==0.1.1` 和
`Qwen/Qwen3-TTS-12Hz-0.6B-Base`，把用户明确授权的参考音频转换为可复用的
voice clone prompt，并在本机提供 Agent Bell 所需的 HTTP 接口。

为保证可复现安装，官方模型固定到提交
`5d83992436eae1d760afd27aff78a71d676296fc`。显式使用官方 Hugging Face ID 时也使用
同一 revision；显式传入本地模型目录时，由调用者负责确认目录来源与版本。

Lite SAPI 模式不需要安装本目录中的任何内容。只有需要自定义音色时才安装 Voice Pack。

## 安全与隐私边界

- 安装必须显式传入 `-ConfirmVoiceRights`。只使用本人拥有或已经取得明确授权的音色。
- 参考音频和文字只会复制到用户指定的 `InstallRoot`，不会上传到模型下载端点。
- 安装阶段只从官方 PyPI、PyTorch CUDA 索引和 Qwen 的 Hugging Face 模型仓库下载依赖。
- 默认使用安装目录中的模型并启用 Hugging Face 离线模式。只有调用者显式传入官方
  Hugging Face ID 时，服务才可能继续从模型下载端点补齐模型文件。
- 服务地址固定为 `127.0.0.1:17863`，没有可配置的公网或局域网绑定参数。
- HTTP 请求日志已关闭，播报文本不会写入日志。
- 提前生成的 WAV 只保存在有界内存缓存中，不写入磁盘；服务停止后缓存自动清空。
- 本地其他进程仍然可以访问回环端口，因此 Voice Pack 以当前 Windows 用户会话为信任边界。

不要把 `InstallRoot`、参考音频、参考文字或生成缓存提交到开源仓库。

## 系统要求

- Windows 10 或更高版本
- Python 3.12，并且 `py -3.12` 可用
- 支持 CUDA 和 bfloat16 的 NVIDIA GPU 及可用驱动，通常为 Ampere 或更新架构
- 足够的磁盘空间用于隔离 Python 环境与官方模型

参考音频必须在 1–60 秒之间且不超过 50 MiB。较短、单人、无音乐、无混响，并带有
逐字准确台词的普通话样本通常更适合作为通知音色参考。

安装脚本不会修改系统 Python，也不会向系统 Python 安装任何包。所有依赖都进入
`InstallRoot\.venv`。

## 安装

在插件的 `voice-pack` 目录运行：

```powershell
.\install.ps1 `
  -ConfirmVoiceRights `
  -ReferenceAudio "D:\path\to\authorized-voice.wav" `
  -ReferenceText "参考音频中逐字对应的准确台词" `
  -VoiceId "default"
```

默认安装目录是 `%LOCALAPPDATA%\AgentBell\voice-pack`。可以显式放到空间更充足的位置：

```powershell
.\install.ps1 `
  -ConfirmVoiceRights `
  -InstallRoot "D:\AgentBell\voice-pack" `
  -ReferenceAudio "D:\path\to\authorized-voice.mp3" `
  -ReferenceText "参考音频中逐字对应的准确台词"
```

安装流程会：

1. 验证授权确认、参考文件和 Python 3.12。
2. 在 `InstallRoot\.venv` 创建隔离环境，并先从
   `https://download.pytorch.org/whl/cu128` 成对安装 `torch==2.11.0+cu128` 与
   `torchaudio==2.11.0+cu128`。
3. 从官方 PyPI 安装 `qwen-tts==0.1.1`，复用已经就绪的 CUDA PyTorch，然后执行
   `pip check` 与 CUDA 验证。
4. 在本地把参考音频规范化为 24 kHz、单声道、16-bit PCM WAV。
5. 把官方 Qwen3-TTS 0.6B Base 模型下载到 `InstallRoot\models`，把 Hugging Face
   缓存限制在 `InstallRoot\hf-home`。
6. 把私人参考资料保存在 `InstallRoot\voices\<voice_id>`。

重复安装到同一个带标记的目录会更新运行文件和指定音色。为避免误写用户数据，脚本拒绝
使用非空且没有 Voice Pack 标记的目录。

## 仅升级运行时

从早期 Agent Bell 升级时，不必重新复制参考音频或下载模型。先关闭正在运行的 Voice Pack，确认
`127.0.0.1:17863` 不再监听，然后从新版插件的 `voice-pack` 目录运行：

```powershell
.\update.ps1 -InstallRoot "D:\AgentBell\voice-pack"
```

默认安装目录可省略 `-InstallRoot`。更新器会拒绝任何已经占用该端口的进程，而不会擅自终止它；
它只更新 `app\server.py`、`app\start.ps1` 和 `app\requirements.txt`，不会修改 `.venv`、`models`
或 `voices`。新运行时通过语法检查后才替换，随后隐藏启动并验证 `/health` 中的协议版本和
`synthesize/prewarm/cached` 能力。更新失败时会尝试恢复并重新启动旧运行时。

## 启动

安装结束会返回前台和隐藏启动命令。默认前台启动，便于首次确认模型能正常加载：

```powershell
& "$env:LOCALAPPDATA\AgentBell\voice-pack\app\start.ps1"
```

使用自定义目录时：

```powershell
& "D:\AgentBell\voice-pack\app\start.ps1" -InstallRoot "D:\AgentBell\voice-pack"
```

确认无误后，可以由调用者选择隐藏启动：

```powershell
& "D:\AgentBell\voice-pack\app\start.ps1" `
  -InstallRoot "D:\AgentBell\voice-pack" `
  -Hidden
```

`-Hidden` 会等待 `/health` 就绪后再返回成功，默认最多等待 90 秒；模型、CUDA 或端口有问题时会直接报错，而不是误报已经启动。

默认从 `InstallRoot\models\Qwen3-TTS-12Hz-0.6B-Base` 加载。服务也接受官方
Hugging Face ID 或一个已有的本地模型目录：

```powershell
& "D:\AgentBell\voice-pack\app\start.ps1" `
  -InstallRoot "D:\AgentBell\voice-pack" `
  -Model "Qwen/Qwen3-TTS-12Hz-0.6B-Base"
```

脚本不会自行创建开机启动项或计划任务。模型会在服务进程中保持常驻，每个本地音色的
参考 prompt 会在启动时生成一次并缓存在内存中。新增或替换参考音频后需要重启服务。

## 健康检查

服务完成模型与参考 prompt 加载后，下面的请求返回 `status: ready`：

```powershell
Invoke-RestMethod -Uri "http://127.0.0.1:17863/health"
```

响应不会返回参考音频、参考台词或本地路径。

低延迟版本还会返回非私密的 `protocol_version` 和 `capabilities`，供 Agent Bell Doctor 判断
Voice Pack 是否支持预生成与缓存播放。

## 合成与预生成接口

`POST /synthesize` 只接收两个 JSON 字段：

```json
{
  "text": "主人，Codex任务监听开发 任务已完成，请回来查看了。",
  "voice_id": "default"
}
```

成功响应的 `Content-Type` 是 `audio/wav`。PowerShell 测试示例：

```powershell
$json = @{
  text = "主人，Codex任务监听开发 任务已完成，请回来查看了。"
  voice_id = "default"
} | ConvertTo-Json -Compress
$body = [System.Text.Encoding]::UTF8.GetBytes($json)

Invoke-WebRequest `
  -Uri "http://127.0.0.1:17863/synthesize" `
  -Method Post `
  -ContentType "application/json; charset=utf-8" `
  -Body $body `
  -OutFile ".\voice-pack-test.wav"
```

低延迟完成提醒还使用两个具有相同请求体的端点：

- `POST /prewarm`：校验请求后立即返回 `202`，由单个后台生成队列准备 WAV。相同文本与音色的重复请求会合并。
- `POST /cached`：命中时立即返回 `audio/wav`；未命中或仍在生成时立即返回 `404 cache_miss`，绝不触发现场生成。

缓存按音色和完整文本的哈希键控，最多保留有限条目与有限字节，并按 TTL 淘汰。HTTP 响应、健康检查和日志都不会公开文本、哈希键或音频内容。

接口限制：

| 项目 | 限制 |
| --- | --- |
| JSON 请求体 | 最大 16 KiB |
| text | 最大 300 个字符、UTF-8 最大 2 KiB |
| voice_id | 1–64 个 ASCII 字母、数字、点、下划线或连字符 |
| 本地音色 | 单个服务进程最多加载 16 个 |
| 并发推理 | 单 GPU 槽位；繁忙时返回 HTTP 503 |
| WAV 响应 | 最大 25 MiB |
| 预生成缓存 | 有界、仅内存、服务停止即清空 |

## 连接 Agent Bell

Voice Pack 通过健康检查和合成测试后，再把 Agent Bell 数据目录中的 `config.json` 改为：

```json
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
```

保留 `fallback_provider: sapi`。权限和失败事件在服务尚未启动、忙碌、超时或返回无效 WAV 时，
仍可回退到 Windows 系统语音。完成事件只读取预生成缓存；缓存未就绪时会立即响一次 Windows
提示音，不会再等待 17 秒现场生成，也不会稍后补播。

### Windows 实测参考

在 RTX 4060 Ti 8 GB、Python 3.12、PyTorch 2.11.0+cu128 上，7.6 秒测试播报的
冷启动模型加载约 20.9 秒、参考 prompt 约 3.9 秒、生成约 22.8 秒，PyTorch 峰值分配
显存约 2.3 GB。该数据只用于估算，不是不同显卡上的性能承诺。默认 HTTP 超时为 30 秒，
以限制权限和失败播报的异常长生成；完成播报通过任务期间预生成避免这段等待。较慢显卡可以按需提高到最多 300 秒。

## 私人音色目录

安装后的布局如下：

```text
<InstallRoot>/
  .venv/
  app/
  hf-home/
  models/Qwen3-TTS-12Hz-0.6B-Base/
  voices/
    default/
      reference.wav
      reference.txt
```

安装器接受 `.wav`、`.mp3`、`.flac` 或 `.ogg`，并统一保存为 `reference.wav`。
重新安装同一 `voice_id` 时会先在临时目录完成音频校验和转换，再替换旧音色；准备失败时旧音色保持不变。
手动增加音色时，每个音色目录也必须恰好有一个 `reference.<ext>`，并配有逐字准确的
UTF-8 `reference.txt`。建议同样使用 24 kHz 单声道 WAV。
