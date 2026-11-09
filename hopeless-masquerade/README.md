# hopeless-masquerade

A Raspberry Pi 4 Model B running [BirdNET-Pi][birdnet-pi].

## setup

```sh
ansible-playbook -l hopeless-masquerade -e ansible_host=ANSIBLE_HOST --ask-become-pass hopeless-masquerade/main.yml

curl -s https://raw.githubusercontent.com/zach7036/BirdNET-Pi-Enhanced-Version/main/newinstaller.sh | bash
```

Tag the device `tag:birdnet` in the [Tailscale console][tailscale], which
limits what it can reach on the tailnet.

[tailscale]: https://login.tailscale.com/admin/machines

[birdnet-pi]: https://github.com/zach7036/BirdNET-Pi
