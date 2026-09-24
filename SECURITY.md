# Security / 安全

Whirlpool runs as the current user and requires no administrator privileges. It does not store brokerage credentials, place orders, or expose a network control service. Live quote requests use HTTPS. Local settings are not uploaded.

On macOS, the control socket lives in the per-user temporary directory, which other accounts can neither enter nor pre-create files in; it uses owner-only permissions, and both the app and the CLI reject peers running as another user. The optional `--on-click` CLI feature intentionally executes a local shell command; only supply trusted commands. On Windows, settings live under the current user's application-data directory; the app uses a per-session single-instance mutex.

Please report a security issue privately through the repository's Security Advisory feature if the maintainer has enabled it. Otherwise open an issue requesting a private contact without including exploitation details, personal data, or secrets. Do not post private watchlists or credentials in public issues.

中文：应用不需要管理员权限，不保存券商凭据或执行交易。macOS 控制 socket 位于每用户私有的临时目录，应用与 CLI 都校验对端属于同一用户；`--on-click` 会执行本地命令。报告安全问题时请勿公开个人信息、凭据或完整利用细节。
