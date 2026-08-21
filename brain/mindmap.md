---
slug: mindmap
title: Feature mindmap
role: feature mindmap
updated: "2026-08-21T06:38:38"
---

# Feature mindmap

```mermaid
mindmap
  root((libssh2-swift))
    SSH Session
      Socket Connection
      Banner & Cipher Negotiation
      Agent & Key Authentication
    SFTP Subsystem
      Async File Read/Write
      Directory Listing & Stat
      File Attributes & Permissions
    Crypto Engine
      AWS-LC (BoringSSL Fork)
      Modern Ciphers (ChaCha20, Ed25519)
```
