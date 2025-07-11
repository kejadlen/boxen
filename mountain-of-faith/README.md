# mountain of faith

- Set the IP manually either in `~/.ssh/config.local` or `hosts.yml`

```sh
ansible-playbook -l mountain-of-faith mountain-of-faith/main.yml
```

- Log into Tailscale: `sudo tailscale up`
- Disable the key expiry in the [Tailscale console](https://login.tailscale.com/admin/machines)
- Remove the manual IP now that the host is on the tailnet

## minio

```sh
mc alias set minio http://mountain-of-faith:9000 root $MINIO_PASSWORD

# arq
mc mb minio/arq
mc admin accesskey create minio root --policy mountain-of-faith/minio/arq.json
```
