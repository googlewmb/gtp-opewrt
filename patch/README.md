# 补丁脚本目录

所有构建补丁统一放在此目录；编号表示阶段，不能用通配符一次执行全部脚本。

| 文件 | 用途 | 执行时机 |
| --- | --- | --- |
| `10-feeds.sh` | 插件来源与 feeds 安装 | 写入初始配置之后 |
| `20-packages.py` | Ninja、SmartDNS 构建兼容修复 | feeds 安装之后 |
| `21-daed.py`、`daed-lock.py` | DAED 构建规则及锁文件 | feeds 安装之后 |
| `30-sonic.py` | SONiC 全锥形 NAT 全套补丁 | SONiC 源码下载之后 |
| `40-defaults.sh` | 连接跟踪、BBR/FQ、无线默认设置 | 最终配置之前 |
| `50-config.py` | H68K 目标、中文包和配置检查 | 下载源码后及 defconfig 前后 |
| `60-bbr3.sh` | BBRv3 内核适配入口 | 主机工具和交叉工具链完成之后 |
| `openwrt-bbr3.py`、`bbr.py` | BBRv3 候选选择、补丁生成和编译验证 | 由 60-bbr3.sh 调用 |
| `bbr3-check.sh` | 固件内的运行配置检查 | 刷机启动后运行 bbr3-check |
| `70-verify.py` | 内核与固件完整性检查 | 内核编译后、固件发布前 |
| `common.py`、`common.sh` | 公共函数 | 由对应脚本加载 |

所有编号入口均从 OpenWrt 源码根目录调用。详细执行顺序见 `.github/workflows/main.yml`。
BBRv3 用法及兼容边界见 [BBR3.md](BBR3.md)。回归测试单独放在 `tests/`。
