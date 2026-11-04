# MacKit

自用的 Mac 菜单栏工具箱：截图、贴图、录屏、剪贴板……一块块积木慢慢加。
方案和进度见 [docs/方案.md](docs/方案.md)。

## 怎么编译

装了 Xcode 就用 Xcode 编译，没装就用命令行工具。两种方式的产物都是 build/MacKit.app。

```bash
scripts/test.sh                 # 全部检查：坐标单元测试 + 编译 + 应用自检
scripts/build.sh                # 只编译
scripts/install.sh              # 编译、装到 ~/Applications 并启动
scripts/install.sh --no-open    # 只装不启动
scripts/smoke-record.sh         # 录屏实录检查：真的录几小段、拼接、转 GIF 再删掉（会短暂出现系统的录屏标志）
scripts/smoke-longshot.sh       # 长截图实录检查：真的拍屏幕左上角一小块 1.5 秒，看尺寸、量拼接速度（会短暂出现系统的录屏标志）
build/MacKit.app/Contents/MacOS/MacKit --style-preview 输出.png 标题 [左边一栏.png]   # 样张：把各个浮动条、按钮画进一张图（不弹窗口）
MACKIT_BUILDER=swiftc scripts/build.sh   # 装了 Xcode 也强制用命令行编译
```

Xcode 工程由 project.yml 生成。要改工程设置，改 project.yml，然后运行：

```bash
xcodegen generate
```

签名：默认是临时签名，每次重编都要重新给录屏权限。
把 Config/Local.xcconfig.example 复制成 Config/Local.xcconfig 并填上团队编号，
就会改用 Apple Development 证书。这个文件不进 git。

## 目录

```
MacKit/
  App/            程序入口、自检、样张
  Core/           公共积木：快捷键、设置、权限、提示条、菜单、截图记录、统一样子（Theme）
  Tools/
    Screenshot/   截图：冻屏、选区覆盖层、坐标换算、复制和保存
    Pin/          贴图：贴图窗口、缩放透明度、读剪贴板、文字卡片、贴图上标注
    Annotate/     标注：八种工具、工具栏、撤销重做、马赛克、导出
    Clipboard/    剪贴板历史：盯剪贴板、跳过密码、存盘、小窗口、自动粘贴
    Recorder/     录屏：选区域、控制条、倒计时、红框、录制小条、暂停拼接、定时、预览剪辑、GIF、点击高亮、按键显示、摄像头
    Recognize/    识别工具：识别文字和二维码、结果窗口、取色用的像素读取、测量
    LongShot/     长截图：边拍边拼的算法、控制条和预览条、自动滚动
    Misc/         杂项：系统状态（CPU、内存、网速、磁盘、电池）、防休眠、排窗口小抄
  Resources/      Info.plist
Config/           签名设置（Local.xcconfig 是本机私有的）
Tests/            坐标换算、贴图缩放、选区调整、剪贴板文字、录屏尺寸、按键显示、识别和测量、长截图拼接、系统状态文字的单元测试
scripts/          编译、测试、安装脚本
project.yml       Xcode 工程的生成规则
```

加新工具：在 `MacKit/Tools/` 下新建文件夹，写一个遵守 `ToolModule` 的类，
再加进 `AppDelegate` 的 `modules` 列表。

## 查日志

zsh 里 `log` 是另一个同名命令，要写完整路径：

```bash
/usr/bin/log show --last 10m --predicate 'subsystem == "local.mackit"'
```

## 截图权限一直不生效

系统可能留着旧签名的权限记录。只清 MacKit 自己的记录，然后重新授权：

```bash
tccutil reset ScreenCapture local.mackit.MacKit
```

## 设置存在哪

```bash
defaults read local.mackit.MacKit
```

## 剪贴板历史存在哪

```bash
open ~/Library/Application\ Support/MacKit/Clipboard
```

index.json 是列表，blobs/ 里是图片等大内容。只存在这台电脑上。

