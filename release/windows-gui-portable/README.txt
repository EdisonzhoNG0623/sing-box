sing-box SFW 1.14.0-beta.15 Windows x64 便携免管理员版
=======================================================

这是什么
--------
- 图形界面来自 SagerNet 官方 SFW-1.14.0-beta.15-x64.exe。
- 本包是非官方派生便携补丁，不是官方原样发布的安装包。
- 初始包不含配置、订阅、节点、密钥、认证信息或设置数据库。

使用方法
--------
1. 把整个文件夹解压到当前用户可写的目录，例如桌面或 D:\Tools。
2. 双击 start.cmd；不要直接双击 sing-box.exe。
3. 在官方 SFW 图形界面内导入你自己的配置。
4. 使用 mixed 入站和“系统代理”模式。

免管理员范围
------------
- 不安装 Windows 服务，不写 Program Files，不要求 UAC。
- TUN 已禁用，因为 Windows TUN/WinDivert 驱动本身需要管理员权限。
- 不遵循 Windows 系统代理的软件，需要自行设置 HTTP/SOCKS 代理。

便携数据
--------
- SFW 配置和设置保存在本目录 data\SFW。
- daemon 运行数据保存在本目录 data\daemon。
- 删除整个 data 文件夹即可重置；请先退出 SFW。
- 启动器退出时会恢复启动前的当前用户系统代理设置。

安全与来源
----------
- 官方安装器地址、原始 SHA-256、源码版本和修改说明见 SOURCE.txt。
- 为满足官方 worker 的同签名校验，派生包中的 sing-box.exe 与
  resources\daemon\sing-box-daemon.exe 使用同一张构建用自签名证书重新签名。
- daemon 从官方 beta.15 的精确源码版本重建，仅当显式监听 IP 本身是回环
  地址时回退到当前用户；启动器固定使用 127.0.0.1，不对局域网开放。
- 该证书不代表 SagerNet/Project S 官方签名，也不会被 Windows 默认信任。
