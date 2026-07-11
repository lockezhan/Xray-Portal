#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
荷兰上传配置安全验证器
独立脚本运行，防范 shell 引号嵌套地狱
"""

import sys
import os
import stat
import yaml
import uuid

def main():
    if len(sys.argv) != 2:
        sys.stderr.write("Usage: {} <ready-file-path>\n".format(sys.argv[0]))
        sys.exit(1)

    MAX_BYTES = 1048576  # 1MB
    ready_file = sys.argv[1]
    
    # 支持在测试中通过 CLASH_SUB_TEST_BASE 重定向基础目录
    base_dir = os.environ.get("CLASH_SUB_TEST_BASE", "/opt/clash-sub")
    incoming_dir = os.path.join(base_dir, "incoming")
    sources_dir = os.path.join(base_dir, "sources")
    published_dir = os.path.join(base_dir, "published")

    # =============================================================================
    # 1. 物理检查 incoming、sources、published 所有权与权限模式 (固定模型校验)
    # =============================================================================
    paths_to_check = {
        base_dir: (0, 0, 0o755),                         # root:root 0755
        incoming_dir: (os.getuid(), os.getgid(), 0o700),  # subpush:subpush 0700
        sources_dir: (0, 0, 0o750),                      # root:root 0750
        published_dir: (0, 0, 0o755),                    # root:root 0755
    }

    is_test = "CLASH_SUB_TEST_BASE" in os.environ

    for path, (expected_uid, expected_gid, expected_mode) in paths_to_check.items():
        if not os.path.exists(path):
            sys.stderr.write("Error: Path does not exist: {}\n".format(path))
            sys.exit(1)
        
        st = os.stat(path)
        
        # 审计权限模式
        actual_mode = stat.S_IMODE(st.st_mode)
        if actual_mode != expected_mode:
            sys.stderr.write("Error: Security breach! Path {} has permission {:o}, expected {:o}.\n".format(
                path, actual_mode, expected_mode
            ))
            sys.exit(1)
            
        # 如果是在真实生产环境，执行严格的 UID / GID 归属审计
        if not is_test:
            if st.st_uid != expected_uid:
                sys.stderr.write("Error: Security breach! Path {} owned by UID {}, expected UID {}.\n".format(
                    path, st.st_uid, expected_uid
                ))
                sys.exit(1)

    # 2. 强力符号链接防范，检测到符号链接时立即拒绝，绝对不主动 unlink
    if os.path.exists(ready_file) and os.path.islink(ready_file):
        sys.stderr.write("Error: Symbolic link detected at target path! Rejected for security.\n")
        sys.exit(1)

    # 3. 限制流读取最大 1MB + 1 字节
    content = sys.stdin.read(MAX_BYTES + 1)
    if len(content) > MAX_BYTES:
        sys.stderr.write("Error: Upload payload exceeded maximum allowed limit of 1MB. Rejected.\n")
        sys.exit(1)

    # 4. 生成固定目录内的随机临时文件，防止命名碰撞与并发越权
    temp_path = os.path.join(incoming_dir, "nl-full.yaml.uploading.{}".format(uuid.uuid4().hex))

    temp_fd = None
    try:
        # 以 O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW 打开临时文件，保证排除符号链接、独占且全新
        temp_fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(temp_fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            # 强制将数据及元数据写入物理磁盘介质
            try:
                os.fsync(temp_fd)
            except OSError:
                pass
        temp_fd = None  # fdopen 已经接管并关闭了 fd

        # 5. YAML 结构与非空 proxies 检验
        data = yaml.safe_load(content)
        if not isinstance(data, dict):
            raise ValueError("Root element of YAML must be a dictionary.")
        if "proxies" not in data:
            raise ValueError("Missing required proxies field.")
        proxies = data["proxies"]
        if not isinstance(proxies, list) or len(proxies) == 0:
            raise ValueError("proxies field must be a non-empty list.")

        # 6. 验证完全通过后，原子替换已有的 ready_file，保障现有 ready_file 不被损坏
        if os.path.islink(ready_file):
            raise OSError("Symbolic link detected on target path during atomicity replacement.")
        
        os.replace(temp_path, ready_file)
        
        # 7. 对 incoming 目录元数据同步 fsync
        dir_fd = os.open(incoming_dir, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        except OSError:
            pass
        finally:
            os.close(dir_fd)
            
    except Exception as e:
        # 错误日志脱敏
        sys.stderr.write("Error: Upload process failed: {}\n".format(type(e).__name__))
        if temp_fd is not None:
            try:
                os.close(temp_fd)
            except OSError:
                pass
        if os.path.exists(temp_path):
            try:
                os.unlink(temp_path)
            except OSError:
                pass
        sys.exit(1)

if __name__ == '__main__':
    main()
