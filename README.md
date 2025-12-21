
---

# AnyTLS + Nginx 增强部署方案

本方案通过 Nginx 为 AnyTLS 提供合法的 TLS 证书伪装，在不损失 AnyTLS 核心功能的前提下，极大地提升了节点的隐蔽性与安全性。

## 🚀 快速安装

在终端执行以下命令开始安装：

```bash
wget https://raw.githubusercontent.com/markdemo666/anything/refs/heads/main/install_anytls.sh
bash install_anytls.sh

```

---

## 🛡️ 为什么选择 Nginx + AnyTLS？

使用 Nginx 并不会削弱 AnyTLS 的功能，反而是为其穿上了一层更完美的“伪装衣”。

### 1. 外层伪装（由 Nginx 负责）

* **合法证书：** 节点对外展示的是经过权威机构（如 Let's Encrypt）签发的合法证书，而非之前易被识别的自签名证书。
* **完美混淆：** 在防火墙或运营商看来，您的流量表现为正常的、安全的 **HTTPS (Port 443)** 访问。这显著降低了被主动探测和阻断的风险。

### 2. 内核协议（由 AnyTLS 负责）

* **透明转发：** Nginx 利用 `stream` 模块（第四层转发）充当传输管道。
* **完整保留：** 在完成 SSL 握手后，数据流会原封不动地传递给后端的 AnyTLS。AnyTLS 特有的协议逻辑、用户认证等核心功能完全由其自身处理。

---

## 💡 方案总结

| 特性 | 纯 AnyTLS 模式 | Nginx + AnyTLS 模式 (推荐) |
| --- | --- | --- |
| **证书可靠性** | 自签名证书（易被拦截） | **Let's Encrypt 权威证书** |
| **流量特征** | 较明显的加密特征 | **标准 HTTPS 网站流量** |
| **核心协议** | AnyTLS | AnyTLS (完全保留) |
| **安全性** | 基础加密 | **高强度伪装 + 核心加密** |

**结论：** 您现在拥有了 **Nginx 的合法证书伪装** + **AnyTLS 的核心传输能力**，这是目前最稳健的配置方式。

---
