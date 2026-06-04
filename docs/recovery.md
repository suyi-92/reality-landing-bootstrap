# 恢复与回滚

## SSH 故障原则

不要关闭当前还能登录的 SSH 窗口。先执行：

```bash
sudo /usr/sbin/sshd -t
sudo /usr/sbin/sshd -T -C user=root,host=localhost,addr=127.0.0.1
```

如果新窗口无法登录，可在旧窗口回滚：

```bash
sudo CONFIRM_ROLLBACK=yes bash bootstrap.sh --phase rollback
```

## UFW 导致失联

如果旧窗口还能用，可以临时禁用 UFW：

```bash
sudo ufw disable
```

或只删除本项目规则：

```bash
sudo CONFIRM_ROLLBACK=yes bash bootstrap.sh --phase rollback
```

## Xray 配置问题

检查配置：

```bash
sudo xray run -test -config /etc/xray/config.json
sudo systemctl status xray --no-pager -l
```

查看日志：

```bash
sudo journalctl -u xray --no-pager -n 100
sudo tail -n 100 /var/log/reality-landing-bootstrap.log
```
