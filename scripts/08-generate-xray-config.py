#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import ipaddress
import json
import os
import re
import uuid as uuidlib
from pathlib import Path
from typing import Any, Dict, Iterable, List
from urllib.parse import quote, urlencode


REQUIRED_COLUMNS = {"tag", "listen_port", "allowed_sources", "uuid", "server_name", "flow"}
TAG_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
SHORT_ID_RE = re.compile(r"^[0-9a-fA-F]{0,16}$")


class ConfigError(SystemExit):
    pass


def parse_env_file(path: Path) -> Dict[str, str]:
    env: Dict[str, str] = {}
    if not path.exists():
        raise ConfigError(f"找不到配置文件：{path}")
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        env[key] = value
    return env


def defaults(env: Dict[str, str]) -> Dict[str, str]:
    state_dir = env.get("RLB_STATE_DIR", "/etc/reality-landing-bootstrap")
    merged = {
        "SERVER_ALIAS": "landing-vps",
        "SERVER_DOMAIN": "",
        "SERVER_IP_IPV4": "",
        "SERVER_IP_IPV6": "",
        "SSH_PORT": "22",
        "ADMIN_PUBKEY": "",
        "ADMIN_PUBKEYS": "",
        "REALITY_SERVER_NAME": "www.microsoft.com",
        "REALITY_DEST": "www.microsoft.com:443",
        "CLIENT_PORT_START": "51043",
        "ENABLE_UFW": "true",
        "ENABLE_FAIL2BAN": "true",
        "ENABLE_IPV6_LISTEN": "false",
        "RESET_REALITY_KEYS": "false",
        "RESET_CLIENT_UUIDS": "false",
        "RLB_STATE_DIR": state_dir,
        "XRAY_CONFIG_PATH": "/etc/xray/config.json",
        "LANDING_CLIENTS_PATH": "./landing-clients.csv",
        "CLIENT_UUIDS_PATH": f"{state_dir}/client-uuids.json",
        "REALITY_PRIVATE_KEY_PATH": f"{state_dir}/reality-private.key",
        "REALITY_PUBLIC_KEY_PATH": f"{state_dir}/reality-public.key",
        "REALITY_SHORT_ID_PATH": f"{state_dir}/reality-short-id.txt",
        "LINKS_DIR": f"{state_dir}/links",
        "LINKS_OUT": "/root/reality-landing-bootstrap-links.txt",
        "CLIENT_FINGERPRINT": "chrome",
        "DEFAULT_FLOW": "xtls-rprx-vision",
        "XRAY_LOGLEVEL": "warning",
    }
    merged.update(env)
    return merged


def as_bool(env: Dict[str, str], key: str) -> bool:
    value = env.get(key, "").lower()
    if value not in {"true", "false"}:
        raise ConfigError(f"{key} 必须是 true 或 false，当前：{env.get(key)}")
    return value == "true"


def as_port(env: Dict[str, str], key: str) -> int:
    value = env.get(key, "")
    if not value.isdigit():
        raise ConfigError(f"{key} 必须是数字端口，当前：{value}")
    port = int(value)
    if not 1 <= port <= 65535:
        raise ConfigError(f"{key} 超出端口范围 1-65535：{port}")
    return port


def resolve_path(env: Dict[str, str], key: str, base: Path) -> Path:
    path = Path(env[key])
    if not path.is_absolute():
        path = base / env[key].lstrip("./")
    return path


def validate_domain(value: str, key: str) -> None:
    if not re.match(r"^[A-Za-z0-9._-]+$", value):
        raise ConfigError(f"{key} 不合法：{value}")


def validate_env(env: Dict[str, str]) -> None:
    if not env["SERVER_ALIAS"].strip():
        raise ConfigError("SERVER_ALIAS 不能为空")
    if not (env["SERVER_DOMAIN"].strip() or env["SERVER_IP_IPV4"].strip() or env["SERVER_IP_IPV6"].strip()):
        raise ConfigError("SERVER_DOMAIN、SERVER_IP_IPV4、SERVER_IP_IPV6 至少填写一个")
    validate_domain(env["REALITY_SERVER_NAME"], "REALITY_SERVER_NAME")
    as_port(env, "SSH_PORT")
    as_port(env, "CLIENT_PORT_START")
    for key in ["ENABLE_UFW", "ENABLE_FAIL2BAN", "ENABLE_IPV6_LISTEN", "RESET_REALITY_KEYS", "RESET_CLIENT_UUIDS"]:
        as_bool(env, key)
    if env.get("DEFAULT_FLOW", "") not in {"", "xtls-rprx-vision"}:
        raise ConfigError("DEFAULT_FLOW 目前建议为空或 xtls-rprx-vision")
    for key in ["RLB_STATE_DIR", "XRAY_CONFIG_PATH", "CLIENT_UUIDS_PATH", "LINKS_DIR", "LINKS_OUT"]:
        if not Path(env[key]).is_absolute():
            raise ConfigError(f"{key} 必须是绝对路径：{env[key]}")


def iter_csv_lines(path: Path) -> Iterable[str]:
    for line in path.read_text(encoding="utf-8-sig").splitlines(True):
        if line.strip() and not line.lstrip().startswith("#"):
            yield line


def parse_sources(value: str, lineno: int) -> List[str]:
    sources = [item.strip() for item in value.split(";") if item.strip()]
    if not sources:
        raise ConfigError(f"landing-clients.csv 第 {lineno} 行 allowed_sources 不能为空")
    for source in sources:
        try:
            ipaddress.ip_network(source, strict=False)
        except ValueError as exc:
            raise ConfigError(f"landing-clients.csv 第 {lineno} 行 allowed_sources 不合法：{source}") from exc
    return sources


def load_uuid_state(env: Dict[str, str]) -> Dict[str, str]:
    path = Path(env["CLIENT_UUIDS_PATH"])
    if path.exists() and not as_bool(env, "RESET_CLIENT_UUIDS"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise ConfigError(f"CLIENT_UUIDS_PATH 不是合法 JSON：{path}") from exc
        if isinstance(data, dict):
            return {str(k): str(v) for k, v in data.items()}
    return {}


def save_uuid_state(env: Dict[str, str], state: Dict[str, str]) -> None:
    path = Path(env["CLIENT_UUIDS_PATH"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)


def next_client_port(start: int, used: set[int]) -> int:
    for port in range(start, 65536):
        if port not in used:
            return port
    raise ConfigError("没有可用客户端入口端口")


def load_clients(env: Dict[str, str], base: Path, *, persist_uuids: bool) -> List[Dict[str, Any]]:
    path = resolve_path(env, "LANDING_CLIENTS_PATH", base)
    if not path.exists():
        raise ConfigError(f"找不到 landing-clients.csv：{path}")
    try:
        reader = csv.DictReader(iter_csv_lines(path))
    except UnicodeDecodeError as exc:
        raise ConfigError(f"landing-clients.csv 必须是 UTF-8：{exc}") from exc
    if not reader.fieldnames:
        raise ConfigError("landing-clients.csv 没有表头")
    missing = REQUIRED_COLUMNS - set(reader.fieldnames)
    if missing:
        raise ConfigError("landing-clients.csv 表头缺少字段：" + ", ".join(sorted(missing)))

    client_start = as_port(env, "CLIENT_PORT_START")
    uuid_state = load_uuid_state(env)
    used_tags: set[str] = set()
    used_ports: set[int] = set()
    rows: List[Dict[str, Any]] = []

    for lineno, row in enumerate(reader, start=2):
        normalized = {key: (value or "").strip() for key, value in row.items()}
        if not any(normalized.values()):
            continue
        tag = normalized["tag"]
        if not TAG_RE.match(tag):
            raise ConfigError(f"landing-clients.csv 第 {lineno} 行 tag 不合法：{tag}")
        if tag in used_tags:
            raise ConfigError(f"landing-clients.csv 第 {lineno} 行 tag 重复：{tag}")
        used_tags.add(tag)

        if normalized["listen_port"]:
            if not normalized["listen_port"].isdigit():
                raise ConfigError(f"landing-clients.csv 第 {lineno} 行 listen_port 必须是数字或留空")
            listen_port = int(normalized["listen_port"])
        else:
            listen_port = next_client_port(client_start, used_ports)
        if not 1 <= listen_port <= 65535:
            raise ConfigError(f"landing-clients.csv 第 {lineno} 行 listen_port 超出范围：{listen_port}")
        if listen_port in used_ports:
            raise ConfigError(f"landing-clients.csv 第 {lineno} 行 listen_port 重复：{listen_port}")
        used_ports.add(listen_port)

        client_uuid = normalized["uuid"] or uuid_state.get(tag) or str(uuidlib.uuid4())
        if not UUID_RE.match(client_uuid):
            raise ConfigError(f"landing-clients.csv 第 {lineno} 行 uuid 不合法：{client_uuid}")
        uuid_state[tag] = client_uuid

        server_name = normalized["server_name"] or env["REALITY_SERVER_NAME"]
        validate_domain(server_name, f"landing-clients.csv 第 {lineno} 行 server_name")
        flow = normalized["flow"] or env.get("DEFAULT_FLOW", "xtls-rprx-vision")
        if flow not in {"", "xtls-rprx-vision"}:
            raise ConfigError(f"landing-clients.csv 第 {lineno} 行 flow 不支持：{flow}")

        rows.append(
            {
                "tag": tag,
                "listen_port": listen_port,
                "allowed_sources": parse_sources(normalized["allowed_sources"], lineno),
                "uuid": client_uuid,
                "server_name": server_name,
                "flow": flow,
            }
        )

    if not rows:
        raise ConfigError("landing-clients.csv 没有任何客户端行")
    if persist_uuids:
        save_uuid_state(env, uuid_state)
    return rows


def read_text_file(path: str, label: str) -> str:
    p = Path(path)
    if not p.exists():
        raise ConfigError(f"找不到 {label}：{p}；请先运行 sudo bash bootstrap.sh --phase xray")
    value = p.read_text(encoding="utf-8").strip()
    if not value:
        raise ConfigError(f"{label} 为空：{p}")
    return value


def build_xray_config(env: Dict[str, str], clients: List[Dict[str, Any]]) -> Dict[str, Any]:
    private_key = read_text_file(env["REALITY_PRIVATE_KEY_PATH"], "Reality private key")
    short_id = read_text_file(env["REALITY_SHORT_ID_PATH"], "Reality short-id").lower()
    if not SHORT_ID_RE.match(short_id) or len(short_id) % 2 != 0:
        raise ConfigError("Reality short-id 必须是 0-16 位、偶数长度的十六进制字符串")
    listen = "::" if as_bool(env, "ENABLE_IPV6_LISTEN") else "0.0.0.0"
    inbounds = []
    for client in clients:
        user: Dict[str, Any] = {"id": client["uuid"], "email": client["tag"]}
        if client["flow"]:
            user["flow"] = client["flow"]
        inbounds.append(
            {
                "tag": f"in-{client['tag']}",
                "listen": listen,
                "port": client["listen_port"],
                "protocol": "vless",
                "settings": {"clients": [user], "decryption": "none"},
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "show": False,
                        "dest": env["REALITY_DEST"],
                        "xver": 0,
                        "serverNames": [client["server_name"]],
                        "privateKey": private_key,
                        "shortIds": [short_id],
                    },
                },
                "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
            }
        )
    return {
        "log": {"loglevel": env["XRAY_LOGLEVEL"]},
        "inbounds": inbounds,
        "outbounds": [{"tag": "direct", "protocol": "freedom"}, {"tag": "blocked", "protocol": "blackhole"}],
    }


def url_host(host: str) -> str:
    if ":" in host and not host.startswith("["):
        return f"[{host}]"
    return host


def public_host(env: Dict[str, str]) -> str:
    return env["SERVER_DOMAIN"] or env["SERVER_IP_IPV4"] or env["SERVER_IP_IPV6"]


def build_link(env: Dict[str, str], client: Dict[str, Any]) -> str:
    public_key = read_text_file(env["REALITY_PUBLIC_KEY_PATH"], "Reality public key")
    short_id = read_text_file(env["REALITY_SHORT_ID_PATH"], "Reality short-id").lower()
    params = {
        "type": "tcp",
        "security": "reality",
        "flow": client["flow"],
        "fp": env["CLIENT_FINGERPRINT"],
        "sni": client["server_name"],
        "pbk": public_key,
        "sid": short_id,
        "spx": "/",
    }
    if not params["flow"]:
        params.pop("flow")
    query = urlencode(params)
    name = quote(f"{env['SERVER_ALIAS']}-{client['tag']}")
    return f"vless://{client['uuid']}@{url_host(public_host(env))}:{client['listen_port']}?{query}#{name}"


def write_config(path: Path, config: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)


def output_links(env: Dict[str, str], clients: List[Dict[str, Any]]) -> None:
    links_dir = Path(env["LINKS_DIR"])
    links_dir.mkdir(parents=True, exist_ok=True)
    all_links = []
    link_files = []
    for client in clients:
        link = build_link(env, client)
        all_links.append(link)
        path = links_dir / f"{client['tag']}.txt"
        path.write_text(link + "\n", encoding="utf-8")
        os.chmod(path, 0o600)
        link_files.append((client["tag"], path))
    out = Path(env["LINKS_OUT"])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(all_links) + "\n", encoding="utf-8")
    os.chmod(out, 0o600)
    print()
    print(f"已生成链接文件：{out}")
    print(f"已生成单客户端链接目录：{links_dir}")
    print("单客户端链接文件：")
    for tag, path in link_files:
        print(f"  {tag} -> {path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-env", type=Path, default=Path("config.env"))
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--print-ports", action="store_true")
    parser.add_argument("--print-ufw-rules", action="store_true")
    parser.add_argument("--output-links", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    base = args.config_env.resolve().parent
    env = defaults(parse_env_file(args.config_env))
    validate_env(env)
    persist = args.write or args.output_links
    clients = load_clients(env, base, persist_uuids=persist)

    if args.print_ports:
        for client in clients:
            print(client["listen_port"])
        return 0
    if args.print_ufw_rules:
        for client in clients:
            for source in client["allowed_sources"]:
                print(f"{client['tag']}\t{client['listen_port']}\t{source}")
        return 0
    if args.output_links:
        output_links(env, clients)
        return 0
    if args.write:
        config = build_xray_config(env, clients)
        write_config(Path(env["XRAY_CONFIG_PATH"]), config)
        if not args.quiet:
            print(f"已生成 Xray 配置：{env['XRAY_CONFIG_PATH']}")
        return 0
    if args.check_only:
        return 0
    print(json.dumps(build_xray_config(env, clients), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
